import { Router } from 'express';
import { supabase } from '../config/database';
import { redis, redisKeys } from '../config/redis';
import { createOTP, verifyOTP, hashValue } from '../services/otp.service';
import { getKeyFingerprint } from '../services/crypto.service';
import { createAccessToken, createRefreshToken, hashToken } from '../services/jwt.service';
import { otpRateLimiter } from '../middleware/rateLimit';
import { asyncHandler } from '../middleware/errorHandler';
import {
  RequestOTPBody,
  VerifyOTPBody,
  RefreshTokenBody,
  APIResponse,
} from '../types';

const router = Router();

/**
 * POST /api/v1/auth/request-otp
 * Request OTP for phone verification
 */
router.post(
  '/request-otp',
  otpRateLimiter,
  asyncHandler(async (req, res) => {
    const { phoneNumber } = req.body as RequestOTPBody;
    
    // Validate phone number format
    const phoneRegex = /^\+[1-9]\d{1,14}$/;
    if (!phoneRegex.test(phoneNumber)) {
      res.status(400).json({
        success: false,
        error: 'Invalid phone number format',
      } as APIResponse);
      return;
    }
    
    // Create and send OTP
    await createOTP(phoneNumber);
    
    res.json({
      success: true,
      expiresIn: 300,
    } as APIResponse<{ expiresIn: number }>);
  })
);

/**
 * POST /api/v1/auth/verify-otp
 * Verify OTP and register/authenticate user
 */
router.post(
  '/verify-otp',
  asyncHandler(async (req, res) => {
    const { phoneNumber, code, publicKey, deviceId, deviceName } = req.body as VerifyOTPBody;
    
    // Validate inputs
    if (!phoneNumber || !code || !publicKey || !deviceId) {
      res.status(400).json({
        success: false,
        error: 'Missing required fields',
      } as APIResponse);
      return;
    }
    
    // Verify OTP
    const isValid = await verifyOTP(phoneNumber, code);
    if (!isValid) {
      res.status(400).json({
        success: false,
        error: 'Invalid or expired OTP',
      } as APIResponse);
      return;
    }
    
    // Find or create user
    let { data: user } = await supabase
      .from('users')
      .select('*')
      .eq('phone_number', phoneNumber)
      .single();
    
    if (!user) {
      // Create new user
      const { data: newUser, error } = await supabase
        .from('users')
        .insert({ phone_number: phoneNumber })
        .select()
        .single();
      
      if (error || !newUser) {
        res.status(500).json({
          success: false,
          error: 'Failed to create user',
        } as APIResponse);
        return;
      }
      
      user = newUser;
    }
    
    // Store/update public key
    const keyFingerprint = getKeyFingerprint(publicKey);
    const { data: existingKey } = await supabase
      .from('public_keys')
      .select('*')
      .eq('user_id', user.id)
      .eq('key_fingerprint', keyFingerprint)
      .single();
    
    if (existingKey) {
      // Update existing key
      await supabase
        .from('public_keys')
        .update({
          public_key_data: publicKey,
          device_name: deviceName,
          is_active: true,
        })
        .eq('id', existingKey.id);
    } else {
      // Create new key
      await supabase
        .from('public_keys')
        .insert({
          user_id: user.id,
          public_key_data: publicKey,
          key_fingerprint: keyFingerprint,
          device_id: deviceId,
          device_name: deviceName,
        });
    }
    
    // Check voice enrollment
    const { data: voiceprint } = await supabase
      .from('voiceprints')
      .select('id')
      .eq('user_id', user.id)
      .single();
    
    // Generate tokens
    const accessToken = createAccessToken(user.id, user.phone_number);
    const refreshTokenValue = createRefreshToken();
    const refreshTokenHash = hashToken(refreshTokenValue);
    
    // Store refresh token
    await supabase
      .from('refresh_tokens')
      .insert({
        user_id: user.id,
        token_hash: refreshTokenHash,
        expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
      });
    
    // Cache session in Redis
    if (redis) {
      await redis.set(
        redisKeys.userSession(user.id),
        JSON.stringify({
          user_id: user.id,
          phone: user.phone_number,
          device_id: deviceId,
        }),
        { ex: 7 * 24 * 60 * 60 } // 7 days
      );
    }
    
    res.json({
      success: true,
      accessToken,
      refreshToken: refreshTokenValue,
      user: {
        id: user.id,
        phoneNumber: user.phone_number,
        displayName: user.display_name,
        voiceEnrolled: !!voiceprint,
      },
    });
  })
);

/**
 * POST /api/v1/auth/refresh
 * Refresh access token
 */
router.post(
  '/refresh',
  asyncHandler(async (req, res) => {
    const { refreshToken } = req.body as RefreshTokenBody;
    
    if (!refreshToken) {
      res.status(400).json({
        success: false,
        error: 'Missing refresh token',
      } as APIResponse);
      return;
    }
    
    // Hash and find refresh token
    const tokenHash = hashToken(refreshToken);
    const { data: tokenRecord } = await supabase
      .from('refresh_tokens')
      .select('*, users(*)')
      .eq('token_hash', tokenHash)
      .gt('expires_at', new Date().toISOString())
      .single();
    
    if (!tokenRecord) {
      res.status(401).json({
        success: false,
        error: 'Invalid or expired refresh token',
      } as APIResponse);
      return;
    }
    
    // Revoke old token
    await supabase
      .from('refresh_tokens')
      .delete()
      .eq('id', tokenRecord.id);
    
    // Generate new tokens
    const accessToken = createAccessToken(tokenRecord.users.id, tokenRecord.users.phone_number);
    const newRefreshToken = createRefreshToken();
    const newRefreshHash = hashToken(newRefreshToken);
    
    // Store new refresh token
    await supabase
      .from('refresh_tokens')
      .insert({
        user_id: tokenRecord.users.id,
        token_hash: newRefreshHash,
        expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
      });
    
    res.json({
      success: true,
      accessToken,
      refreshToken: newRefreshToken,
    });
  })
);

export default router;

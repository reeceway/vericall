import { Router } from 'express';
import { supabase } from '../config/database';
import { redis, redisKeys } from '../config/redis';
import { authenticate } from '../middleware/auth';
import { callRateLimiter } from '../middleware/rateLimit';
import { asyncHandler } from '../middleware/errorHandler';
import { verifySignature, createCallMessage } from '../services/crypto.service';
import { sendToUser } from '../services/websocket.service';
import {
  AuthenticatedRequest,
  InitiateCallBody,
  CallActionBody,
  InitiateCallResponse,
  RecipientInfo,
  APIResponse,
} from '../types';

const router = Router();

/**
 * POST /api/v1/calls/initiate
 * Initiate a call with cryptographic signature
 */
router.post(
  '/initiate',
  authenticate,
  callRateLimiter,
  asyncHandler(async (req: AuthenticatedRequest, res) => {
    const caller = req.user!;
    const { recipientId, timestamp, nonce, signature } = req.body as InitiateCallBody;
    
    // Verify timestamp is recent (within 5 minutes)
    const now = Math.floor(Date.now() / 1000);
    if (Math.abs(now - timestamp) > 300) {
      res.status(400).json({
        success: false,
        error: 'Timestamp too old',
      } as APIResponse);
      return;
    }
    
    // Find recipient
    const { data: recipient } = await supabase
      .from('users')
      .select('*, public_keys(*)')
      .eq('id', recipientId)
      .single();
    
    if (!recipient) {
      res.status(404).json({
        success: false,
        error: 'Recipient not found',
      } as APIResponse);
      return;
    }
    
    if (recipient.id === caller.id) {
      res.status(400).json({
        success: false,
        error: 'Cannot call yourself',
      } as APIResponse);
      return;
    }
    
    // Get caller's public key
    const { data: callerKey } = await supabase
      .from('public_keys')
      .select('*')
      .eq('user_id', caller.id)
      .eq('is_active', true)
      .single();
    
    // Verify signature
    let verified = false;
    if (callerKey) {
      const message = createCallMessage(recipientId, timestamp, nonce);
      verified = verifySignature(callerKey.public_key_data, message, signature);
    }
    
    // Create call record
    const { data: call, error } = await supabase
      .from('call_records')
      .insert({
        caller_id: caller.id,
        recipient_id: recipientId,
        signature_data: signature,
        verified,
      })
      .select()
      .single();
    
    if (error || !call) {
      res.status(500).json({
        success: false,
        error: 'Failed to create call',
      } as APIResponse);
      return;
    }
    
    // Create call session in Redis
    if (redis) {
      await redis.set(
        redisKeys.callSession(call.id),
        JSON.stringify({
          caller_id: caller.id,
          recipient_id: recipientId,
          status: 'pending',
        }),
        { ex: 3600 } // 1 hour
      );
    }
    
    // Check if recipient is online
    let socketConnected = false;
    if (redis) {
      const presence = await redis.get(redisKeys.userPresence(recipientId));
      socketConnected = presence === 'online';
    }
    
    // Notify recipient via WebSocket
    sendToUser(recipientId, {
      type: 'call:incoming',
      callId: call.id,
      caller: {
        id: caller.id,
        displayName: caller.display_name,
        verified,
      },
    });
    
    // Update caller last seen
    await supabase
      .from('users')
      .update({ updated_at: new Date().toISOString() })
      .eq('id', caller.id);
    
    const response: InitiateCallResponse = {
      callId: call.id,
      verified,
      recipient: {
        id: recipient.id,
        displayName: recipient.display_name || undefined,
        socketConnected,
      },
    };
    
    res.json({
      success: true,
      ...response,
    });
  })
);

/**
 * POST /api/v1/calls/answer
 * Answer an incoming call
 */
router.post(
  '/answer',
  authenticate,
  asyncHandler(async (req: AuthenticatedRequest, res) => {
    const recipient = req.user!;
    const { callId } = req.body as CallActionBody;
    
    // Get call
    const { data: call } = await supabase
      .from('call_records')
      .select('*')
      .eq('id', callId)
      .single();
    
    if (!call) {
      res.status(404).json({
        success: false,
        error: 'Call not found',
      } as APIResponse);
      return;
    }
    
    if (call.recipient_id !== recipient.id) {
      res.status(403).json({
        success: false,
        error: 'Not authorized to answer this call',
      } as APIResponse);
      return;
    }
    
    // Update call
    const { error } = await supabase
      .from('call_records')
      .update({
        answered_at: new Date().toISOString(),
      })
      .eq('id', callId);
    
    if (error) {
      res.status(500).json({
        success: false,
        error: 'Failed to answer call',
      } as APIResponse);
      return;
    }
    
    // Update Redis session
    if (redis) {
      const session = await redis.get(redisKeys.callSession(callId));
      if (session) {
        const data = JSON.parse(session as string);
        data.status = 'active';
        data.answered_at = new Date().toISOString();
        await redis.set(redisKeys.callSession(callId), JSON.stringify(data), { ex: 3600 });
      }
    }
    
    // Notify caller
    sendToUser(call.caller_id, {
      type: 'call:answered',
      callId,
    });
    
    res.json({ success: true });
  })
);

/**
 * POST /api/v1/calls/end
 * End an active call
 */
router.post(
  '/end',
  authenticate,
  asyncHandler(async (req: AuthenticatedRequest, res) => {
    const user = req.user!;
    const { callId } = req.body as CallActionBody;
    
    // Get call
    const { data: call } = await supabase
      .from('call_records')
      .select('*')
      .eq('id', callId)
      .single();
    
    if (!call) {
      res.status(404).json({
        success: false,
        error: 'Call not found',
      } as APIResponse);
      return;
    }
    
    if (call.caller_id !== user.id && call.recipient_id !== user.id) {
      res.status(403).json({
        success: false,
        error: 'Not authorized',
      } as APIResponse);
      return;
    }
    
    // Calculate duration
    let durationSeconds: number | undefined;
    if (call.answered_at) {
      const start = new Date(call.answered_at).getTime();
      const end = Date.now();
      durationSeconds = Math.floor((end - start) / 1000);
    }
    
    // Update call
    await supabase
      .from('call_records')
      .update({
        ended_at: new Date().toISOString(),
        duration_seconds: durationSeconds,
      })
      .eq('id', callId);
    
    // Clean up Redis
    if (redis) {
      await redis.del(redisKeys.callSession(callId));
    }
    
    // Notify other party
    const otherPartyId = call.caller_id === user.id ? call.recipient_id : call.caller_id;
    sendToUser(otherPartyId, {
      type: 'call:ended',
      callId,
    });
    
    res.json({ success: true });
  })
);

/**
 * GET /api/v1/calls/history/my
 * Get call history
 */
router.get(
  '/history/my',
  authenticate,
  asyncHandler(async (req: AuthenticatedRequest, res) => {
    const user = req.user!;
    const limit = parseInt(req.query.limit as string) || 50;
    const offset = parseInt(req.query.offset as string) || 0;
    
    // Get calls
    const { data: calls, error } = await supabase
      .from('call_records')
      .select('*, caller:users!caller_id(*), recipient:users!recipient_id(*)')
      .or(`caller_id.eq.${user.id},recipient_id.eq.${user.id}`)
      .order('initiated_at', { ascending: false })
      .range(offset, offset + limit - 1);
    
    if (error) {
      res.status(500).json({
        success: false,
        error: 'Failed to fetch call history',
      } as APIResponse);
      return;
    }
    
    // Get total count
    const { count } = await supabase
      .from('call_records')
      .select('*', { count: 'exact', head: true })
      .or(`caller_id.eq.${user.id},recipient_id.eq.${user.id}`);
    
    const formattedCalls = (calls || []).map((call: any) => ({
      id: call.id,
      callerId: call.caller_id,
      recipientId: call.recipient_id,
      status: call.ended_at ? 'ended' : call.answered_at ? 'active' : 'pending',
      startedAt: call.answered_at,
      endedAt: call.ended_at,
      durationSeconds: call.duration_seconds,
      verified: call.verified,
    }));
    
    res.json({
      success: true,
      calls: formattedCalls,
      total: count || 0,
    });
  })
);

export default router;

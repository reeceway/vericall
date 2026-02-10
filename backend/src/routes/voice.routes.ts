import { Router } from 'express';
import { supabase } from '../config/database';
import { redis, redisKeys } from '../config/redis';
import { authenticate } from '../middleware/auth';
import { voiceRateLimiter } from '../middleware/rateLimit';
import { asyncHandler } from '../middleware/errorHandler';
import { forwardCallMessage } from '../services/websocket.service';
import {
  AuthenticatedRequest,
  VoiceEnrollBody,
  VoiceVerifyBody,
  VoiceVerifyResponse,
  APIResponse,
} from '../types';
import { CONSTANTS } from '../config/constants';

const router = Router();

/**
 * Calculate cosine similarity between two vectors
 */
const cosineSimilarity = (a: number[], b: number[]): number => {
  let dot = 0;
  let normA = 0;
  let normB = 0;
  
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  
  if (normA === 0 || normB === 0) return 0;
  return dot / (Math.sqrt(normA) * Math.sqrt(normB));
};

/**
 * Get confidence level based on match score
 */
const getConfidence = (score: number): VoiceVerifyResponse['confidence'] => {
  if (score >= 0.90) return 'very_high';
  if (score >= CONSTANTS.VOICE_MATCH_THRESHOLD) return 'high';
  if (score >= CONSTANTS.VOICE_WARNING_THRESHOLD) return 'medium';
  if (score >= 0.40) return 'low';
  return 'very_low';
};

/**
 * POST /api/v1/voice/enroll
 * Enroll voice print with 192-dimension embedding
 */
router.post(
  '/enroll',
  authenticate,
  voiceRateLimiter,
  asyncHandler(async (req: AuthenticatedRequest, res) => {
    const user = req.user!;
    const { embedding, sampleCount } = req.body as VoiceEnrollBody;
    
    // Validate embedding dimension
    if (!embedding || embedding.length !== CONSTANTS.VOICE_EMBEDDING_DIMENSION) {
      res.status(400).json({
        success: false,
        error: `Embedding must have exactly ${CONSTANTS.VOICE_EMBEDDING_DIMENSION} dimensions`,
      } as APIResponse);
      return;
    }
    
    // Calculate quality score based on variance
    const mean = embedding.reduce((a, b) => a + b, 0) / embedding.length;
    const variance = embedding.reduce((sum, val) => sum + Math.pow(val - mean, 2), 0) / embedding.length;
    const quality = Math.min(1.0, Math.max(0.5, variance * 10));
    
    // Check if user already has voiceprint
    const { data: existing } = await supabase
      .from('voiceprints')
      .select('*')
      .eq('user_id', user.id)
      .single();
    
    if (existing) {
      // Update existing
      await supabase
        .from('voiceprints')
        .update({
          embedding,
          sample_count: sampleCount,
          quality,
          updated_at: new Date().toISOString(),
        })
        .eq('id', existing.id);
    } else {
      // Create new
      await supabase
        .from('voiceprints')
        .insert({
          user_id: user.id,
          embedding,
          sample_count: sampleCount,
          quality,
        });
    }
    
    // Update user voice_enrolled flag
    await supabase
      .from('users')
      .update({ voice_enrolled: true })
      .eq('id', user.id);
    
    res.json({
      success: true,
      quality: Math.round(quality * 100) / 100,
    });
  })
);

/**
 * GET /api/v1/voice/voiceprint/:userId
 * Get voice print for a user
 */
router.get(
  '/voiceprint/:userId',
  authenticate,
  asyncHandler(async (req: AuthenticatedRequest, res) => {
    const currentUser = req.user!;
    const { userId } = req.params;
    
    // Only allow getting own voiceprint or if in active call
    if (currentUser.id !== userId) {
      // Check if they have an active call
      const { data: activeCall } = await supabase
        .from('call_records')
        .select('*')
        .or(`and(caller_id.eq.${currentUser.id},recipient_id.eq.${userId}),and(caller_id.eq.${userId},recipient_id.eq.${currentUser.id})`)
        .is('ended_at', null)
        .single();
      
      if (!activeCall) {
        res.status(403).json({
          success: false,
          error: 'Not authorized to access this voice print',
        } as APIResponse);
        return;
      }
    }
    
    const { data: voiceprint } = await supabase
      .from('voiceprints')
      .select('*')
      .eq('user_id', userId)
      .single();
    
    if (!voiceprint) {
      res.json({
        success: true,
        enrolled: false,
      });
      return;
    }
    
    res.json({
      success: true,
      enrolled: true,
      voiceprint: {
        embedding: voiceprint.embedding,
        version: '1.0',
        sampleCount: voiceprint.sample_count,
        quality: voiceprint.quality,
      },
    });
  })
);

/**
 * POST /api/v1/voice/verify
 * Verify voice against stored voiceprint
 */
router.post(
  '/verify',
  authenticate,
  voiceRateLimiter,
  asyncHandler(async (req: AuthenticatedRequest, res) => {
    const currentUser = req.user!;
    const { embedding, callId, targetUserId } = req.body as VoiceVerifyBody;
    
    // Validate embedding
    if (!embedding || embedding.length !== CONSTANTS.VOICE_EMBEDDING_DIMENSION) {
      res.status(400).json({
        success: false,
        error: `Embedding must have exactly ${CONSTANTS.VOICE_EMBEDDING_DIMENSION} dimensions`,
      } as APIResponse);
      return;
    }
    
    // Determine target user
    const userIdToVerify = targetUserId || currentUser.id;
    
    // Get target voiceprint
    const { data: voiceprint } = await supabase
      .from('voiceprints')
      .select('*')
      .eq('user_id', userIdToVerify)
      .single();
    
    if (!voiceprint) {
      res.status(404).json({
        success: false,
        error: 'Target user has no voice print',
      } as APIResponse);
      return;
    }
    
    // Calculate similarity
    const similarity = cosineSimilarity(embedding, voiceprint.embedding);
    const isMatch = similarity >= CONSTANTS.VOICE_MATCH_THRESHOLD;
    const confidence = getConfidence(similarity);
    
    // If call context, update call record
    if (callId) {
      const { data: call } = await supabase
        .from('call_records')
        .select('*')
        .eq('id', callId)
        .single();
      
      if (call && (call.caller_id === currentUser.id || call.recipient_id === currentUser.id)) {
        // Get current scores
        const scores = call.voice_match_scores || [];
        scores.push({
          timestamp: new Date().toISOString(),
          score: similarity,
          isMatch,
        });
        
        // Calculate average
        const avgScore = scores.reduce((sum: number, s: any) => sum + s.score, 0) / scores.length;
        
        await supabase
          .from('call_records')
          .update({ voice_match_scores: scores })
          .eq('id', callId);
        
        // Update Redis for WebSocket
        if (redis) {
          await forwardCallMessage(callId, currentUser.id, {
            type: 'voice:match',
            callId,
            matchScore: Math.round(similarity * 100),
            isMatch,
            confidence,
          });
        }
      }
    }
    
    const response: VoiceVerifyResponse = {
      match_score: Math.round(similarity * 10000) / 10000,
      is_match: isMatch,
      confidence,
      threshold: CONSTANTS.VOICE_MATCH_THRESHOLD,
    };
    
    res.json({
      success: true,
      ...response,
    });
  })
);

/**
 * DELETE /api/v1/voice/voiceprint
 * Delete user's voice print
 */
router.delete(
  '/voiceprint',
  authenticate,
  asyncHandler(async (req: AuthenticatedRequest, res) => {
    const user = req.user!;
    
    await supabase
      .from('voiceprints')
      .delete()
      .eq('user_id', user.id);
    
    // Update user flag
    await supabase
      .from('users')
      .update({ voice_enrolled: false })
      .eq('id', user.id);
    
    res.json({
      success: true,
      message: 'Voice print deleted',
    });
  })
);

export default router;

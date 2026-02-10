import { Router } from 'express';
import { supabase } from '../config/database';
import { authenticate } from '../middleware/auth';
import { asyncHandler } from '../middleware/errorHandler';
import { AuthenticatedRequest, UpdateUserBody, APIResponse } from '../types';

const router = Router();

/**
 * GET /api/v1/users/me
 * Get current user profile
 */
router.get(
  '/me',
  authenticate,
  asyncHandler(async (req: AuthenticatedRequest, res) => {
    const user = req.user!;
    
    // Check voice enrollment
    const { data: voiceprint } = await supabase
      .from('voiceprints')
      .select('id')
      .eq('user_id', user.id)
      .single();
    
    res.json({
      success: true,
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
 * PATCH /api/v1/users/me
 * Update user profile
 */
router.patch(
  '/me',
  authenticate,
  asyncHandler(async (req: AuthenticatedRequest, res) => {
    const user = req.user!;
    const { displayName } = req.body as UpdateUserBody;
    
    const updates: { display_name?: string; updated_at: string } = {
      updated_at: new Date().toISOString(),
    };
    
    if (displayName !== undefined) {
      updates.display_name = displayName;
    }
    
    const { data: updatedUser, error } = await supabase
      .from('users')
      .update(updates)
      .eq('id', user.id)
      .select()
      .single();
    
    if (error || !updatedUser) {
      res.status(500).json({
        success: false,
        error: 'Failed to update user',
      } as APIResponse);
      return;
    }
    
    // Check voice enrollment
    const { data: voiceprint } = await supabase
      .from('voiceprints')
      .select('id')
      .eq('user_id', user.id)
      .single();
    
    res.json({
      success: true,
      user: {
        id: updatedUser.id,
        phoneNumber: updatedUser.phone_number,
        displayName: updatedUser.display_name,
        voiceEnrolled: !!voiceprint,
      },
    });
  })
);

export default router;

import { Router } from 'express';
import { supabase } from '../config/database';
import { authenticate } from '../middleware/auth';
import { asyncHandler } from '../middleware/errorHandler';
import { getKeyFingerprint } from '../services/crypto.service';
import { AuthenticatedRequest, ContactSyncBody, ContactInfo, APIResponse } from '../types';

const router = Router();

/**
 * POST /api/v1/contacts/sync
 * Sync contacts to find VeriCall users
 */
router.post(
  '/sync',
  authenticate,
  asyncHandler(async (req: AuthenticatedRequest, res) => {
    const currentUser = req.user!;
    const { phoneNumbers } = req.body as ContactSyncBody;
    
    if (!phoneNumbers || !Array.isArray(phoneNumbers) || phoneNumbers.length === 0) {
      res.status(400).json({
        success: false,
        error: 'phoneNumbers array required',
      } as APIResponse);
      return;
    }
    
    // Find users with matching phone numbers (excluding self)
    const { data: users } = await supabase
      .from('users')
      .select('*, public_keys(*), voiceprints(id)')
      .in('phone_number', phoneNumbers)
      .neq('id', currentUser.id);
    
    const contacts: ContactInfo[] = [];
    
    if (users) {
      for (const user of users) {
        const publicKey = user.public_keys?.[0];
        const voiceprint = user.voiceprints?.[0];
        
        contacts.push({
          phoneNumber: user.phone_number,
          userId: user.id,
          displayName: user.display_name || undefined,
          publicKeyFingerprint: publicKey 
            ? getKeyFingerprint(publicKey.public_key_data)
            : '',
          voiceEnrolled: !!voiceprint,
        });
      }
    }
    
    res.json({
      success: true,
      contacts,
    } as APIResponse<{ contacts: ContactInfo[] }>);
  })
);

export default router;

import crypto from 'crypto';
import { CONSTANTS } from '../config/constants';
import { supabase } from '../config/database';

/**
 * Generate a 6-digit OTP
 */
export const generateOTP = (): string => {
  return Array.from({ length: CONSTANTS.OTP_LENGTH }, () => 
    Math.floor(Math.random() * 10)
  ).join('');
};

/**
 * Hash a value using SHA-256
 */
export const hashValue = (value: string): string => {
  return crypto.createHash('sha256').update(value).digest('hex');
};

/**
 * Create OTP record in database
 */
export const createOTP = async (phoneNumber: string): Promise<string> => {
  const otp = generateOTP();
  const codeHash = hashValue(otp);
  const expiresAt = new Date(Date.now() + CONSTANTS.OTP_EXPIRES_IN * 1000);
  
  const { error } = await supabase
    .from('otps')
    .insert({
      phone_number: phoneNumber,
      code_hash: codeHash,
      expires_at: expiresAt.toISOString(),
    });
  
  if (error) {
    throw new Error(`Failed to create OTP: ${error.message}`);
  }
  
  // In production, send SMS here
  console.log(`🔐 OTP for ${phoneNumber}: ${otp}`);
  
  return otp;
};

/**
 * Verify OTP code
 */
export const verifyOTP = async (
  phoneNumber: string,
  code: string
): Promise<boolean> => {
  const codeHash = hashValue(code);
  
  // Find latest unused OTP
  const { data: otpRecord, error } = await supabase
    .from('otps')
    .select('*')
    .eq('phone_number', phoneNumber)
    .eq('is_used', false)
    .gt('expires_at', new Date().toISOString())
    .order('created_at', { ascending: false })
    .limit(1)
    .single();
  
  if (error || !otpRecord) {
    return false;
  }
  
  // Increment attempts
  await supabase
    .from('otps')
    .update({ attempts: (otpRecord.attempts || 0) + 1 })
    .eq('id', otpRecord.id);
  
  // Check max attempts
  if (otpRecord.attempts >= 5) {
    return false;
  }
  
  // Verify code
  if (codeHash !== otpRecord.code_hash) {
    return false;
  }
  
  // Mark as used
  await supabase
    .from('otps')
    .update({ is_used: true })
    .eq('id', otpRecord.id);
  
  return true;
};

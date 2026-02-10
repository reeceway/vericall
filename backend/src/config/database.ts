import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';

dotenv.config();

const supabaseUrl = process.env.SUPABASE_URL || '';
const supabaseKey = process.env.SUPABASE_SERVICE_KEY || '';

if (!supabaseUrl || !supabaseKey) {
  console.warn('Warning: Supabase credentials not configured');
}

export const supabase = createClient(supabaseUrl, supabaseKey);

// Database types matching the EXACT schema
export interface User {
  id: string;
  phone_number: string;
  display_name?: string;
  created_at: string;
  updated_at: string;
}

export interface PublicKey {
  id: string;
  user_id: string;
  public_key_data: string;
  key_fingerprint: string;
  device_id?: string;
  device_name?: string;
  is_active: boolean;
  created_at: string;
}

export interface Voiceprint {
  id: string;
  user_id: string;
  embedding: number[]; // Array of 192 floats
  sample_count: number;
  quality?: number;
  created_at: string;
  updated_at: string;
}

export interface CallRecord {
  id: string;
  caller_id: string;
  recipient_id: string;
  signature_data?: string;
  verified: boolean;
  initiated_at: string;
  answered_at?: string;
  ended_at?: string;
  duration_seconds?: number;
}

export interface RefreshToken {
  id: string;
  user_id: string;
  token_hash: string;
  expires_at: string;
  created_at: string;
}

export interface OTPRecord {
  id: string;
  phone_number: string;
  code_hash: string;
  is_used: boolean;
  attempts: number;
  created_at: string;
  expires_at: string;
}

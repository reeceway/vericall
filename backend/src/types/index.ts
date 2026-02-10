import { Request, Response, NextFunction } from 'express';
import { User } from './config/database';

// Auth types
export interface AuthenticatedRequest extends Request {
  user?: User;
}

export interface JWTPayload {
  sub: string;      // user id
  phone: string;
  type: 'access' | 'refresh';
  iat: number;
  exp: number;
}

// API Response types
export interface APIResponse<T = unknown> {
  success: boolean;
  data?: T;
  error?: string;
}

// Auth request bodies
export interface RequestOTPBody {
  phoneNumber: string;
}

export interface VerifyOTPBody {
  phoneNumber: string;
  code: string;
  publicKey: string;
  deviceId: string;
  deviceName?: string;
}

export interface RefreshTokenBody {
  refreshToken: string;
}

export interface UpdateUserBody {
  displayName?: string;
}

// Contact types
export interface ContactSyncBody {
  phoneNumbers: string[];
}

export interface ContactInfo {
  phoneNumber: string;
  userId: string;
  displayName?: string;
  publicKeyFingerprint: string;
  voiceEnrolled: boolean;
}

// Voice types
export interface VoiceEnrollBody {
  embedding: number[];  // 192 floats
  sampleCount: number;
}

export interface VoiceVerifyBody {
  embedding: number[];  // 192 floats
  callId?: string;
  targetUserId?: string;
}

export interface VoiceVerifyResponse {
  match_score: number;
  is_match: boolean;
  confidence: 'very_high' | 'high' | 'medium' | 'low' | 'very_low';
  threshold: number;
}

// Call types
export interface InitiateCallBody {
  recipientId: string;
  timestamp: number;
  nonce: string;
  signature: string;
}

export interface CallActionBody {
  callId: string;
}

export interface RecipientInfo {
  id: string;
  displayName?: string;
  socketConnected: boolean;
}

export interface InitiateCallResponse {
  callId: string;
  verified: boolean;
  recipient: RecipientInfo;
}

// WebSocket types
export interface WSMessage {
  type: string;
  [key: string]: unknown;
}

export interface WSAuthenticateMessage extends WSMessage {
  type: 'authenticate';
  token: string;
}

export interface WSCallMessage extends WSMessage {
  type: 'call:initiate' | 'call:answer' | 'call:end';
  callId?: string;
  recipientId?: string;
  signature?: string;
}

export interface WSSignalMessage extends WSMessage {
  type: 'call:ice-candidate' | 'call:sdp-offer' | 'call:sdp-answer';
  callId: string;
  candidate?: RTCIceCandidateInit;
  sdp?: string;
}

// Express middleware type
export type MiddlewareFn = (req: AuthenticatedRequest, res: Response, next: NextFunction) => void | Promise<void>;

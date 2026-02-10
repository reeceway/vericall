import jwt from 'jsonwebtoken';
import crypto from 'crypto';
import { CONSTANTS } from '../config/constants';
import { JWTPayload } from '../types';

const JWT_SECRET = process.env.JWT_SECRET || 'dev-secret-change-in-production';

/**
 * Create JWT access token
 */
export const createAccessToken = (userId: string, phone: string): string => {
  const payload: Omit<JWTPayload, 'iat' | 'exp'> = {
    sub: userId,
    phone,
    type: 'access',
  };
  
  return jwt.sign(payload, JWT_SECRET, {
    expiresIn: CONSTANTS.JWT_EXPIRES_IN,
  });
};

/**
 * Create JWT refresh token (just for validation, actual token is random)
 */
export const createRefreshToken = (): string => {
  return crypto.randomBytes(32).toString('base64url');
};

/**
 * Verify JWT token
 */
export const verifyToken = (token: string): JWTPayload | null => {
  try {
    const decoded = jwt.verify(token, JWT_SECRET) as JWTPayload;
    return decoded;
  } catch (error) {
    return null;
  }
};

/**
 * Hash refresh token for storage
 */
export const hashToken = (token: string): string => {
  return crypto.createHash('sha256').update(token).digest('hex');
};

import { Redis } from '@upstash/redis';
import dotenv from 'dotenv';

dotenv.config();

const redisUrl = process.env.UPSTASH_REDIS_URL || '';
const redisToken = process.env.UPSTASH_REDIS_TOKEN || '';

let redis: Redis | null = null;

if (redisUrl && redisToken) {
  redis = new Redis({
    url: redisUrl,
    token: redisToken,
  });
} else {
  console.warn('Warning: Upstash Redis credentials not configured');
}

export { redis };

// Redis key helpers
export const redisKeys = {
  userSession: (userId: string) => `session:user:${userId}`,
  userPresence: (userId: string) => `presence:${userId}`,
  callSession: (callId: string) => `call:${callId}`,
  wsConnection: (userId: string) => `ws:user:${userId}`,
  pushQueue: (userId: string) => `push:${userId}`,
  rateLimit: (key: string) => `ratelimit:${key}`,
  otp: (phone: string) => `otp:${phone}`,
};

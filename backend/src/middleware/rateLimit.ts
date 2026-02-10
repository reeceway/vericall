import { Response, NextFunction } from 'express';
import { redis, redisKeys } from '../config/redis';
import { AuthenticatedRequest } from '../types';

interface RateLimitConfig {
  windowMs: number;
  maxRequests: number;
}

export const createRateLimiter = (config: RateLimitConfig) => {
  return async (
    req: AuthenticatedRequest,
    res: Response,
    next: NextFunction
  ): Promise<void> => {
    if (!redis) {
      next();
      return;
    }
    
    const identifier = req.user?.id || req.ip || 'unknown';
    const key = redisKeys.rateLimit(`${req.path}:${identifier}`);
    
    try {
      const current = await redis.get(key);
      const count = current ? parseInt(current as string, 10) : 0;
      
      if (count >= config.maxRequests) {
        const ttl = await redis.ttl(key);
        res.status(429).json({
          success: false,
          error: `Rate limit exceeded. Try again in ${ttl} seconds.`,
        });
        return;
      }
      
      // Increment counter
      const pipeline = redis.pipeline();
      pipeline.incr(key);
      pipeline.expire(key, Math.floor(config.windowMs / 1000));
      await pipeline.exec();
      
      next();
    } catch (error) {
      console.error('Rate limit error:', error);
      next();
    }
  };
};

// Pre-configured rate limiters
export const otpRateLimiter = createRateLimiter({
  windowMs: 5 * 60 * 1000, // 5 minutes
  maxRequests: 5,
});

export const callRateLimiter = createRateLimiter({
  windowMs: 60 * 1000, // 1 minute
  maxRequests: 60,
});

export const voiceRateLimiter = createRateLimiter({
  windowMs: 60 * 1000, // 1 minute
  maxRequests: 20,
});

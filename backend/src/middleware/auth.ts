import { Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { AuthenticatedRequest, JWTPayload } from '../types';
import { supabase } from '../config/database';

const JWT_SECRET = process.env.JWT_SECRET || 'dev-secret-change-in-production';

export const authenticate = async (
  req: AuthenticatedRequest,
  res: Response,
  next: NextFunction
): Promise<void> => {
  try {
    const authHeader = req.headers.authorization;
    
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      res.status(401).json({ success: false, error: 'Missing authorization header' });
      return;
    }
    
    const token = authHeader.split(' ')[1];
    
    // Verify JWT
    const decoded = jwt.verify(token, JWT_SECRET) as JWTPayload;
    
    if (decoded.type !== 'access') {
      res.status(401).json({ success: false, error: 'Invalid token type' });
      return;
    }
    
    // Get user from database
    const { data: user, error } = await supabase
      .from('users')
      .select('*')
      .eq('id', decoded.sub)
      .single();
    
    if (error || !user) {
      res.status(401).json({ success: false, error: 'User not found' });
      return;
    }
    
    req.user = user;
    next();
  } catch (error) {
    if (error instanceof jwt.TokenExpiredError) {
      res.status(401).json({ success: false, error: 'Token expired' });
      return;
    }
    if (error instanceof jwt.JsonWebTokenError) {
      res.status(401).json({ success: false, error: 'Invalid token' });
      return;
    }
    res.status(500).json({ success: false, error: 'Authentication failed' });
  }
};

export const optionalAuth = async (
  req: AuthenticatedRequest,
  res: Response,
  next: NextFunction
): Promise<void> => {
  try {
    const authHeader = req.headers.authorization;
    
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      next();
      return;
    }
    
    const token = authHeader.split(' ')[1];
    const decoded = jwt.verify(token, JWT_SECRET) as JWTPayload;
    
    if (decoded.type === 'access') {
      const { data: user } = await supabase
        .from('users')
        .select('*')
        .eq('id', decoded.sub)
        .single();
      
      if (user) {
        req.user = user;
      }
    }
    
    next();
  } catch {
    next();
  }
};

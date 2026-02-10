import { WebSocketServer, WebSocket } from 'ws';
import { redis, redisKeys } from '../config/redis';
import { verifyToken } from './jwt.service';
import { WSMessage } from '../types';

// Map of userId to WebSocket connection
const connections = new Map<string, WebSocket>();

/**
 * Setup WebSocket server
 */
export const setupWebSocket = (wss: WebSocketServer): void => {
  wss.on('connection', (ws: WebSocket) => {
    let userId: string | null = null;
    
    ws.on('message', async (data: Buffer) => {
      try {
        const message = JSON.parse(data.toString()) as WSMessage;
        
        switch (message.type) {
          case 'authenticate':
            const token = (message as { token: string }).token;
            const decoded = verifyToken(token);
            
            if (!decoded || decoded.type !== 'access') {
              ws.send(JSON.stringify({
                type: 'error',
                message: 'Invalid token',
              }));
              return;
            }
            
            userId = decoded.sub;
            connections.set(userId, ws);
            
            // Update presence in Redis
            if (redis) {
              await redis.set(redisKeys.userPresence(userId), 'online', {
                ex: 300, // 5 minutes
              });
            }
            
            // Send pending notifications
            if (redis) {
              const notifications = await redis.lrange(redisKeys.pushQueue(userId), 0, -1);
              for (const notif of notifications) {
                ws.send(JSON.stringify(notif));
              }
              await redis.del(redisKeys.pushQueue(userId));
            }
            
            ws.send(JSON.stringify({
              type: 'authenticated',
              userId,
            }));
            break;
          
          case 'call:answer':
          case 'call:end':
          case 'call:ice-candidate':
          case 'call:sdp-offer':
          case 'call:sdp-answer':
            // Forward to other participant
            if (userId && message.callId) {
              await forwardCallMessage(message.callId, userId, message);
            }
            break;
          
          default:
            ws.send(JSON.stringify({
              type: 'error',
              message: `Unknown message type: ${message.type}`,
            }));
        }
      } catch (error) {
        console.error('WebSocket message error:', error);
        ws.send(JSON.stringify({
          type: 'error',
          message: 'Invalid message format',
        }));
      }
    });
    
    ws.on('close', async () => {
      if (userId) {
        connections.delete(userId);
        if (redis) {
          await redis.del(redisKeys.userPresence(userId));
        }
      }
    });
    
    ws.on('error', (error) => {
      console.error('WebSocket error:', error);
    });
  });
};

/**
 * Forward call-related message to other participant
 */
export const forwardCallMessage = async (
  callId: string,
  senderId: string,
  message: WSMessage
): Promise<void> => {
  if (!redis) return;
  
  // Get call session from Redis
  const session = await redis.get(redisKeys.callSession(callId));
  if (!session) return;
  
  const { caller_id, recipient_id } = JSON.parse(session as string);
  const targetId = senderId === caller_id ? recipient_id : caller_id;
  
  // Send to target if connected
  const targetWs = connections.get(targetId);
  if (targetWs && targetWs.readyState === WebSocket.OPEN) {
    targetWs.send(JSON.stringify(message));
  } else {
    // Queue for later delivery
    await redis.lpush(redisKeys.pushQueue(targetId), JSON.stringify(message));
  }
};

/**
 * Send message to specific user
 */
export const sendToUser = (userId: string, message: WSMessage): void => {
  const ws = connections.get(userId);
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(message));
  }
};

/**
 * Check if user is online
 */
export const isUserOnline = async (userId: string): Promise<boolean> => {
  if (!redis) return false;
  const presence = await redis.get(redisKeys.userPresence(userId));
  return presence === 'online';
};

import express from 'express';
import cors from 'cors';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import dotenv from 'dotenv';

// Routes
import authRoutes from './routes/auth.routes';
import usersRoutes from './routes/users.routes';
import contactsRoutes from './routes/contacts.routes';
import callsRoutes from './routes/calls.routes';
import voiceRoutes from './routes/voice.routes';

// Services & Middleware
import { setupWebSocket } from './services/websocket.service';
import { errorHandler, notFoundHandler } from './middleware/errorHandler';

dotenv.config();

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ server });

// Middleware
app.use(cors());
app.use(express.json({ limit: '10mb' }));

// Request logging (development)
if (process.env.NODE_ENV !== 'production') {
  app.use((req, _res, next) => {
    console.log(`${req.method} ${req.path}`);
    next();
  });
}

// Health check
app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    version: '1.0.0',
  });
});

// API Root
app.get('/', (_req, res) => {
  res.json({
    name: 'VeriCall API',
    version: '1.0.0',
    description: 'Cryptographic caller verification and voice matching',
    documentation: '/api/v1/docs',
    health: '/health',
  });
});

// API Routes v1
app.use('/api/v1/auth', authRoutes);
app.use('/api/v1/users', usersRoutes);
app.use('/api/v1/contacts', contactsRoutes);
app.use('/api/v1/calls', callsRoutes);
app.use('/api/v1/voice', voiceRoutes);

// WebSocket setup
setupWebSocket(wss);

// Error handling
app.use(notFoundHandler);
app.use(errorHandler);

const PORT = process.env.PORT || 3000;

server.listen(PORT, () => {
  console.log('🚀 VeriCall API Server');
  console.log('======================');
  console.log(`📡 HTTP: http://localhost:${PORT}`);
  console.log(`📡 WebSocket: ws://localhost:${PORT}`);
  console.log(`🏥 Health: http://localhost:${PORT}/health`);
  console.log('======================');
  console.log('Ready for connections!');
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down gracefully');
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});

process.on('SIGINT', () => {
  console.log('SIGINT received, shutting down gracefully');
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});

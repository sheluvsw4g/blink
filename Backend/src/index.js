// Main Server Entry Point
import express from 'express';
import { createServer } from 'http';
import { Server } from 'socket.io';
import cors from 'cors';
import { config } from './config/index.js';
import { PrismaClient } from '@prisma/client';
import authRoutes from './routes/auth.js';
import userRoutes from './routes/users.js';
import conversationRoutes from './routes/conversations.js';
import messageRoutes from './routes/messages.js';
import callRoutes from './routes/calls.js';
import uploadRoutes from './routes/upload.js';
import { authenticateSocket } from './middleware/auth.js';
import { setupCallSignaling } from './services/callSignaling.js';
import { setupMessageHandling } from './services/messageHandler.js';

export const prisma = new PrismaClient({
  log: config.nodeEnv === 'development' ? ['query', 'error', 'warn'] : ['error'],
});

const app = express();
const httpServer = createServer(app);

// Socket.io with CORS
export const io = new Server(httpServer, {
  cors: {
    origin: config.corsOrigin,
    methods: ['GET', 'POST'],
    credentials: true,
  },
  // Ping interval for connection health
  pingInterval: 25000,
  pingTimeout: 20000,
});

// Middleware
app.use(cors({ origin: config.corsOrigin, credentials: true }));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// API Routes
app.use('/api/auth', authRoutes);
app.use('/api/users', userRoutes);
app.use('/api/conversations', conversationRoutes);
app.use('/api/messages', messageRoutes);
app.use('/api/calls', callRoutes);
app.use('/api/upload', uploadRoutes);

// Socket.io authentication middleware
io.use(authenticateSocket);

// Socket.io connection handling
io.on('connection', (socket) => {
  console.log(`User connected: ${socket.user.id} (${socket.id})`);
  
  // Join user's personal room for direct events
  socket.join(`user:${socket.user.id}`);
  
  // Join conversation rooms
  socket.on('join:conversation', (conversationId) => {
    socket.join(`conversation:${conversationId}`);
    console.log(`User ${socket.user.id} joined conversation ${conversationId}`);
  });
  
  socket.on('leave:conversation', (conversationId) => {
    socket.leave(`conversation:${conversationId}`);
  });
  
  // Typing indicators
  socket.on('typing:start', (conversationId) => {
    socket.to(`conversation:${conversationId}`).emit('user:typing', {
      userId: socket.user.id,
      conversationId,
    });
  });
  
  socket.on('typing:stop', (conversationId) => {
    socket.to(`conversation:${conversationId}`).emit('user:stopped_typing', {
      userId: socket.user.id,
      conversationId,
    });
  });
  
  // Mark messages as read
  socket.on('messages:read', async (data) => {
    try {
      await setupMessageHandling.markAsRead(socket.user.id, data.conversationId, data.messageIds);
      socket.to(`conversation:${data.conversationId}`).emit('messages:read', {
        userId: socket.user.id,
        messageIds: data.messageIds,
      });
    } catch (error) {
      console.error('Mark read error:', error);
    }
  });
  
  // Setup call signaling (WebRTC)
  setupCallSignaling(io, socket);
  
  // Setup message handling
  setupMessageHandling(io, socket);
  
  // Update online status
  socket.on('status:update', async (status) => {
    try {
      await prisma.user.update({
        where: { id: socket.user.id },
        data: { isOnline: status === 'online', lastSeen: new Date() },
      });
      socket.broadcast.emit('user:status', { userId: socket.user.id, status });
    } catch (error) {
      console.error('Status update error:', error);
    }
  });
  
  socket.on('disconnect', async (reason) => {
    console.log(`User disconnected: ${socket.user.id} - ${reason}`);
    try {
      await prisma.user.update({
        where: { id: socket.user.id },
        data: { isOnline: false, lastSeen: new Date() },
      });
      socket.broadcast.emit('user:status', { userId: socket.user.id, status: 'offline' });
    } catch (error) {
      console.error('Disconnect error:', error);
    }
  });
});

// Error handling middleware
app.use((err, req, res, next) => {
  console.error('Server error:', err);
  res.status(500).json({ 
    error: 'Internal server error',
    message: config.nodeEnv === 'development' ? err.message : undefined,
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('SIGTERM received, shutting down gracefully...');
  httpServer.close(async () => {
    await prisma.$disconnect();
    process.exit(0);
  });
});

httpServer.listen(config.port, () => {
  console.log(`
╔══════════════════════════════════════════════════════════╗
║  Blink Messenger Backend                                 ║
║  Running on http://localhost:${config.port}                    ║
║  Environment: ${config.nodeEnv}                               ║
║  WebSocket: Ready                                        ║
╚══════════════════════════════════════════════════════════╝
  `);
});

export { app, httpServer };
// Socket.io Authentication Middleware
import jwt from 'jsonwebtoken';
import { config } from '../config/index.js';
import { prisma } from '../index.js';

export const authenticateSocket = async (socket, next) => {
  try {
    // Token can be in auth object or query string
    const token = socket.handshake.auth?.token || socket.handshake.query?.token;
    
    if (!token) {
      return next(new Error('Authentication required'));
    }
    
    const decoded = jwt.verify(token, config.jwtSecret);
    
    const user = await prisma.user.findUnique({
      where: { id: decoded.userId },
      select: { id: true, phoneNumber: true, name: true, avatarUrl: true, isOnline: true },
    });
    
    if (!user) {
      return next(new Error('User not found'));
    }
    
    socket.user = user;
    next();
  } catch (error) {
    if (error.name === 'TokenExpiredError') {
      return next(new Error('Token expired'));
    }
    if (error.name === 'JsonWebTokenError') {
      return next(new Error('Invalid token'));
    }
    console.error('Socket auth error:', error);
    next(new Error('Authentication failed'));
  }
};
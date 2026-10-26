// Auth Routes - Phone Number Registration & Login
import express from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { prisma } from '../index.js';
import { generateTokens, verifyRefreshToken } from '../middleware/auth.js';
import { config } from '../config/index.js';

const router = express.Router();

// Validation schemas
const phoneSchema = z.string().regex(/^\+?[1-9]\d{1,14}$/, 'Invalid phone number format');
const codeSchema = z.string().length(6, 'Code must be 6 digits');
const nameSchema = z.string().min(1).max(50).optional();

// In-memory store for verification codes (use Redis in production)
const verificationCodes = new Map();

// Generate 6-digit code
const generateCode = () => Math.floor(100000 + Math.random() * 900000).toString();

// Send SMS (replace with real provider in production)
const sendSMS = async (phoneNumber, code) => {
  if (config.smsProvider === 'twilio' && config.twilio.accountSid) {
    // TODO: Implement Twilio
    // const twilio = require('twilio')(config.twilio.accountSid, config.twilio.authToken);
    // await twilio.messages.create({ body: `Your Blink code: ${code}`, from: config.twilio.fromNumber, to: phoneNumber });
  } else {
    // Development mode - log to console
    console.log(`
╔═══════════════════════════════════════════╗
║  SMS VERIFICATION CODE                   ║
║  To: ${phoneNumber.padEnd(34)}║
║  Code: ${code.padEnd(34)}║
╚═══════════════════════════════════════════╝
    `);
  }
};

// Request verification code
router.post('/send-code', async (req, res) => {
  try {
    const { phoneNumber } = phoneSchema.parse(req.body);
    
    // Check rate limiting (max 3 codes per hour)
    const existing = verificationCodes.get(phoneNumber);
    if (existing && existing.attempts >= 3 && Date.now() < existing.expiresAt) {
      return res.status(429).json({ error: 'Too many requests. Try again later.' });
    }
    
    const code = generateCode();
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000); // 5 minutes
    
    verificationCodes.set(phoneNumber, {
      code,
      expiresAt,
      attempts: (existing?.attempts || 0) + 1,
    });
    
    await sendSMS(phoneNumber, code);
    
    res.json({ success: true, message: 'Code sent' });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Send code error:', error);
    res.status(500).json({ error: 'Failed to send code' });
  }
});

// Verify code and register/login
router.post('/verify-code', async (req, res) => {
  try {
    const { phoneNumber, code, name } = req.body;
    
    phoneSchema.parse(phoneNumber);
    codeSchema.parse(code);
    if (name) nameSchema.parse(name);
    
    const stored = verificationCodes.get(phoneNumber);
    
    if (!stored) {
      return res.status(400).json({ error: 'Code not found or expired' });
    }
    
    if (Date.now() > stored.expiresAt) {
      verificationCodes.delete(phoneNumber);
      return res.status(400).json({ error: 'Code expired' });
    }
    
    if (stored.code !== code) {
      return res.status(400).json({ error: 'Invalid code' });
    }
    
    // Code verified - delete it
    verificationCodes.delete(phoneNumber);
    
    // Find or create user
    let user = await prisma.user.findUnique({ where: { phoneNumber } });
    
    if (!user) {
      // New user registration
      user = await prisma.user.create({
        data: {
          phoneNumber,
          name: name || `User ${phoneNumber.slice(-4)}`,
        },
      });
    } else if (name && !user.name) {
      // Update name if provided and not set
      user = await prisma.user.update({
        where: { id: user.id },
        data: { name },
      });
    }
    
    // Generate tokens
    const { accessToken, refreshToken } = generateTokens(user.id);
    
    // Store refresh token hash (in production, use secure storage)
    const refreshTokenHash = await bcrypt.hash(refreshToken, 10);
    await prisma.user.update({
      where: { id: user.id },
      data: { 
        // You could add a refreshTokenHash field to User model
      },
    });
    
    res.json({
      user: {
        id: user.id,
        phoneNumber: user.phoneNumber,
        name: user.name,
        avatarUrl: user.avatarUrl,
      },
      accessToken,
      refreshToken,
    });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Verify code error:', error);
    res.status(500).json({ error: 'Verification failed' });
  }
});

// Refresh access token
router.post('/refresh', async (req, res) => {
  try {
    const { refreshToken } = req.body;
    
    if (!refreshToken) {
      return res.status(400).json({ error: 'Refresh token required' });
    }
    
    const decoded = verifyRefreshToken(refreshToken);
    if (!decoded || decoded.type !== 'refresh') {
      return res.status(401).json({ error: 'Invalid refresh token' });
    }
    
    const user = await prisma.user.findUnique({
      where: { id: decoded.userId },
      select: { id: true },
    });
    
    if (!user) {
      return res.status(401).json({ error: 'User not found' });
    }
    
    const tokens = generateTokens(user.id);
    res.json(tokens);
  } catch (error) {
    console.error('Refresh token error:', error);
    res.status(500).json({ error: 'Token refresh failed' });
  }
});

// Get current user profile
router.get('/me', async (req, res) => {
  try {
    // This requires the authenticate middleware
    // Will be used with: router.get('/me', authenticate, handler)
    res.json({ user: req.user });
  } catch (error) {
    console.error('Get profile error:', error);
    res.status(500).json({ error: 'Failed to get profile' });
  }
});

// Update profile
router.patch('/me', async (req, res) => {
  try {
    const { name, bio, avatarUrl } = req.body;
    const userId = req.user.id;
    
    const user = await prisma.user.update({
      where: { id: userId },
      data: {
        name: name?.trim() || undefined,
        bio: bio?.trim() || undefined,
        avatarUrl: avatarUrl || undefined,
      },
      select: { id: true, phoneNumber: true, name: true, avatarUrl: true, bio: true },
    });
    
    res.json({ user });
  } catch (error) {
    console.error('Update profile error:', error);
    res.status(500).json({ error: 'Failed to update profile' });
  }
});

// Register device for push notifications
router.post('/device', async (req, res) => {
  try {
    const { token, platform } = req.body;
    const userId = req.user.id;
    
    if (!token || !platform) {
      return res.status(400).json({ error: 'Token and platform required' });
    }
    
    await prisma.device.upsert({
      where: { token },
      create: { userId, token, platform },
      update: { userId, platform },
    });
    
    res.json({ success: true });
  } catch (error) {
    console.error('Register device error:', error);
    res.status(500).json({ error: 'Failed to register device' });
  }
});

// Logout - invalidate refresh token (implement token blacklist in production)
router.post('/logout', async (req, res) => {
  // In production: add token to blacklist/redis
  res.json({ success: true, message: 'Logged out' });
});

export default router;
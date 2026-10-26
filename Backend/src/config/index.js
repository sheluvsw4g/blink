// Backend Configuration
import 'dotenv/config';

export const config = {
  // Server
  port: parseInt(process.env.PORT || '3000'),
  nodeEnv: process.env.NODE_ENV || 'development',
  
  // Database
  databaseUrl: process.env.DATABASE_URL || 'postgresql://postgres:postgres@localhost:5432/blink_messenger',
  
  // JWT
  jwtSecret: process.env.JWT_SECRET || 'your-super-secret-jwt-key-change-in-production',
  jwtExpiresIn: '7d',
  jwtRefreshExpiresIn: '30d',
  
  // SMS (configure your provider: Twilio, Vonage, etc.)
  smsProvider: process.env.SMS_PROVIDER || 'console', // 'console' for dev, 'twilio' for prod
  twilio: {
    accountSid: process.env.TWILIO_ACCOUNT_SID,
    authToken: process.env.TWILIO_AUTH_TOKEN,
    fromNumber: process.env.TWILIO_FROM_NUMBER,
  },
  
  // WebRTC / STUN/TURN
  iceServers: [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun1.l.google.com:19302' },
    // Add your TURN servers here for production:
    // {
    //   urls: 'turn:your-turn-server.com:3478',
    //   username: process.env.TURN_USERNAME,
    //   credential: process.env.TURN_PASSWORD
    // }
  ],
  
  // File Upload
  uploadDir: process.env.UPLOAD_DIR || './uploads',
  maxFileSize: 50 * 1024 * 1024, // 50MB
  
  // CORS
  corsOrigin: process.env.CORS_ORIGIN || '*',
  
  // Rate Limiting
  rateLimit: {
    windowMs: 15 * 60 * 1000, // 15 minutes
    maxRequests: 100,
  },
  
  // Push Notifications (APNs)
  apns: {
    keyId: process.env.APNS_KEY_ID,
    teamId: process.env.APNS_TEAM_ID,
    bundleId: process.env.APNS_BUNDLE_ID || 'com.blink.messenger',
    keyPath: process.env.APNS_KEY_PATH, // Path to .p8 file
    production: process.env.APNS_PRODUCTION === 'true',
  },
};
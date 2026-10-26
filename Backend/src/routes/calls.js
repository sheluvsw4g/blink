// Call Routes - REST API for call history and management
import express from 'express';
import { z } from 'zod';
import { prisma } from '../index.js';
import { authenticate } from '../middleware/auth.js';

const router = express.Router();
router.use(authenticate);

// Get call history
router.get('/history', async (req, res) => {
  try {
    const { limit = '50', offset = '0', type } = req.query;
    
    const where = {
      OR: [{ initiatorId: req.user.id }, { receiverId: req.user.id }],
    };
    
    if (type) where.type = type;
    
    const calls = await prisma.call.findMany({
      where,
      include: {
        initiator: { select: { id: true, name: true, avatarUrl: true } },
        receiver: { select: { id: true, name: true, avatarUrl: true } },
        conversation: { select: { id: true, type: true, name: true } },
      },
      orderBy: { createdAt: 'desc' },
      take: parseInt(limit),
      skip: parseInt(offset),
    });
    
    res.json({ calls });
  } catch (error) {
    console.error('Get call history error:', error);
    res.status(500).json({ error: 'Failed to get call history' });
  }
});

// Get call details
router.get('/:callId', async (req, res) => {
  try {
    const call = await prisma.call.findFirst({
      where: {
        id: req.params.callId,
        OR: [{ initiatorId: req.user.id }, { receiverId: req.user.id }],
      },
      include: {
        initiator: { select: { id: true, name: true, avatarUrl: true } },
        receiver: { select: { id: true, name: true, avatarUrl: true } },
        conversation: { select: { id: true, type: true, name: true } },
      },
    });
    
    if (!call) {
      return res.status(404).json({ error: 'Call not found' });
    }
    
    res.json({ call });
  } catch (error) {
    console.error('Get call error:', error);
    res.status(500).json({ error: 'Failed to get call' });
  }
});

// Initiate call (creates call record, signaling handled via WebSocket)
router.post('/initiate', async (req, res) => {
  try {
    const { conversationId, receiverId, type } = z.object({
      conversationId: z.string().uuid(),
      receiverId: z.string().uuid(),
      type: z.enum(['VOICE', 'VIDEO']),
    }).parse(req.body);
    
    // Verify conversation access
    const conversation = await prisma.conversation.findFirst({
      where: {
        id: conversationId,
        participants: {
          every: { userId: { in: [req.user.id, receiverId] }, leftAt: null },
        },
      },
    });
    
    if (!conversation) {
      return res.status(404).json({ error: 'Conversation not found' });
    }
    
    // Check if receiver is blocked
    const blocked = await prisma.blockedUser.findFirst({
      where: {
        OR: [
          { blockerId: req.user.id, blockedId: receiverId },
          { blockerId: receiverId, blockedId: req.user.id },
        ],
      },
    });
    
    if (blocked) {
      return res.status(403).json({ error: 'Cannot call this user' });
    }
    
    // Check for existing active call
    const activeCall = await prisma.call.findFirst({
      where: {
        conversationId,
        status: { in: ['INITIATED', 'RINGING', 'ANSWERED'] },
      },
    });
    
    if (activeCall) {
      return res.status(409).json({ error: 'Active call already exists', callId: activeCall.id });
    }
    
    // Create call record
    const call = await prisma.call.create({
      data: {
        conversationId,
        initiatorId: req.user.id,
        receiverId,
        type,
        status: 'INITIATED',
      },
      include: {
        initiator: { select: { id: true, name: true, avatarUrl: true } },
        receiver: { select: { id: true, name: true, avatarUrl: true } },
      },
    });
    
    // Signaling will be handled via WebSocket
    // The client should listen for 'call:incoming' on the receiver's socket
    
    res.status(201).json({ call });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Initiate call error:', error);
    res.status(500).json({ error: 'Failed to initiate call' });
  }
});

// Update call status (answer, reject, end)
router.patch('/:callId/status', async (req, res) => {
  try {
    const { status } = z.object({
      status: z.enum(['ANSWERED', 'REJECTED', 'ENDED', 'MISSED', 'FAILED']),
    }).parse(req.body);
    
    const call = await prisma.call.findFirst({
      where: {
        id: req.params.callId,
        OR: [{ initiatorId: req.user.id }, { receiverId: req.user.id }],
      },
    });
    
    if (!call) {
      return res.status(404).json({ error: 'Call not found' });
    }
    
    const now = new Date();
    const updateData = { status };
    
    if (status === 'ANSWERED' && !call.answeredAt) {
      updateData.answeredAt = now;
      updateData.startedAt = now;
    }
    
    if (['ENDED', 'REJECTED', 'MISSED', 'FAILED'].includes(status)) {
      updateData.endedAt = now;
      if (call.startedAt) {
        updateData.duration = Math.floor((now - call.startedAt) / 1000);
      }
    }
    
    const updated = await prisma.call.update({
      where: { id: call.id },
      data: updateData,
    });
    
    // Create call log message in conversation
    if (['ENDED', 'MISSED', 'REJECTED'].includes(status)) {
      await prisma.message.create({
        data: {
          conversationId: call.conversationId,
          senderId: req.user.id,
          type: 'CALL_LOG',
          content: JSON.stringify({
            callId: call.id,
            type: call.type,
            status: updated.status,
            duration: updated.duration,
            initiatorId: call.initiatorId,
          }),
        },
      });
    }
    
    // io.to(`conversation:${call.conversationId}`).emit('call:status', updated);
    
    res.json({ call: updated });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Update call status error:', error);
    res.status(500).json({ error: 'Failed to update call status' });
  }
});

// Get ICE servers for WebRTC
router.get('/ice-servers', async (req, res) => {
  try {
    // In production, generate TURN credentials with TTL
    // For now, return configured STUN servers
    const { config } = await import('../config/index.js');
    res.json({ iceServers: config.iceServers });
  } catch (error) {
    console.error('Get ICE servers error:', error);
    res.status(500).json({ error: 'Failed to get ICE servers' });
  }
});

export default router;
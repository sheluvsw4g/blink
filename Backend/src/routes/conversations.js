// Conversation Routes
import express from 'express';
import { z } from 'zod';
import { prisma } from '../index.js';
import { authenticate } from '../middleware/auth.js';

const router = express.Router();
router.use(authenticate);

// Get all conversations for current user
router.get('/', async (req, res) => {
  try {
    const { limit = '50', offset = '0' } = req.query;
    
    const conversations = await prisma.conversation.findMany({
      where: {
        participants: {
          some: { userId: req.user.id, leftAt: null },
        },
      },
      include: {
        participants: {
          where: { leftAt: null },
          include: {
            user: {
              select: { id: true, phoneNumber: true, name: true, avatarUrl: true, isOnline: true, lastSeen: true },
            },
          },
        },
        messages: {
          take: 1,
          orderBy: { createdAt: 'desc' },
          select: {
            id: true,
            type: true,
            content: true,
            mediaUrl: true,
            senderId: true,
            createdAt: true,
            statuses: { where: { userId: req.user.id }, select: { status: true } },
          },
        },
      },
      orderBy: { updatedAt: 'desc' },
      take: parseInt(limit),
      skip: parseInt(offset),
    });
    
    // Format response
    const formatted = conversations.map(conv => {
      const lastMessage = conv.messages[0] || null;
      const otherParticipants = conv.participants.filter(p => p.userId !== req.user.id);
      
      return {
        id: conv.id,
        type: conv.type,
        name: conv.name,
        avatarUrl: conv.avatarUrl,
        participants: conv.participants.map(p => p.user),
        lastMessage: lastMessage ? {
          id: lastMessage.id,
          type: lastMessage.type,
          content: lastMessage.content,
          mediaUrl: lastMessage.mediaUrl,
          senderId: lastMessage.senderId,
          createdAt: lastMessage.createdAt,
          status: lastMessage.statuses[0]?.status || 'SENT',
        } : null,
        unreadCount: 0, // TODO: Calculate unread count
        updatedAt: conv.updatedAt,
      };
    });
    
    res.json({ conversations: formatted });
  } catch (error) {
    console.error('Get conversations error:', error);
    res.status(500).json({ error: 'Failed to get conversations' });
  }
});

// Create or get private conversation
router.post('/private', async (req, res) => {
  try {
    const { userId } = z.object({ userId: z.string().uuid() }).parse(req.body);
    
    if (userId === req.user.id) {
      return res.status(400).json({ error: 'Cannot create conversation with yourself' });
    }
    
    const otherUser = await prisma.user.findUnique({ where: { id: userId } });
    if (!otherUser) {
      return res.status(404).json({ error: 'User not found' });
    }
    
    // Check if blocked
    const blocked = await prisma.blockedUser.findFirst({
      where: {
        OR: [
          { blockerId: req.user.id, blockedId: userId },
          { blockerId: userId, blockedId: req.user.id },
        ],
      },
    });
    
    if (blocked) {
      return res.status(403).json({ error: 'Cannot create conversation' });
    }
    
    // Find existing private conversation
    const existing = await prisma.conversation.findFirst({
      where: {
        type: 'PRIVATE',
        participants: {
          every: { userId: { in: [req.user.id, userId] }, leftAt: null },
        },
      },
      include: {
        participants: {
          where: { leftAt: null },
          include: { user: { select: { id: true, phoneNumber: true, name: true, avatarUrl: true, isOnline: true } } },
        },
      },
    });
    
    if (existing) {
      return res.json({ conversation: existing });
    }
    
    // Create new conversation
    const conversation = await prisma.conversation.create({
      data: {
        type: 'PRIVATE',
        participants: {
          create: [
            { userId: req.user.id, role: 'MEMBER' },
            { userId, role: 'MEMBER' },
          ],
        },
      },
      include: {
        participants: {
          include: { user: { select: { id: true, phoneNumber: true, name: true, avatarUrl: true, isOnline: true } } },
        },
      },
    });
    
    res.status(201).json({ conversation });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Create private conversation error:', error);
    res.status(500).json({ error: 'Failed to create conversation' });
  }
});

// Create group conversation
router.post('/group', async (req, res) => {
  try {
    const { name, participantIds, avatarUrl } = z.object({
      name: z.string().min(1).max(100),
      participantIds: z.array(z.string().uuid()).min(1).max(100),
      avatarUrl: z.string().url().optional(),
    }).parse(req.body);
    
    // Validate all participants exist
    const users = await prisma.user.findMany({
      where: { id: { in: participantIds } },
      select: { id: true },
    });
    
    if (users.length !== participantIds.length) {
      return res.status(400).json({ error: 'Some users not found' });
    }
    
    // Ensure current user is included
    const allParticipantIds = [...new Set([req.user.id, ...participantIds])];
    
    const conversation = await prisma.conversation.create({
      data: {
        type: 'GROUP',
        name,
        avatarUrl,
        participants: {
          create: allParticipantIds.map((id, index) => ({
            userId: id,
            role: id === req.user.id ? 'ADMIN' : 'MEMBER',
          })),
        },
      },
      include: {
        participants: {
          include: { user: { select: { id: true, phoneNumber: true, name: true, avatarUrl: true, isOnline: true } } },
        },
      },
    });
    
    res.status(201).json({ conversation });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Create group error:', error);
    res.status(500).json({ error: 'Failed to create group' });
  }
});

// Get conversation by ID
router.get('/:conversationId', async (req, res) => {
  try {
    const conversation = await prisma.conversation.findFirst({
      where: {
        id: req.params.conversationId,
        participants: { some: { userId: req.user.id, leftAt: null } },
      },
      include: {
        participants: {
          where: { leftAt: null },
          include: { user: { select: { id: true, phoneNumber: true, name: true, avatarUrl: true, isOnline: true, lastSeen: true } } },
        },
      },
    });
    
    if (!conversation) {
      return res.status(404).json({ error: 'Conversation not found' });
    }
    
    res.json({ conversation });
  } catch (error) {
    console.error('Get conversation error:', error);
    res.status(500).json({ error: 'Failed to get conversation' });
  }
});

// Update group conversation
router.patch('/:conversationId', async (req, res) => {
  try {
    const { name, avatarUrl } = z.object({
      name: z.string().min(1).max(100).optional(),
      avatarUrl: z.string().url().optional(),
    }).parse(req.body);
    
    const conversation = await prisma.conversation.findFirst({
      where: {
        id: req.params.conversationId,
        type: 'GROUP',
        participants: { some: { userId: req.user.id, role: 'ADMIN', leftAt: null } },
      },
    });
    
    if (!conversation) {
      return res.status(403).json({ error: 'Not authorized or not a group' });
    }
    
    const updated = await prisma.conversation.update({
      where: { id: conversation.id },
      data: { name, avatarUrl },
      include: {
        participants: {
          where: { leftAt: null },
          include: { user: { select: { id: true, phoneNumber: true, name: true, avatarUrl: true, isOnline: true } } },
        },
      },
    });
    
    // Notify participants via socket
    // io.to(`conversation:${conversation.id}`).emit('conversation:updated', updated);
    
    res.json({ conversation: updated });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Update conversation error:', error);
    res.status(500).json({ error: 'Failed to update conversation' });
  }
});

// Add participants to group
router.post('/:conversationId/participants', async (req, res) => {
  try {
    const { userIds } = z.object({ userIds: z.array(z.string().uuid()).min(1) }).parse(req.body);
    
    const conversation = await prisma.conversation.findFirst({
      where: {
        id: req.params.conversationId,
        type: 'GROUP',
        participants: { some: { userId: req.user.id, role: 'ADMIN', leftAt: null } },
      },
    });
    
    if (!conversation) {
      return res.status(403).json({ error: 'Not authorized or not a group' });
    }
    
    const newParticipants = await prisma.conversationParticipant.createMany({
      data: userIds.map(userId => ({
        conversationId: conversation.id,
        userId,
        role: 'MEMBER',
      })),
      skipDuplicates: true,
    });
    
    // Fetch full participant info
    const participants = await prisma.conversationParticipant.findMany({
      where: { conversationId: conversation.id, userId: { in: userIds } },
      include: { user: { select: { id: true, phoneNumber: true, name: true, avatarUrl: true, isOnline: true } } },
    });
    
    res.status(201).json({ participants, added: newParticipants.count });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Add participants error:', error);
    res.status(500).json({ error: 'Failed to add participants' });
  }
});

// Remove participant from group
router.delete('/:conversationId/participants/:userId', async (req, res) => {
  try {
    const { conversationId, userId } = req.params;
    const isSelf = userId === req.user.id;
    
    const conversation = await prisma.conversation.findFirst({
      where: {
        id: conversationId,
        type: 'GROUP',
        participants: { some: { userId: req.user.id, leftAt: null } },
      },
    });
    
    if (!conversation) {
      return res.status(404).json({ error: 'Conversation not found' });
    }
    
    const participant = await prisma.conversationParticipant.findUnique({
      where: { conversationId_userId: { conversationId, userId } },
    });
    
    if (!participant) {
      return res.status(404).json({ error: 'Participant not found' });
    }
    
    // Check permissions
    const requesterParticipant = await prisma.conversationParticipant.findUnique({
      where: { conversationId_userId: { conversationId, userId: req.user.id } },
    });
    
    if (!isSelf && requesterParticipant?.role !== 'ADMIN') {
      return res.status(403).json({ error: 'Not authorized' });
    }
    
    await prisma.conversationParticipant.update({
      where: { conversationId_userId: { conversationId, userId } },
      data: { leftAt: new Date() },
    });
    
    res.json({ success: true });
  } catch (error) {
    console.error('Remove participant error:', error);
    res.status(500).json({ error: 'Failed to remove participant' });
  }
});

// Leave conversation
router.post('/:conversationId/leave', async (req, res) => {
  try {
    const { conversationId } = req.params;
    
    const participant = await prisma.conversationParticipant.findUnique({
      where: { conversationId_userId: { conversationId, userId: req.user.id } },
    });
    
    if (!participant) {
      return res.status(404).json({ error: 'Not a participant' });
    }
    
    await prisma.conversationParticipant.update({
      where: { conversationId_userId: { conversationId, userId: req.user.id } },
      data: { leftAt: new Date() },
    });
    
    // If group and admin leaving, promote another member
    const conversation = await prisma.conversation.findUnique({
      where: { id: conversationId },
      include: { participants: { where: { leftAt: null, role: 'ADMIN' } } },
    });
    
    if (conversation?.type === 'GROUP' && participant.role === 'ADMIN') {
      const remainingAdmins = conversation.participants.length;
      if (remainingAdmins === 0) {
        const newAdmin = await prisma.conversationParticipant.findFirst({
          where: { conversationId, leftAt: null, userId: { not: req.user.id } },
        });
        if (newAdmin) {
          await prisma.conversationParticipant.update({
            where: { id: newAdmin.id },
            data: { role: 'ADMIN' },
          });
        }
      }
    }
    
    res.json({ success: true });
  } catch (error) {
    console.error('Leave conversation error:', error);
    res.status(500).json({ error: 'Failed to leave conversation' });
  }
});

// Delete conversation (only for private, or group if admin and last member)
router.delete('/:conversationId', async (req, res) => {
  try {
    const conversation = await prisma.conversation.findFirst({
      where: {
        id: req.params.conversationId,
        participants: { some: { userId: req.user.id, leftAt: null } },
      },
    });
    
    if (!conversation) {
      return res.status(404).json({ error: 'Conversation not found' });
    }
    
    if (conversation.type === 'PRIVATE') {
      // For private, just mark as left for current user
      await prisma.conversationParticipant.update({
        where: { conversationId_userId: { conversationId: conversation.id, userId: req.user.id } },
        data: { leftAt: new Date() },
      });
    } else {
      // For group, only admin can delete if they're the last member
      const participant = await prisma.conversationParticipant.findUnique({
        where: { conversationId_userId: { conversationId: conversation.id, userId: req.user.id } },
      });
      
      if (participant?.role !== 'ADMIN') {
        return res.status(403).json({ error: 'Only admin can delete group' });
      }
      
      const remaining = await prisma.conversationParticipant.count({
        where: { conversationId: conversation.id, leftAt: null },
      });
      
      if (remaining > 1) {
        return res.status(400).json({ error: 'Remove all members first' });
      }
      
      // Delete everything
      await prisma.conversation.delete({ where: { id: conversation.id } });
    }
    
    res.json({ success: true });
  } catch (error) {
    console.error('Delete conversation error:', error);
    res.status(500).json({ error: 'Failed to delete conversation' });
  }
});

export default router;
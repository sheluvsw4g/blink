// Message Routes
import express from 'express';
import { z } from 'zod';
import { prisma } from '../index.js';
import { authenticate } from '../middleware/auth.js';

const router = express.Router();
router.use(authenticate);

// Get messages for a conversation
router.get('/:conversationId', async (req, res) => {
  try {
    const { conversationId } = req.params;
    const { limit = '50', before, after } = req.query;
    
    // Verify access
    const participant = await prisma.conversationParticipant.findUnique({
      where: { conversationId_userId: { conversationId, userId: req.user.id } },
    });
    
    if (!participant || participant.leftAt) {
      return res.status(403).json({ error: 'Not a participant' });
    }
    
    const where = {
      conversationId,
      isDeleted: false,
    };
    
    if (before) {
      where.createdAt = { lt: new Date(before) };
    }
    if (after) {
      where.createdAt = { ...where.createdAt, gt: new Date(after) };
    }
    
    const messages = await prisma.message.findMany({
      where,
      include: {
        sender: { select: { id: true, name: true, avatarUrl: true } },
        replyTo: {
          select: { id: true, type: true, content: true, mediaUrl: true, senderId: true },
        },
        statuses: {
          select: { userId: true, status: true },
        },
      },
      orderBy: { createdAt: 'desc' },
      take: parseInt(limit) + 1, // Fetch one extra to check if there are more
    });
    
    const hasMore = messages.length > parseInt(limit);
    const result = hasMore ? messages.slice(0, -1) : messages;
    
    // Mark as delivered
    const messageIds = result.map(m => m.id);
    await prisma.messageStatus.upsertMany(
      messageIds.map(messageId => ({
        where: { messageId_userId: { messageId, userId: req.user.id } },
        create: { messageId, userId: req.user.id, status: 'DELIVERED' },
        update: { status: 'DELIVERED' },
      }))
    );
    
    // Update last read timestamp
    await prisma.conversationParticipant.update({
      where: { conversationId_userId: { conversationId, userId: req.user.id } },
      data: { lastReadAt: new Date() },
    });
    
    res.json({
      messages: result.reverse(), // Return in chronological order
      hasMore,
    });
  } catch (error) {
    console.error('Get messages error:', error);
    res.status(500).json({ error: 'Failed to get messages' });
  }
});

// Send message
router.post('/', async (req, res) => {
  try {
    const data = z.object({
      conversationId: z.string().uuid(),
      type: z.enum(['TEXT', 'IMAGE', 'VIDEO', 'AUDIO', 'DOCUMENT', 'VOICE_MESSAGE', 'VIDEO_MESSAGE', 'LOCATION', 'CONTACT']).default('TEXT'),
      content: z.string().max(10000).optional(),
      mediaUrl: z.string().url().optional(),
      mediaType: z.string().optional(),
      mediaSize: z.number().int().positive().optional(),
      duration: z.number().int().positive().optional(),
      replyToId: z.string().uuid().optional(),
    }).parse(req.body);
    
    // Verify access
    const participant = await prisma.conversationParticipant.findUnique({
      where: { conversationId_userId: { conversationId: data.conversationId, userId: req.user.id } },
    });
    
    if (!participant || participant.leftAt) {
      return res.status(403).json({ error: 'Not a participant' });
    }
    
    // Validate replyTo exists in same conversation
    if (data.replyToId) {
      const replyTo = await prisma.message.findFirst({
        where: { id: data.replyToId, conversationId: data.conversationId },
      });
      if (!replyTo) {
        return res.status(400).json({ error: 'Reply message not found' });
      }
    }
    
    // Create message
    const message = await prisma.message.create({
      data: {
        conversationId: data.conversationId,
        senderId: req.user.id,
        type: data.type,
        content: data.content,
        mediaUrl: data.mediaUrl,
        mediaType: data.mediaType,
        mediaSize: data.mediaSize,
        duration: data.duration,
        replyToId: data.replyToId,
      },
      include: {
        sender: { select: { id: true, name: true, avatarUrl: true } },
        replyTo: {
          select: { id: true, type: true, content: true, mediaUrl: true, senderId: true },
        },
      },
    });
    
    // Create status for sender (SENT)
    await prisma.messageStatus.create({
      data: { messageId: message.id, userId: req.user.id, status: 'SENT' },
    });
    
    // Create status for other participants (PENDING -> will be DELIVERED when they receive)
    const otherParticipants = await prisma.conversationParticipant.findMany({
      where: { conversationId: data.conversationId, userId: { not: req.user.id }, leftAt: null },
      select: { userId: true },
    });
    
    await prisma.messageStatus.createMany({
      data: otherParticipants.map(p => ({ messageId: message.id, userId: p.userId, status: 'SENT' })),
      skipDuplicates: true,
    });
    
    // Update conversation updatedAt
    await prisma.conversation.update({
      where: { id: data.conversationId },
      data: { updatedAt: new Date() },
    });
    
    // Emit via socket (handled in socket service)
    // io.to(`conversation:${data.conversationId}`).emit('message:new', message);
    
    res.status(201).json({ message });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Send message error:', error);
    res.status(500).json({ error: 'Failed to send message' });
  }
});

// Edit message
router.patch('/:messageId', async (req, res) => {
  try {
    const { content } = z.object({ content: z.string().min(1).max(10000) }).parse(req.body);
    
    const message = await prisma.message.findFirst({
      where: { id: req.params.messageId, senderId: req.user.id, isDeleted: false },
    });
    
    if (!message) {
      return res.status(404).json({ error: 'Message not found or not yours' });
    }
    
    // Can only edit within 15 minutes
    if (Date.now() - message.createdAt.getTime() > 15 * 60 * 1000) {
      return res.status(400).json({ error: 'Edit time expired' });
    }
    
    const updated = await prisma.message.update({
      where: { id: message.id },
      data: { content, isEdited: true },
      include: {
        sender: { select: { id: true, name: true, avatarUrl: true } },
        replyTo: { select: { id: true, type: true, content: true, mediaUrl: true, senderId: true } },
      },
    });
    
    // io.to(`conversation:${message.conversationId}`).emit('message:updated', updated);
    
    res.json({ message: updated });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Edit message error:', error);
    res.status(500).json({ error: 'Failed to edit message' });
  }
});

// Delete message (for everyone or just me)
router.delete('/:messageId', async (req, res) => {
  try {
    const { forEveryone } = z.object({ forEveryone: z.boolean().default(false) }).parse(req.query);
    
    const message = await prisma.message.findUnique({
      where: { id: req.params.messageId },
    });
    
    if (!message) {
      return res.status(404).json({ error: 'Message not found' });
    }
    
    const participant = await prisma.conversationParticipant.findUnique({
      where: { conversationId_userId: { conversationId: message.conversationId, userId: req.user.id } },
    });
    
    if (!participant) {
      return res.status(403).json({ error: 'Not a participant' });
    }
    
    if (forEveryone) {
      // Only sender can delete for everyone, within 1 hour
      if (message.senderId !== req.user.id) {
        return res.status(403).json({ error: 'Only sender can delete for everyone' });
      }
      if (Date.now() - message.createdAt.getTime() > 60 * 60 * 1000) {
        return res.status(400).json({ error: 'Delete for everyone time expired' });
      }
      
      await prisma.message.update({
        where: { id: message.id },
        data: { isDeleted: true, content: 'This message was deleted' },
      });
      
      // io.to(`conversation:${message.conversationId}`).emit('message:deleted', { messageId: message.id, forEveryone: true });
    } else {
      // Delete for me only - mark as deleted for this user
      // Could implement a MessageUserDelete table, for now just mark as deleted
      await prisma.message.update({
        where: { id: message.id },
        data: { isDeleted: true },
      });
    }
    
    res.json({ success: true });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Delete message error:', error);
    res.status(500).json({ error: 'Failed to delete message' });
  }
});

// Mark messages as read
router.post('/:conversationId/read', async (req, res) => {
  try {
    const { messageIds } = z.object({ messageIds: z.array(z.string().uuid()).min(1) }).parse(req.body);
    
    await prisma.messageStatus.updateMany({
      where: { messageId: { in: messageIds }, userId: req.user.id },
      data: { status: 'READ' },
    });
    
    await prisma.conversationParticipant.update({
      where: { conversationId_userId: { conversationId: req.params.conversationId, userId: req.user.id } },
      data: { lastReadAt: new Date() },
    });
    
    // io.to(`conversation:${req.params.conversationId}`).emit('messages:read', { userId: req.user.id, messageIds });
    
    res.json({ success: true });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Mark read error:', error);
    res.status(500).json({ error: 'Failed to mark as read' });
  }
});

// Forward message
router.post('/:messageId/forward', async (req, res) => {
  try {
    const { conversationIds } = z.object({ conversationIds: z.array(z.string().uuid()).min(1).max(10) }).parse(req.body);
    
    const message = await prisma.message.findUnique({
      where: { id: req.params.messageId },
      include: { sender: { select: { id: true, name: true } } },
    });
    
    if (!message) {
      return res.status(404).json({ error: 'Message not found' });
    }
    
    const results = [];
    
    for (const convId of conversationIds) {
      const participant = await prisma.conversationParticipant.findUnique({
        where: { conversationId_userId: { conversationId: convId, userId: req.user.id } },
      });
      
      if (!participant || participant.leftAt) continue;
      
      const forwarded = await prisma.message.create({
        data: {
          conversationId: convId,
          senderId: req.user.id,
          type: message.type,
          content: message.content,
          mediaUrl: message.mediaUrl,
          mediaType: message.mediaType,
          mediaSize: message.mediaSize,
          duration: message.duration,
        },
      });
      
      results.push(forwarded);
    }
    
    res.json({ messages: results });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Forward message error:', error);
    res.status(500).json({ error: 'Failed to forward message' });
  }
});

export default router;
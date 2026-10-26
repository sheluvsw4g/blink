// Message Handler Service - Real-time message handling via Socket.io
import { prisma } from '../index.js';

export const setupMessageHandling = (io, socket) => {
  const userId = socket.user.id;
  
  // Send message (real-time)
  socket.on('message:send', async (data) => {
    try {
      const { conversationId, type, content, mediaUrl, mediaType, mediaSize, duration, replyToId, tempId } = data;
      
      // Verify access
      const participant = await prisma.conversationParticipant.findUnique({
        where: { conversationId_userId: { conversationId, userId } },
      });
      
      if (!participant || participant.leftAt) {
        socket.emit('message:error', { tempId, error: 'Not a participant' });
        return;
      }
      
      // Validate replyTo
      if (replyToId) {
        const replyTo = await prisma.message.findFirst({
          where: { id: replyToId, conversationId },
        });
        if (!replyTo) {
          socket.emit('message:error', { tempId, error: 'Reply message not found' });
          return;
        }
      }
      
      // Create message in database
      const message = await prisma.message.create({
        data: {
          conversationId,
          senderId: userId,
          type: type || 'TEXT',
          content,
          mediaUrl,
          mediaType,
          mediaSize,
          duration,
          replyToId,
        },
        include: {
          sender: { select: { id: true, name: true, avatarUrl: true } },
          replyTo: {
            select: { id: true, type: true, content: true, mediaUrl: true, senderId: true },
          },
        },
      });
      
      // Create statuses
      const otherParticipants = await prisma.conversationParticipant.findMany({
        where: { conversationId, userId: { not: userId }, leftAt: null },
        select: { userId: true },
      });
      
      await prisma.messageStatus.createMany({
        data: [
          { messageId: message.id, userId, status: 'SENT' },
          ...otherParticipants.map(p => ({ messageId: message.id, userId: p.userId, status: 'SENT' })),
        ],
        skipDuplicates: true,
      });
      
      // Update conversation timestamp
      await prisma.conversation.update({
        where: { id: conversationId },
        data: { updatedAt: new Date() },
      });
      
      // Send confirmation to sender
      socket.emit('message:sent', { tempId, message });
      
      // Broadcast to conversation (including sender for sync)
      io.to(`conversation:${conversationId}`).emit('message:new', message);
      
      // Send push notifications to offline users
      for (const p of otherParticipants) {
        const targetUser = await prisma.user.findUnique({
          where: { id: p.userId },
          select: { isOnline: true, devices: { select: { token: true, platform: true } } },
        });
        
        if (targetUser && !targetUser.isOnline && targetUser.devices.length > 0) {
          // TODO: Send push notification via APNs/FCM
          // await sendPushNotification(targetUser.devices, message);
        }
      }
      
    } catch (error) {
      console.error('Send message error:', error);
      socket.emit('message:error', { tempId: data.tempId, error: 'Failed to send message' });
    }
  });
  
  // Mark messages as read
  export const markAsRead = async (userId, conversationId, messageIds) => {
    await prisma.messageStatus.updateMany({
      where: { messageId: { in: messageIds }, userId },
      data: { status: 'READ' },
    });
    
    await prisma.conversationParticipant.update({
      where: { conversationId_userId: { conversationId, userId } },
      data: { lastReadAt: new Date() },
    });
  };
  
  // Typing indicators
  socket.on('typing:start', (conversationId) => {
    socket.to(`conversation:${conversationId}`).emit('user:typing', {
      userId,
      conversationId,
      userName: socket.user.name,
    });
  });
  
  socket.on('typing:stop', (conversationId) => {
    socket.to(`conversation:${conversationId}`).emit('user:stopped_typing', {
      userId,
      conversationId,
    });
  });
  
  // Message reactions (optional feature)
  socket.on('message:react', async (data) => {
    try {
      const { messageId, emoji } = data;
      
      // In a full implementation, you'd store reactions in DB
      // For now, just broadcast
      const message = await prisma.message.findUnique({ where: { id: messageId } });
      if (message) {
        io.to(`conversation:${message.conversationId}`).emit('message:reaction', {
          messageId,
          userId,
          emoji,
          userName: socket.user.name,
        });
      }
    } catch (error) {
      console.error('Message reaction error:', error);
    }
  });
  
  // Delete message
  socket.on('message:delete', async (data) => {
    try {
      const { messageId, forEveryone } = data;
      
      const message = await prisma.message.findUnique({ where: { id: messageId } });
      if (!message) return;
      
      if (forEveryone) {
        if (message.senderId !== userId) return;
        if (Date.now() - message.createdAt.getTime() > 60 * 60 * 1000) return;
        
        await prisma.message.update({
          where: { id: messageId },
          data: { isDeleted: true, content: 'This message was deleted' },
        });
        
        io.to(`conversation:${message.conversationId}`).emit('message:deleted', {
          messageId,
          forEveryone: true,
        });
      }
    } catch (error) {
      console.error('Delete message error:', error);
    }
  });
  
  // Edit message
  socket.on('message:edit', async (data) => {
    try {
      const { messageId, content } = data;
      
      const message = await prisma.message.findUnique({ where: { id: messageId } });
      if (!message || message.senderId !== userId) return;
      if (Date.now() - message.createdAt.getTime() > 15 * 60 * 1000) return;
      
      const updated = await prisma.message.update({
        where: { id: messageId },
        data: { content, isEdited: true },
        include: {
          sender: { select: { id: true, name: true, avatarUrl: true } },
          replyTo: { select: { id: true, type: true, content: true, mediaUrl: true, senderId: true } },
        },
      });
      
      io.to(`conversation:${message.conversationId}`).emit('message:updated', updated);
    } catch (error) {
      console.error('Edit message error:', error);
    }
  });
};
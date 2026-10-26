// Call Signaling Service - WebRTC Signaling via Socket.io
import { prisma } from '../index.js';

const pendingCalls = new Map(); // callId -> { offer, candidates, timeout }

export const setupCallSignaling = (io, socket) => {
  const userId = socket.user.id;
  
  // Initiate call - send offer to receiver
  socket.on('call:initiate', async (data) => {
    try {
      const { callId, offer, conversationId, receiverId, type } = data;
      
      // Verify call exists and user is initiator
      const call = await prisma.call.findUnique({
        where: { id: callId },
        include: { conversation: true },
      });
      
      if (!call || call.initiatorId !== userId) {
        socket.emit('call:error', { callId, error: 'Call not found or not authorized' });
        return;
      }
      
      // Update call status to RINGING
      await prisma.call.update({
        where: { id: callId },
        data: { status: 'RINGING' },
      });
      
      // Store offer for when receiver answers
      pendingCalls.set(callId, { offer, candidates: [], initiatorId: userId });
      
      // Send to receiver
      io.to(`user:${receiverId}`).emit('call:incoming', {
        callId,
        conversationId,
        callerId: userId,
        callerName: socket.user.name,
        callerAvatar: socket.user.avatarUrl,
        type,
        offer,
      });
      
      // Set timeout for call (30 seconds)
      setTimeout(async () => {
        const pending = pendingCalls.get(callId);
        if (pending) {
          pendingCalls.delete(callId);
          await prisma.call.update({
            where: { id: callId },
            data: { status: 'MISSED', endedAt: new Date() },
          });
          io.to(`user:${userId}`).emit('call:timeout', { callId });
          io.to(`user:${receiverId}`).emit('call:cancelled', { callId });
        }
      }, 30000);
      
    } catch (error) {
      console.error('Call initiate error:', error);
      socket.emit('call:error', { error: 'Failed to initiate call' });
    }
  });
  
  // Answer call
  socket.on('call:answer', async (data) => {
    try {
      const { callId, answer } = data;
      
      const call = await prisma.call.findUnique({ where: { id: callId } });
      if (!call || call.receiverId !== userId) {
        socket.emit('call:error', { callId, error: 'Call not found or not authorized' });
        return;
      }
      
      if (call.status !== 'RINGING') {
        socket.emit('call:error', { callId, error: 'Call is not ringing' });
        return;
      }
      
      // Update call status
      await prisma.call.update({
        where: { id: callId },
        data: { status: 'ANSWERED', answeredAt: new Date(), startedAt: new Date() },
      });
      
      // Get stored offer
      const pending = pendingCalls.get(callId);
      if (!pending) {
        socket.emit('call:error', { callId, error: 'Call offer expired' });
        return;
      }
      
      // Send answer to initiator
      io.to(`user:${call.initiatorId}`).emit('call:answered', {
        callId,
        answer,
        receiverId: userId,
      });
      
      // Send any queued ICE candidates to both parties
      for (const candidate of pending.candidates) {
        io.to(`user:${call.initiatorId}`).emit('call:ice-candidate', { callId, candidate });
        io.to(`user:${userId}`).emit('call:ice-candidate', { callId, candidate });
      }
      
      // Update pending call with answer
      pending.answer = answer;
      pending.receiverId = userId;
      
    } catch (error) {
      console.error('Call answer error:', error);
      socket.emit('call:error', { error: 'Failed to answer call' });
    }
  });
  
  // Reject call
  socket.on('call:reject', async (data) => {
    try {
      const { callId } = data;
      
      const call = await prisma.call.findUnique({ where: { id: callId } });
      if (!call || (call.initiatorId !== userId && call.receiverId !== userId)) {
        return;
      }
      
      await prisma.call.update({
        where: { id: callId },
        data: { status: 'REJECTED', endedAt: new Date() },
      });
      
      const otherId = call.initiatorId === userId ? call.receiverId : call.initiatorId;
      io.to(`user:${otherId}`).emit('call:rejected', { callId, rejectedBy: userId });
      
      pendingCalls.delete(callId);
      
    } catch (error) {
      console.error('Call reject error:', error);
    }
  });
  
  // End call
  socket.on('call:end', async (data) => {
    try {
      const { callId } = data;
      
      const call = await prisma.call.findUnique({ where: { id: callId } });
      if (!call || (call.initiatorId !== userId && call.receiverId !== userId)) {
        return;
      }
      
      const now = new Date();
      const duration = call.startedAt ? Math.floor((now - call.startedAt) / 1000) : 0;
      
      await prisma.call.update({
        where: { id: callId },
        data: { status: 'ENDED', endedAt: now, duration },
      });
      
      const otherId = call.initiatorId === userId ? call.receiverId : call.initiatorId;
      io.to(`user:${otherId}`).emit('call:ended', { callId, endedBy: userId, duration });
      
      pendingCalls.delete(callId);
      
    } catch (error) {
      console.error('Call end error:', error);
    }
  });
  
  // ICE Candidate exchange
  socket.on('call:ice-candidate', (data) => {
    const { callId, candidate, targetId } = data;
    
    const pending = pendingCalls.get(callId);
    if (pending) {
      pending.candidates.push(candidate);
    }
    
    // Forward to target user
    if (targetId) {
      io.to(`user:${targetId}`).emit('call:ice-candidate', { callId, candidate, from: userId });
    }
  });
  
  // Renegotiation (e.g., switch camera, mute/unmute)
  socket.on('call:renegotiate', (data) => {
    const { callId, offer, targetId } = data;
    
    if (targetId) {
      io.to(`user:${targetId}`).emit('call:renegotiate', { callId, offer, from: userId });
    }
  });
  
  // Call quality feedback
  socket.on('call:quality', (data) => {
    const { callId, stats } = data;
    // Log or forward to other participant
    // io.to(`conversation:${data.conversationId}`).emit('call:quality', { callId, stats, from: userId });
  });
  
  // Cleanup on disconnect
  socket.on('disconnect', () => {
    // Handle any pending calls where this user was involved
    for (const [callId, pending] of pendingCalls.entries()) {
      if (pending.initiatorId === userId || pending.receiverId === userId) {
        const otherId = pending.initiatorId === userId ? pending.receiverId : pending.initiatorId;
        if (otherId) {
          io.to(`user:${otherId}`).emit('call:peer-disconnected', { callId });
        }
        // Don't delete immediately - give time for reconnection
        setTimeout(() => {
          if (pendingCalls.has(callId)) {
            pendingCalls.delete(callId);
          }
        }, 10000);
      }
    }
  });
};
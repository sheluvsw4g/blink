// User Routes
import express from 'express';
import { z } from 'zod';
import { prisma } from '../index.js';
import { authenticate } from '../middleware/auth.js';

const router = express.Router();

// All routes require authentication
router.use(authenticate);

// Search users by phone number or name
router.get('/search', async (req, res) => {
  try {
    const { q, limit = '20', offset = '0' } = req.query;
    
    if (!q || q.length < 2) {
      return res.json({ users: [] });
    }
    
    const users = await prisma.user.findMany({
      where: {
        AND: [
          { id: { not: req.user.id } },
          {
            OR: [
              { phoneNumber: { contains: q } },
              { name: { contains: q, mode: 'insensitive' } },
            ],
          },
        ],
      },
      take: parseInt(limit),
      skip: parseInt(offset),
      select: {
        id: true,
        phoneNumber: true,
        name: true,
        avatarUrl: true,
        isOnline: true,
        lastSeen: true,
      },
    });
    
    res.json({ users });
  } catch (error) {
    console.error('Search users error:', error);
    res.status(500).json({ error: 'Search failed' });
  }
});

// Get user by ID
router.get('/:userId', async (req, res) => {
  try {
    const user = await prisma.user.findUnique({
      where: { id: req.params.userId },
      select: {
        id: true,
        phoneNumber: true,
        name: true,
        avatarUrl: true,
        bio: true,
        isOnline: true,
        lastSeen: true,
        createdAt: true,
      },
    });
    
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }
    
    // Check if blocked
    const blocked = await prisma.blockedUser.findFirst({
      where: {
        OR: [
          { blockerId: req.user.id, blockedId: user.id },
          { blockerId: user.id, blockedId: req.user.id },
        ],
      },
    });
    
    if (blocked) {
      return res.status(404).json({ error: 'User not found' });
    }
    
    res.json({ user });
  } catch (error) {
    console.error('Get user error:', error);
    res.status(500).json({ error: 'Failed to get user' });
  }
});

// Get user's contacts
router.get('/contacts/list', async (req, res) => {
  try {
    const contacts = await prisma.contact.findMany({
      where: { ownerId: req.user.id },
      include: {
        contact: {
          select: {
            id: true,
            phoneNumber: true,
            name: true,
            avatarUrl: true,
            isOnline: true,
            lastSeen: true,
          },
        },
      },
      orderBy: { contact: { name: 'asc' } },
    });
    
    res.json({ contacts });
  } catch (error) {
    console.error('Get contacts error:', error);
    res.status(500).json({ error: 'Failed to get contacts' });
  }
});

// Add contact
router.post('/contacts', async (req, res) => {
  try {
    const { contactId, name } = z.object({
      contactId: z.string().uuid(),
      name: z.string().max(50).optional(),
    }).parse(req.body);
    
    if (contactId === req.user.id) {
      return res.status(400).json({ error: 'Cannot add yourself' });
    }
    
    const contact = await prisma.user.findUnique({ where: { id: contactId } });
    if (!contact) {
      return res.status(404).json({ error: 'User not found' });
    }
    
    const newContact = await prisma.contact.create({
      data: {
        ownerId: req.user.id,
        contactId,
        name: name || contact.name,
      },
      include: {
        contact: {
          select: { id: true, phoneNumber: true, name: true, avatarUrl: true },
        },
      },
    });
    
    res.status(201).json({ contact: newContact });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    if (error.code === 'P2002') {
      return res.status(400).json({ error: 'Contact already exists' });
    }
    console.error('Add contact error:', error);
    res.status(500).json({ error: 'Failed to add contact' });
  }
});

// Update contact name
router.patch('/contacts/:contactId', async (req, res) => {
  try {
    const { name } = z.object({ name: z.string().max(50) }).parse(req.body);
    
    const contact = await prisma.contact.update({
      where: {
        ownerId_contactId: {
          ownerId: req.user.id,
          contactId: req.params.contactId,
        },
      },
      data: { name },
      include: {
        contact: { select: { id: true, phoneNumber: true, name: true, avatarUrl: true } },
      },
    });
    
    res.json({ contact });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return res.status(400).json({ error: error.errors[0].message });
    }
    console.error('Update contact error:', error);
    res.status(500).json({ error: 'Failed to update contact' });
  }
});

// Delete contact
router.delete('/contacts/:contactId', async (req, res) => {
  try {
    await prisma.contact.delete({
      where: {
        ownerId_contactId: {
          ownerId: req.user.id,
          contactId: req.params.contactId,
        },
      },
    });
    
    res.json({ success: true });
  } catch (error) {
    console.error('Delete contact error:', error);
    res.status(500).json({ error: 'Failed to delete contact' });
  }
});

// Block user
router.post('/block/:userId', async (req, res) => {
  try {
    const targetId = req.params.userId;
    
    if (targetId === req.user.id) {
      return res.status(400).json({ error: 'Cannot block yourself' });
    }
    
    await prisma.blockedUser.create({
      data: { blockerId: req.user.id, blockedId: targetId },
    });
    
    // Remove from contacts if exists
    await prisma.contact.deleteMany({
      where: {
        OR: [
          { ownerId: req.user.id, contactId: targetId },
          { ownerId: targetId, contactId: req.user.id },
        ],
      },
    });
    
    res.json({ success: true });
  } catch (error) {
    if (error.code === 'P2002') {
      return res.status(400).json({ error: 'Already blocked' });
    }
    console.error('Block user error:', error);
    res.status(500).json({ error: 'Failed to block user' });
  }
});

// Unblock user
router.delete('/block/:userId', async (req, res) => {
  try {
    await prisma.blockedUser.delete({
      where: {
        blockerId_blockedId: {
          blockerId: req.user.id,
          blockedId: req.params.userId,
        },
      },
    });
    
    res.json({ success: true });
  } catch (error) {
    console.error('Unblock user error:', error);
    res.status(500).json({ error: 'Failed to unblock user' });
  }
});

// Get blocked users
router.get('/blocked/list', async (req, res) => {
  try {
    const blocked = await prisma.blockedUser.findMany({
      where: { blockerId: req.user.id },
      include: {
        blocked: {
          select: { id: true, phoneNumber: true, name: true, avatarUrl: true },
        },
      },
    });
    
    res.json({ blocked });
  } catch (error) {
    console.error('Get blocked error:', error);
    res.status(500).json({ error: 'Failed to get blocked users' });
  }
});

export default router;
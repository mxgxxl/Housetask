import { Router } from 'express';
import * as householdController from '../controllers/household.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { requireMembership } from '../middleware/membership.middleware';
import { asyncHandler } from '../utils/asyncHandler';

const router = Router();

// All household routes require authentication.
router.use(authMiddleware);

// Not household-scoped: creating and joining happen before membership exists.
router.post('/', asyncHandler(householdController.create));
router.post('/join', asyncHandler(householdController.join));

// Household-scoped: requireMembership is the single membership checkpoint.
router.get('/:householdId', requireMembership, asyncHandler(householdController.getById));
router.get(
  '/:householdId/members',
  requireMembership,
  asyncHandler(householdController.listMembers)
);
router.delete(
  '/:householdId/members/:userId',
  requireMembership,
  asyncHandler(householdController.removeMember)
);

export default router;

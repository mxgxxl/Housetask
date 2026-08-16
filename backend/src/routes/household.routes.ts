import { Router } from 'express';
import * as householdController from '../controllers/household.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { requireMembership } from '../middleware/membership.middleware';
import { idempotency } from '../middleware/idempotency.middleware';
import { validate } from '../middleware/validate';
import { createHouseholdSchema, joinHouseholdSchema } from '../schemas/household.schema';
import { asyncHandler } from '../utils/asyncHandler';

const router = Router();

// All household routes require authentication.
router.use(authMiddleware);

// Not household-scoped: creating and joining happen before membership exists.
// validate() before idempotency: a malformed body fails fast without ever
// claiming/burning the client's Idempotency-Key (TD-028).
router.post(
  '/',
  validate(createHouseholdSchema),
  idempotency,
  asyncHandler(householdController.create),
);
router.post(
  '/join',
  validate(joinHouseholdSchema),
  idempotency,
  asyncHandler(householdController.join),
);

// Household-scoped: requireMembership is the single membership checkpoint.
router.get('/:householdId', requireMembership, asyncHandler(householdController.getById));
router.get(
  '/:householdId/members',
  requireMembership,
  asyncHandler(householdController.listMembers),
);
router.get('/:householdId/stats', requireMembership, asyncHandler(householdController.getStats));
router.delete(
  '/:householdId/members/:userId',
  requireMembership,
  asyncHandler(householdController.removeMember),
);

export default router;

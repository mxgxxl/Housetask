import { Router } from 'express';
import * as householdController from '../controllers/household.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { requireMembership } from '../middleware/membership.middleware';
import { idempotency } from '../middleware/idempotency.middleware';
import { validate } from '../middleware/validate';
import {
  createHouseholdSchema,
  joinHouseholdSchema,
  transferOwnershipSchema,
} from '../schemas/household.schema';
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

// Governance (TD-067, PDR-022). requireMembership answers 401/403/404 for a
// caller outside the household; being the CREATOR is checked in the service,
// inside the same transaction that writes, because `createdBy` is a live
// permission that a concurrent transfer can move (Hard Rule 3).
//
// PATCH, not POST: promote/demote set a member's role to a known value, so a
// replay lands on the same state rather than creating anything. That is also
// why they carry no `Idempotency-Key` — Hard Rule 13 governs POSTs that create
// a resource, and these create nothing. `leave` and `transfer-ownership` are
// POST because they are commands rather than field edits, and are likewise
// idempotent by construction: the second call finds the caller already gone,
// or already not the owner, and answers 403.
router.patch(
  '/:householdId/members/:userId/promote',
  requireMembership,
  asyncHandler(householdController.promoteMember),
);
router.patch(
  '/:householdId/members/:userId/demote',
  requireMembership,
  asyncHandler(householdController.demoteMember),
);
router.post(
  '/:householdId/transfer-ownership',
  requireMembership,
  validate(transferOwnershipSchema),
  asyncHandler(householdController.transferOwnership),
);
router.post(
  '/:householdId/leave',
  requireMembership,
  asyncHandler(householdController.leave),
);

// Destruction with a grace period (PDR-022 D4). Creator-only, checked in the
// service; `requireMembership` still runs first so a non-member never learns
// whether the household exists.
//
// Only `schedule` carries `idempotency`: it is the one that CREATES a resource
// (the HouseholdDestruction row), which is what Hard Rule 13 is about. Cancel
// and confirm act on a row that must already exist, and the unique index makes
// a duplicate schedule impossible anyway — the middleware is the retry-safety
// net, not the uniqueness guarantee.
router.post(
  '/:householdId/schedule-destruction',
  requireMembership,
  idempotency,
  asyncHandler(householdController.scheduleDestruction),
);
router.post(
  '/:householdId/cancel-destruction',
  requireMembership,
  asyncHandler(householdController.cancelDestruction),
);
router.post(
  '/:householdId/confirm-destruction',
  requireMembership,
  asyncHandler(householdController.confirmDestruction),
);
router.get(
  '/:householdId/destruction-status',
  requireMembership,
  asyncHandler(householdController.getDestructionStatus),
);

export default router;

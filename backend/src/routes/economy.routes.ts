import { Router } from 'express';
import * as economyController from '../controllers/economy.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { requireMembership } from '../middleware/membership.middleware';
import { validate, validateQuery } from '../middleware/validate';
import { idempotency } from '../middleware/idempotency.middleware';
import {
  buyIceSchema,
  personalEconomyQuerySchema,
  updateBudgetSchema,
} from '../schemas/economy-p1.schema';
import { asyncHandler } from '../utils/asyncHandler';

// mergeParams lets us read :householdId from the parent mount path.
const router = Router({ mergeParams: true });

router.use(authMiddleware);
// Every route below is household-scoped; membership is verified once, here.
router.use(requireMembership);

router.get('/', asyncHandler(economyController.get));

// TD-066 B6. Mounted under /p1 so the Fase A endpoint above keeps its exact
// path and shape for the whole migration (design §6.5) — the two economies
// coexist rather than one shadowing the other.
router.get(
  '/p1/me',
  validateQuery(personalEconomyQuerySchema),
  asyncHandler(economyController.getPersonalP1),
);
router.get('/p1/household', asyncHandler(economyController.getHouseholdP1));

// TD-066 B8. validate() before the handler, same order as every other write
// route: a malformed plan must fail before it can touch a stored budget.
router.patch(
  '/p1/budget',
  validate(updateBudgetSchema),
  asyncHandler(economyController.updateBudgetP1),
);

// B9: buying an ice creates a ledger entry, so it is a POST and carries
// Idempotency-Key protection (Hard Rule 13).
router.post(
  '/p1/ice',
  validate(buyIceSchema),
  idempotency,
  asyncHandler(economyController.buyIceP1),
);

export default router;

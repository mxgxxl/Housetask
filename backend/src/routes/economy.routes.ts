import { Router } from 'express';
import * as economyController from '../controllers/economy.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { requireMembership } from '../middleware/membership.middleware';
import { validateQuery } from '../middleware/validate';
import { personalEconomyQuerySchema } from '../schemas/economy-p1.schema';
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

export default router;

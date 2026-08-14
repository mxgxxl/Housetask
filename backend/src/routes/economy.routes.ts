import { Router } from 'express';
import * as economyController from '../controllers/economy.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { requireMembership } from '../middleware/membership.middleware';
import { asyncHandler } from '../utils/asyncHandler';

// mergeParams lets us read :householdId from the parent mount path.
const router = Router({ mergeParams: true });

router.use(authMiddleware);
// Every route below is household-scoped; membership is verified once, here.
router.use(requireMembership);

router.get('/', asyncHandler(economyController.get));

export default router;

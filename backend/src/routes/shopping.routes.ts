import { Router } from 'express';
import * as shoppingController from '../controllers/shopping.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { requireMembership } from '../middleware/membership.middleware';
import { idempotency } from '../middleware/idempotency.middleware';
import { asyncHandler } from '../utils/asyncHandler';

// mergeParams lets us read :householdId from the parent mount path.
const router = Router({ mergeParams: true });

router.use(authMiddleware);
// Every route below is household-scoped; membership is verified once, here.
router.use(requireMembership);

router.get('/', asyncHandler(shoppingController.list));
router.post('/', idempotency, asyncHandler(shoppingController.create));
router.patch('/:itemId', asyncHandler(shoppingController.update));
router.patch('/:itemId/purchase', asyncHandler(shoppingController.purchase));
router.delete('/:itemId', asyncHandler(shoppingController.remove));

export default router;

import { Router } from 'express';
import * as taskController from '../controllers/task.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { requireMembership } from '../middleware/membership.middleware';
import { asyncHandler } from '../utils/asyncHandler';

// mergeParams lets us read :householdId from the parent mount path.
const router = Router({ mergeParams: true });

router.use(authMiddleware);
// Every route below is household-scoped; membership is verified once, here.
router.use(requireMembership);

router.get('/', asyncHandler(taskController.list));
router.post('/', asyncHandler(taskController.create));
// Static path must precede the ':taskId' routes so it is not treated as an id.
router.post('/generate-instances', asyncHandler(taskController.generateRecurringInstances));
router.patch('/:taskId', asyncHandler(taskController.update));
router.patch('/:taskId/complete', asyncHandler(taskController.complete));
router.delete('/:taskId', asyncHandler(taskController.remove));

export default router;

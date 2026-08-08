import { Router } from 'express';
import * as taskController from '../controllers/task.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { asyncHandler } from '../utils/asyncHandler';

// mergeParams lets us read :householdId from the parent mount path.
const router = Router({ mergeParams: true });

router.use(authMiddleware);

router.get('/', asyncHandler(taskController.list));
router.post('/', asyncHandler(taskController.create));
router.patch('/:taskId', asyncHandler(taskController.update));
router.patch('/:taskId/complete', asyncHandler(taskController.complete));
router.delete('/:taskId', asyncHandler(taskController.remove));

export default router;

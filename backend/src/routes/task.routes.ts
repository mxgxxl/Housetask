import { Router } from 'express';
import * as taskController from '../controllers/task.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { requireMembership } from '../middleware/membership.middleware';
import { idempotency } from '../middleware/idempotency.middleware';
import { validate } from '../middleware/validate';
import { createTaskSchema, updateTaskSchema } from '../schemas/task.schema';
import { asyncHandler } from '../utils/asyncHandler';

// mergeParams lets us read :householdId from the parent mount path.
const router = Router({ mergeParams: true });

router.use(authMiddleware);
// Every route below is household-scoped; membership is verified once, here.
router.use(requireMembership);

router.get('/', asyncHandler(taskController.list));
// validate() before idempotency: a malformed body fails fast without ever
// claiming/burning the client's Idempotency-Key (TD-028).
router.post('/', validate(createTaskSchema), idempotency, asyncHandler(taskController.create));
// Static path must precede the ':taskId' routes so it is not treated as an id.
router.post('/generate-instances', asyncHandler(taskController.generateRecurringInstances));
router.patch('/:taskId', validate(updateTaskSchema), asyncHandler(taskController.update));
router.patch('/:taskId/complete', asyncHandler(taskController.complete));
router.delete('/:taskId', asyncHandler(taskController.remove));

export default router;

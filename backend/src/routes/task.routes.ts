import { Router } from 'express';
import * as taskController from '../controllers/task.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { requireMembership } from '../middleware/membership.middleware';
import { idempotency } from '../middleware/idempotency.middleware';
import { validate } from '../middleware/validate';
import { createTaskSchema, updateTaskSchema } from '../schemas/task.schema';
import { completeTaskP1Schema } from '../schemas/economy-p1.schema';
import { asyncHandler } from '../utils/asyncHandler';

// mergeParams lets us read :householdId from the parent mount path.
const router = Router({ mergeParams: true });

router.use(authMiddleware);
// Every route below is household-scoped; membership is verified once, here.
router.use(requireMembership);

router.get('/', asyncHandler(taskController.list));

// TD-064: the timeline reads. Registered before any `/:taskId` route so a
// literal segment can never be captured as an id — there is no GET `/:taskId`
// today, but adding one later must not silently swallow these.
router.get('/timeline', asyncHandler(taskController.timeline));
router.get('/undated', asyncHandler(taskController.undated));
// validate() before idempotency: a malformed body fails fast without ever
// claiming/burning the client's Idempotency-Key (TD-028).
router.post('/', validate(createTaskSchema), idempotency, asyncHandler(taskController.create));
// Static paths must precede the ':taskId' routes so they are not treated as an id.
router.post('/generate-instances', asyncHandler(taskController.generateRecurringInstances));
router.post('/purge', asyncHandler(taskController.purge));
router.patch('/:taskId', validate(updateTaskSchema), asyncHandler(taskController.update));
// TD-066 B4: the header is OPTIONAL (idempotency.middleware passes straight
// through without it), so mounting it here changes nothing for the published
// client, which never sends it on a PATCH. What it adds is a safe retry for
// the caller that DOES send one — which matters now that this path can fail
// where it used to half-succeed: with P1 on, a reward failure rolls back the
// completion instead of leaving it completed-but-unpaid.
router.patch('/:taskId/complete', idempotency, asyncHandler(taskController.complete));
// TD-066 B3: the P1 completion command. Same validate()-before-idempotency
// order as POST '/' — a malformed body must not burn the client's key.
router.post(
  '/:taskId/completions',
  validate(completeTaskP1Schema),
  idempotency,
  asyncHandler(taskController.completions),
);
router.delete('/:taskId', asyncHandler(taskController.remove));
router.post('/:taskId/restore', asyncHandler(taskController.restore));

export default router;

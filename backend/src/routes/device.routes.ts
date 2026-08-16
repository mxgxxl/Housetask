import { Router } from 'express';
import * as deviceController from '../controllers/device.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { idempotency } from '../middleware/idempotency.middleware';
import { validate } from '../middleware/validate';
import { registerDeviceSchema } from '../schemas/device.schema';
import { asyncHandler } from '../utils/asyncHandler';

const router = Router();

router.use(authMiddleware);

// validate() before idempotency: a malformed body fails fast without ever
// claiming/burning the client's Idempotency-Key (TD-028), same ordering as
// every other resource-creating POST (Hard Rule 13).
router.post(
  '/register',
  validate(registerDeviceSchema),
  idempotency,
  asyncHandler(deviceController.register),
);
router.delete('/:token', asyncHandler(deviceController.remove));

export default router;

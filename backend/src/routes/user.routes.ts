import { Router } from 'express';
import * as userController from '../controllers/user.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { asyncHandler } from '../utils/asyncHandler';

const router = Router();

router.use(authMiddleware);

router.get('/me', asyncHandler(userController.getProfile));
router.patch('/me', asyncHandler(userController.updateProfile));

export default router;

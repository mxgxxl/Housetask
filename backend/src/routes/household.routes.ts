import { Router } from 'express';
import * as householdController from '../controllers/household.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { asyncHandler } from '../utils/asyncHandler';

const router = Router();

// All household routes require authentication.
router.use(authMiddleware);

router.post('/', asyncHandler(householdController.create));
router.post('/join', asyncHandler(householdController.join));
router.get('/:id', asyncHandler(householdController.getById));
router.get('/:id/members', asyncHandler(householdController.listMembers));
router.delete('/:id/members/:userId', asyncHandler(householdController.removeMember));

export default router;

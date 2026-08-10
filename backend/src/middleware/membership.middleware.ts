import { Response, NextFunction } from 'express';
import { HouseholdModel } from '../models/Household';
import { AppError } from './error.middleware';
import { asyncHandler } from '../utils/asyncHandler';
import { AuthenticatedRequest } from '../types';

/**
 * Household membership guard for every household-scoped HTTP route.
 *
 * This is the single membership checkpoint for the HTTP surface (Hard Rule 8):
 * services no longer re-verify, so a new endpoint mounted on a nested router
 * is protected by construction instead of by remembering to call a helper.
 * It is also the designated place to plug the Redis membership cache and its
 * destructive-operation bypass in Phase 2 (see Performance Patterns).
 *
 * Runs after `authMiddleware`, reads `:householdId` from the route, and
 * attaches the caller's membership to `req.member` — role, joinedAt and the
 * household's full member id list — so controllers can make role-based and
 * reference-validation decisions without a second query.
 *
 * Responds 404 when the household does not exist and 403 when the caller is
 * not one of its members.
 */
export const requireMembership = asyncHandler(
  async (req: AuthenticatedRequest, _res: Response, next: NextFunction): Promise<void> => {
    const householdId = req.params.householdId;
    const userId = req.user?.userId;

    if (!userId) {
      // authMiddleware must always run first; reaching here is a wiring bug.
      throw new AppError('Authentication required', 401);
    }

    const household = await HouseholdModel.findById(householdId).select('members').lean();
    if (!household) {
      throw new AppError('Household not found', 404);
    }

    const member = household.members.find((m) => m.user.toString() === userId);
    if (!member) {
      throw new AppError('You are not a member of this household', 403);
    }

    req.member = {
      role: member.role,
      joinedAt: member.joinedAt,
      // Free: the household document is already in hand.
      memberIds: household.members.map((m) => m.user.toString()),
    };
    next();
  }
);

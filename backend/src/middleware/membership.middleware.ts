import { Response, NextFunction } from 'express';
import { HouseholdModel } from '../models/Household';
import { HouseholdMemberModel } from '../models/HouseholdMember';
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
 *
 * TD-001 phase 3 (cutover): membership is now read from the HouseholdMember
 * collection, which is the authority. The embedded `Household.members` array
 * is no longer read here — it is still written, as the rollback net, until
 * phase 4. The dual-read verification that measured the two against each
 * other through the observation window is gone with it: there is no longer a
 * second opinion to compare against.
 */
export const requireMembership = asyncHandler(
  async (req: AuthenticatedRequest, _res: Response, next: NextFunction): Promise<void> => {
    const householdId = req.params.householdId;
    const userId = req.user?.userId;

    if (!userId) {
      // authMiddleware must always run first; reaching here is a wiring bug.
      throw new AppError('Authentication required', 401);
    }

    // One indexed query on `{householdId: 1, userId: 1}` answers both questions
    // this middleware exists to answer: is the caller a member, and who else
    // is. Before the cutover this cost two round trips (the household document
    // plus the verification read); the hot path is now a single one.
    const memberships = await HouseholdMemberModel.find({ householdId })
      .select('userId role joinedAt')
      .lean();

    const member = memberships.find((m) => m.userId.toString() === userId);

    if (!member) {
      // Only the failure path pays for telling 404 from 403. An empty result
      // is ambiguous on its own — a household that does not exist and one the
      // caller does not belong to both produce it — and answering 403 for a
      // missing household would leak nothing but would break the contract
      // households.test.ts pins. Members, the overwhelming majority, never
      // reach this branch.
      const exists = await HouseholdModel.exists({ _id: householdId });
      if (!exists) {
        throw new AppError('Household not found', 404);
      }
      throw new AppError('You are not a member of this household', 403);
    }

    req.member = {
      role: member.role,
      joinedAt: member.joinedAt,
      // Free: the whole membership list is already in hand.
      memberIds: memberships.map((m) => m.userId.toString()),
    };

    next();
  },
);

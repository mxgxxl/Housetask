import { Response, NextFunction } from 'express';
import { HouseholdModel } from '../models/Household';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { AppError } from './error.middleware';
import { asyncHandler } from '../utils/asyncHandler';
import { AuthenticatedRequest, RequesterMembership } from '../types';
import { captureSecurityWarning } from '../utils/sentry';
import { logger } from '../utils/logger';

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
/**
 * Compare the HouseholdMember collection against the embedded array that just
 * answered this request (TD-001, phase 2).
 *
 * This is the measurement that decides when the cutover is safe: the criterion
 * agreed for advancing is a number — zero divergences under real traffic — not
 * a date. Every mismatch is reported with the `td001_dual_read` category so a
 * Sentry search on that tag gives the count directly, and mirrored to the log
 * so it is also visible in Railway without opening Sentry.
 *
 * Never throws and never changes the outcome: a fault in the verification path
 * must not turn a working request into a 500. Nothing here is the authority
 * yet.
 */
async function verifyMembershipMirror(
  householdId: string,
  userId: string,
  fromEmbedded: RequesterMembership,
): Promise<void> {
  try {
    const rows = await HouseholdMemberModel.find({ householdId })
      .select('userId role')
      .lean();

    const mirrored = rows.find((r) => r.userId.toString() === userId);
    const differences: string[] = [];

    if (!mirrored) {
      differences.push('caller missing from collection');
    } else if (mirrored.role !== fromEmbedded.role) {
      differences.push(`role embedded=${fromEmbedded.role} collection=${mirrored.role}`);
    }

    const embeddedIds = [...fromEmbedded.memberIds].sort();
    const collectionIds = rows.map((r) => r.userId.toString()).sort();
    if (embeddedIds.join(',') !== collectionIds.join(',')) {
      differences.push(
        `member set embedded=[${embeddedIds.join('|')}] collection=[${collectionIds.join('|')}]`,
      );
    }

    if (differences.length === 0) return;

    const message = `TD-001 dual-read divergence: ${differences.join('; ')}`;
    logger.warn(message, { householdId, userId });
    captureSecurityWarning(message, {
      category: 'td001_dual_read',
      householdId,
      userId,
      differences,
    });
  } catch (err) {
    // A broken verification is a lost sample, not a broken request.
    logger.error('TD-001 dual-read verification failed', (err as Error).message);
  }
}

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

    // TD-001 phase 2: verify the new collection agrees, WITHOUT letting it
    // affect the answer. Deliberately awaited rather than fired and forgotten,
    // so a divergence is reported before the request completes and the sample
    // is not lost when the process recycles — this middleware sees every
    // household-scoped request, which is exactly why it is the measurement
    // point. Remove this call at the cutover, when the collection becomes the
    // authority and there is nothing left to compare against.
    await verifyMembershipMirror(householdId, userId, req.member);

    next();
  },
);

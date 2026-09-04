import { Response } from 'express';
import * as householdService from '../services/household.service';
import * as householdStatsService from '../services/household-stats.service';
import { StatsPeriod } from '../services/household-stats.service';
import { AppError } from '../middleware/error.middleware';
import { sendSuccess } from '../utils/response';
import { AuthenticatedRequest } from '../types';

const VALID_PERIODS: StatsPeriod[] = ['last30days', 'allTime'];

/** Parse the `period` query param; absent defaults to last30days, invalid is a 400. */
function parsePeriod(raw: unknown): StatsPeriod {
  if (raw === undefined) return 'last30days';
  if (typeof raw !== 'string' || !VALID_PERIODS.includes(raw as StatsPeriod)) {
    throw new AppError('period must be one of: last30days, allTime', 400);
  }
  return raw as StatsPeriod;
}

/**
 * POST /api/households
 * Body: { name } — shape validated by createHouseholdSchema (TD-028).
 * Creates a household with the caller as its first admin.
 */
export async function create(req: AuthenticatedRequest, res: Response): Promise<void> {
  const { name } = req.body;
  const household = await householdService.createHousehold(req.user!.userId, name);
  sendSuccess(res, await householdService.serializeHousehold(household), 201);
}

/**
 * GET /api/households/:householdId
 * Returns the household with members populated (members only).
 */
export async function getById(req: AuthenticatedRequest, res: Response): Promise<void> {
  const household = await householdService.getHousehold(req.params.householdId);
  sendSuccess(res, await householdService.serializeHousehold(household));
}

/**
 * POST /api/households/join
 * Body: { inviteCode } — shape validated by joinHouseholdSchema (TD-028).
 * Adds the caller to a household as a member.
 */
export async function join(req: AuthenticatedRequest, res: Response): Promise<void> {
  const { inviteCode } = req.body;
  const household = await householdService.joinHousehold(req.user!.userId, inviteCode);
  sendSuccess(res, await householdService.serializeHousehold(household));
}

/**
 * GET /api/households/:householdId/members
 * Lists the household's members (members only).
 */
export async function listMembers(req: AuthenticatedRequest, res: Response): Promise<void> {
  const household = await householdService.getHousehold(req.params.householdId);
  sendSuccess(res, (await householdService.serializeHousehold(household)).members);
}

/**
 * DELETE /api/households/:householdId/members/:userId
 * Removes a member (admin only; cannot remove the last admin).
 */
export async function removeMember(req: AuthenticatedRequest, res: Response): Promise<void> {
  const household = await householdService.removeMember(
    req.params.householdId,
    req.member!,
    req.params.userId,
  );
  sendSuccess(res, await householdService.serializeHousehold(household));
}

/**
 * GET /api/households/:householdId/stats?period=last30days|allTime
 * Load/completion stats (PDR-007). Any member may read; requireMembership
 * has already verified membership before this handler runs.
 */
export async function getStats(req: AuthenticatedRequest, res: Response): Promise<void> {
  const period = parsePeriod(req.query.period);
  const stats = await householdStatsService.getHouseholdStats(req.params.householdId, period);
  sendSuccess(res, stats);
}

/**
 * PATCH /api/households/:householdId/members/:userId/promote
 * Makes a member an admin. Creator only (PDR-022 D1).
 */
export async function promoteMember(req: AuthenticatedRequest, res: Response): Promise<void> {
  const household = await householdService.changeMemberRole(
    req.params.householdId,
    req.user!.userId,
    req.params.userId,
    'admin',
  );
  sendSuccess(res, await householdService.serializeHousehold(household));
}

/**
 * PATCH /api/households/:householdId/members/:userId/demote
 * Makes an admin a plain member. Creator only, and never the creator
 * themselves (PDR-022 D1).
 */
export async function demoteMember(req: AuthenticatedRequest, res: Response): Promise<void> {
  const household = await householdService.changeMemberRole(
    req.params.householdId,
    req.user!.userId,
    req.params.userId,
    'member',
  );
  sendSuccess(res, await householdService.serializeHousehold(household));
}

/**
 * POST /api/households/:householdId/transfer-ownership
 * Body: { userId } — shape validated by transferOwnershipSchema.
 * Hands `createdBy` to another admin; the outgoing creator stays an admin
 * and stays in the household (PDR-022 D2).
 */
export async function transferOwnership(req: AuthenticatedRequest, res: Response): Promise<void> {
  const household = await householdService.transferOwnership(
    req.params.householdId,
    req.user!.userId,
    req.body.userId,
  );
  sendSuccess(res, await householdService.serializeHousehold(household));
}

/**
 * POST /api/households/:householdId/leave
 * The caller leaves the household (PDR-022 D3).
 *
 * Returns the succession rather than the household: the caller is no longer a
 * member, so serializing the household back to them would hand a former member
 * its current roster and invite code. The two optional ids are what the client
 * needs to explain what happened ("Ana is now the admin"), and both name
 * people the caller was a housemate of a moment ago.
 */
export async function leave(req: AuthenticatedRequest, res: Response): Promise<void> {
  const outcome = await householdService.leaveHousehold(
    req.params.householdId,
    req.user!.userId,
  );
  sendSuccess(res, {
    left: true,
    promotedUserId: outcome.promoteUserId ?? null,
    newOwnerId: outcome.newOwnerId ?? null,
  });
}

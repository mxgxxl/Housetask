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
  sendSuccess(res, householdService.serializeHousehold(household), 201);
}

/**
 * GET /api/households/:householdId
 * Returns the household with members populated (members only).
 */
export async function getById(req: AuthenticatedRequest, res: Response): Promise<void> {
  const household = await householdService.getHousehold(req.params.householdId);
  sendSuccess(res, householdService.serializeHousehold(household));
}

/**
 * POST /api/households/join
 * Body: { inviteCode } — shape validated by joinHouseholdSchema (TD-028).
 * Adds the caller to a household as a member.
 */
export async function join(req: AuthenticatedRequest, res: Response): Promise<void> {
  const { inviteCode } = req.body;
  const household = await householdService.joinHousehold(req.user!.userId, inviteCode);
  sendSuccess(res, householdService.serializeHousehold(household));
}

/**
 * GET /api/households/:householdId/members
 * Lists the household's members (members only).
 */
export async function listMembers(req: AuthenticatedRequest, res: Response): Promise<void> {
  const household = await householdService.getHousehold(req.params.householdId);
  sendSuccess(res, householdService.serializeHousehold(household).members);
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
  sendSuccess(res, householdService.serializeHousehold(household));
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

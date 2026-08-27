import { Response } from 'express';
import * as economyService from '../services/economy.service';
import * as economyP1ReadService from '../services/economy-p1-read.service';
import { sendSuccess } from '../utils/response';
import { PersonalEconomyQuery } from '../schemas/economy-p1.schema';
import { AuthenticatedRequest } from '../types';

/**
 * GET /api/households/:householdId/economy
 * Returns { balance, dailyEarned, recentTransactions } for the household.
 */
export async function get(req: AuthenticatedRequest, res: Response): Promise<void> {
  const householdId = req.params.householdId;

  const [balance, dailyEarned, recentTransactions] = await Promise.all([
    economyService.getBalance(householdId),
    economyService.getDailyEarned(householdId),
    economyService.getRecentTransactions(householdId),
  ]);

  sendSuccess(res, { balance, dailyEarned, recentTransactions });
}

/**
 * GET /api/households/:householdId/economy/p1/me?timeZone=<IANA>
 *
 * The caller's own P1 economy (TD-066 B6): wallet, personal XP, streak and
 * this week's budget. Never anyone else's — `req.user`, not a path param, is
 * what identifies the member, so there is no id to tamper with.
 *
 * While P1 is disabled for the household — every household today — this
 * answers a complete, zeroed structure with `enabled: false` rather than a
 * 404, so a client can ship before its household is migrated.
 */
export async function getPersonalP1(req: AuthenticatedRequest, res: Response): Promise<void> {
  const query = (res.locals.query ?? {}) as PersonalEconomyQuery;

  const view = await economyP1ReadService.getPersonalEconomy(
    req.params.householdId,
    req.user!.userId,
    { timeZone: query.timeZone },
  );

  sendSuccess(res, view);
}

/**
 * GET /api/households/:householdId/economy/p1/household
 *
 * What the household as a whole may see: shared XP, the active savings goal
 * with its per-member breakdown, and each member's personal level. Carries no
 * member's wallet, budget or streak — see the read service for where that
 * line falls and why.
 */
export async function getHouseholdP1(req: AuthenticatedRequest, res: Response): Promise<void> {
  const view = await economyP1ReadService.getHouseholdEconomy(req.params.householdId);
  sendSuccess(res, view);
}

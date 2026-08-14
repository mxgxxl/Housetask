import { Response } from 'express';
import * as economyService from '../services/economy.service';
import { sendSuccess } from '../utils/response';
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

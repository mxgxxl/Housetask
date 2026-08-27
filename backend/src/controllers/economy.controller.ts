import { Response } from 'express';
import * as economyService from '../services/economy.service';
import * as economyP1ReadService from '../services/economy-p1-read.service';
import mongoose, { Types } from 'mongoose';
import * as economyP1BudgetService from '../services/economy-p1-budget.service';
import * as economyP1StreakService from '../services/economy-p1-streak.service';
import { IDEMPOTENCY_HEADER } from '../middleware/idempotency.middleware';
import { emitToUser } from '../config/socket';
import { isP1Enabled } from '../services/feature-flag.service';
import { AppError } from '../middleware/error.middleware';
import { resolveTimeZone, weekKey as currentWeekKey } from '../utils/economy-period';
import { sendSuccess } from '../utils/response';
import * as economyP1SavingsService from '../services/economy-p1-savings.service';
import { emitToHousehold } from '../config/socket';
import {
  ContributeBody,
  CreateSavingsGoalBody,
  PersonalEconomyQuery,
  UpdateBudgetBody,
} from '../schemas/economy-p1.schema';
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

/**
 * PATCH /api/households/:householdId/economy/p1/budget
 *
 * Rewrites the CALLER's plan for one week (TD-066 B8, PDR-011). `mode:
 * 'automatic'` is the "volver a automático" button: it drops every manual
 * override and recomputes the deterministic split. `mode: 'manual'` applies
 * `coinAmount` overrides on top of that same recomputation.
 *
 * Only ever the caller's own plan — the member comes from the access token,
 * so there is no id to point at somebody else's budget.
 */
export async function updateBudgetP1(req: AuthenticatedRequest, res: Response): Promise<void> {
  const householdId = req.params.householdId;
  const userId = req.user!.userId;
  const body = req.body as UpdateBudgetBody;

  // Refused rather than silently stored: writing a plan a disabled economy
  // will never read would let a client believe it had configured something.
  // The GETs answer a zeroed shape instead, because a read has something
  // coherent to say when the economy is off and a write does not.
  await assertP1Enabled(householdId);

  const timeZone = resolveTimeZone(body.timeZone);
  const weekKey = body.weekKey ?? currentWeekKey(new Date(), timeZone);

  const budget = await economyP1BudgetService.updateWeeklyBudget({
    householdId,
    userId,
    weekKey,
    periodTimeZone: timeZone,
    mode: body.mode,
    allocations: body.allocations,
  });

  sendSuccess(res, { weeklyBudget: budget });
}

/**
 * POST /api/households/:householdId/economy/p1/ice
 *
 * Buy one streak ice from the caller's personal wallet (B9, PDR-019).
 *
 * Transactional: the balance check, the wallet debit and the reserve
 * increment are one unit, so a failure can never leave a member paying for an
 * ice they did not receive. `Idempotency-Key` doubles as the operation id, so
 * a retried tap after a timeout hits the ledger's unique index rather than
 * buying a second one.
 */
export async function buyIceP1(req: AuthenticatedRequest, res: Response): Promise<void> {
  const householdId = req.params.householdId;
  const userId = req.user!.userId;

  await assertP1Enabled(householdId);

  const operationId = req.get(IDEMPOTENCY_HEADER) ?? new Types.ObjectId().toString();

  const session = await mongoose.startSession();
  let result: economyP1StreakService.BuyIceResult | null = null;
  try {
    await session.withTransaction(async () => {
      result = await economyP1StreakService.buyIce(userId, householdId, operationId, session);
    });
  } finally {
    await session.endSession();
  }

  if (!result) {
    throw new AppError('Could not complete the ice purchase', 500);
  }
  const purchase = result as economyP1StreakService.BuyIceResult;

  // After the commit: a socket event cannot be un-emitted.
  emitToUser(userId, 'economy:ice_purchased', {
    iceReserve: purchase.iceReserve,
    spent: purchase.spent,
    balance: purchase.balance,
  });

  sendSuccess(res, purchase);
}


/**
 * POST /api/households/:householdId/economy/p1/savings-goals
 *
 * Open the household's one active joint savings goal (B10, PDR-018). The
 * price comes from the server-side catalog, never from the request.
 */
export async function createSavingsGoalP1(
  req: AuthenticatedRequest,
  res: Response,
): Promise<void> {
  const householdId = req.params.householdId;
  await assertP1Enabled(householdId);

  const body = req.body as CreateSavingsGoalBody;
  const goal = await economyP1SavingsService.createGoal(
    householdId,
    req.user!.userId,
    body.itemType,
    body.itemId,
  );

  // A goal is the household's, not one member's: everyone can contribute to
  // it and everyone sees it on the home card (UX-P1-SPEC §4).
  emitToHousehold(householdId, 'household:savings_goal_created', goal.toJSON());

  sendSuccess(res, { goal }, 201);
}

/**
 * POST /api/households/:householdId/economy/p1/savings-goals/:goalId/contributions
 *
 * Move coins from the caller's personal wallet into the goal (B10).
 */
export async function contributeToSavingsGoalP1(
  req: AuthenticatedRequest,
  res: Response,
): Promise<void> {
  const householdId = req.params.householdId;
  await assertP1Enabled(householdId);

  const body = req.body as ContributeBody;
  const operationId = req.get(IDEMPOTENCY_HEADER) ?? new Types.ObjectId().toString();

  const result = await economyP1SavingsService.contribute(
    householdId,
    req.user!.userId,
    req.params.goalId,
    body.amount,
    operationId,
  );

  // Both events are household-wide: the per-member breakdown is explicitly
  // public (UX-P1-SPEC §6 renders "Tú: 40 · Ana: 28"), unlike a wallet.
  emitToHousehold(householdId, 'household:savings_contribution', {
    goalId: result.goal._id.toString(),
    userId: req.user!.userId,
    amount: result.contributedAmount,
    contributedCoins: result.goal.contributedCoins,
    targetCoins: result.goal.targetCoins,
  });
  if (result.unlocked) {
    emitToHousehold(householdId, 'household:savings_goal_unlocked', result.goal.toJSON());
  }

  sendSuccess(res, {
    goal: result.goal,
    contribution: { amount: result.contributedAmount },
    wallet: { balance: result.balance },
  });
}

/**
 * POST /api/households/:householdId/economy/p1/savings-goals/:goalId/cancel
 *
 * Cancel the goal and refund every still-active contribution (B10, PDR-018).
 *
 * A POST rather than a DELETE: the row survives as history with
 * `status: 'cancelled'`, and answering a DELETE would tell the client the
 * opposite of what happened.
 */
export async function cancelSavingsGoalP1(
  req: AuthenticatedRequest,
  res: Response,
): Promise<void> {
  const householdId = req.params.householdId;
  await assertP1Enabled(householdId);

  const result = await economyP1SavingsService.cancelGoal(
    householdId,
    req.user!.userId,
    req.params.goalId,
    req.member!.role === 'admin',
  );

  emitToHousehold(householdId, 'household:savings_goal_cancelled', {
    goal: result.goal.toJSON(),
    refunds: result.refunds,
  });
  // The refund lands in a personal wallet, so each contributor is told
  // privately what came back to them.
  for (const refund of result.refunds) {
    emitToUser(refund.userId, 'economy:savings_refunded', {
      goalId: result.goal._id.toString(),
      amount: refund.amount,
    });
  }

  sendSuccess(res, { goal: result.goal, refunds: result.refunds });
}

/** Shared guard: P1 writes are refused outright while the economy is off. */
async function assertP1Enabled(householdId: string): Promise<void> {
  if (!(await isP1Enabled(householdId))) {
    throw new AppError('The P1 economy is not enabled for this household', 409);
  }
}

import mongoose, { ClientSession, Types } from 'mongoose';

import { AppError } from '../middleware/error.middleware';
import { COSMETICS } from '../config/economy';
import { IJointSavingsGoal, JointSavingsGoalModel } from '../models/JointSavingsGoal';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { SavingsContributionModel } from '../models/SavingsContribution';

/**
 * The joint savings goal (TD-066 B10, PDR-018).
 *
 * ── What this is NOT ─────────────────────────────────────────────────────
 * Not a shared wallet. PDR-018 keeps every coin personal precisely so there
 * is no common purse to argue over; a goal is a cooperative mini-mission
 * toward ONE shared item, where each contribution stays attributable to its
 * author and comes back if the goal never completes.
 *
 * ── Why the target is not client-supplied ────────────────────────────────
 * A goal saves toward a catalog item, so its price comes from the catalog.
 * Letting the client name a `targetAmount` would let a household unlock a
 * 40-coin cosmetic by declaring the target to be 1 — the economy's ceiling
 * would be decorative. `itemType`/`itemId` is what a client chooses; the
 * price is looked up here.
 */

/** What kinds of shared item a goal can save toward. */
export type SavingsItemType = 'cosmetic';

/**
 * The price of a shared item, from the server-side catalog.
 *
 * Only cosmetics for now: they are the shared items that actually exist
 * (PDR-015 keeps the pet's art on a separate track, so there is nothing else
 * to save toward yet). An unknown item is a 400 rather than a guessed price.
 */
export function priceOfItem(itemType: string, itemId: string): number {
  if (itemType !== 'cosmetic') {
    throw new AppError(`Unknown item type: ${itemType}`, 400);
  }
  const cosmetic = COSMETICS.find((c) => c.id === itemId);
  if (!cosmetic) {
    throw new AppError(`Unknown cosmetic: ${itemId}`, 400);
  }
  return cosmetic.price;
}

function isDuplicateKeyError(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: number }).code === 11000;
}

/**
 * Open the household's one active goal (PDR-018: "En v1 hay una sola meta
 * activa").
 *
 * The partial unique index is what enforces the "one" — including against two
 * members tapping "create" at the same moment, which is a plausible race in a
 * household of two looking at the same empty state. A duplicate key here is
 * that index working, so it becomes a 409 rather than a 500.
 */
export async function createGoal(
  householdId: string,
  userId: string,
  itemType: string,
  itemId: string,
): Promise<IJointSavingsGoal> {
  const targetCoins = priceOfItem(itemType, itemId);

  try {
    return await JointSavingsGoalModel.create({
      householdId: new Types.ObjectId(householdId),
      status: 'active',
      itemType,
      itemId,
      targetCoins,
      contributedCoins: 0,
      createdBy: new Types.ObjectId(userId),
    });
  } catch (err) {
    if (isDuplicateKeyError(err)) {
      throw new AppError('This household already has an active savings goal', 409);
    }
    throw err;
  }
}

export interface ContributeResult {
  goal: IJointSavingsGoal;
  contributedAmount: number;
  balance: number;
  /** True when this contribution is the one that reached the price. */
  unlocked: boolean;
}

/**
 * Move coins from a member's personal wallet into the goal.
 *
 * One transaction covers the balance check, the contribution row, the wallet
 * debit and the goal's running total — so a wallet can never be debited
 * without a contribution to show for it, and the total can never claim money
 * nobody paid.
 *
 * `operationId` makes it idempotent through `(goalId, operationId)`: a
 * contribution is a real debit, and paying twice for one tap is the failure
 * that matters most here.
 */
export async function contribute(
  householdId: string,
  userId: string,
  goalId: string,
  amount: number,
  operationId: string,
): Promise<ContributeResult> {
  if (!Number.isInteger(amount) || amount < 1) {
    throw new AppError('A contribution must be a whole number of coins, at least 1', 400);
  }

  const session = await mongoose.startSession();
  let result: ContributeResult | null = null;

  try {
    await session.withTransaction(async () => {
      const goal = await JointSavingsGoalModel.findOne({
        _id: goalId,
        householdId: new Types.ObjectId(householdId),
      }).session(session);

      if (!goal) {
        throw new AppError('Savings goal not found', 404);
      }
      if (goal.status !== 'active') {
        throw new AppError(`This goal is ${goal.status} and no longer accepts contributions`, 409);
      }

      const balance = await walletBalance(userId, session);
      if (balance < amount) {
        // 403 rather than 400: the request is well-formed, the member simply
        // is not allowed to spend what they do not have. Nothing is written.
        throw new AppError(`Not enough coins: your balance is ${balance}`, 403);
      }

      const [contribution] = await SavingsContributionModel.create(
        [
          {
            goalId: goal._id,
            householdId: new Types.ObjectId(householdId),
            userId: new Types.ObjectId(userId),
            amount,
            status: 'active' as const,
            operationId,
          },
        ],
        { session },
      );

      await PersonalCoinLedgerModel.create(
        [
          {
            userId: new Types.ObjectId(userId),
            householdId: new Types.ObjectId(householdId),
            amount: -amount,
            reason: 'savings_contribution' as const,
            refType: 'savings_contribution' as const,
            refId: contribution._id.toString(),
            effectiveAt: new Date(),
          },
        ],
        { session },
      );

      goal.contributedCoins += amount;

      const unlocked = goal.contributedCoins >= goal.targetCoins;
      if (unlocked) {
        goal.status = 'unlocked';
        goal.unlockedAt = new Date();
        // Every contribution has now BOUGHT something, so none of them is
        // refundable any more. Marking them `applied` is what keeps the
        // refund paths (cancel, and a member leaving) from ever handing back
        // money for an item the household already owns.
        await SavingsContributionModel.updateMany(
          { goalId: goal._id, status: 'active' },
          { $set: { status: 'applied' } },
          { session },
        );
      }

      await goal.save({ session });

      result = {
        goal,
        contributedAmount: amount,
        balance: balance - amount,
        unlocked,
      };
    });
  } catch (err) {
    if (isDuplicateKeyError(err)) {
      throw new AppError('This contribution has already been recorded', 409);
    }
    throw err;
  } finally {
    await session.endSession();
  }

  if (!result) {
    throw new AppError('Could not record the contribution', 500);
  }
  return result;
}

/** A member's personal balance: the sum of their ledger, never a counter. */
async function walletBalance(userId: string, session: ClientSession): Promise<number> {
  const [row] = await PersonalCoinLedgerModel.aggregate<{ total: number }>([
    { $match: { userId: new Types.ObjectId(userId) } },
    { $group: { _id: null, total: { $sum: '$amount' } } },
  ]).session(session);
  return row?.total ?? 0;
}

export interface RefundLine {
  userId: string;
  amount: number;
}

/**
 * Give every still-active contribution of a goal back to its author.
 *
 * Shared by both refund paths PDR-018 names — cancelling the goal, and a
 * member leaving the household — because they are the same operation on
 * different subsets. Filtering on `status: 'active'` is what makes it safe to
 * repeat: a second pass finds nothing, so a retried transaction cannot pay
 * twice, and an already-unlocked goal (whose contributions are `applied`) is
 * untouched by construction.
 */
export async function refundContributions(
  filter: Record<string, unknown>,
  session: ClientSession,
): Promise<RefundLine[]> {
  const contributions = await SavingsContributionModel.find({
    ...filter,
    status: 'active',
  }).session(session);

  const refunds: RefundLine[] = [];

  for (const contribution of contributions) {
    await PersonalCoinLedgerModel.create(
      [
        {
          userId: contribution.userId,
          householdId: contribution.householdId,
          amount: contribution.amount,
          reason: 'savings_refund' as const,
          refType: 'savings_contribution' as const,
          // Keyed on the contribution, so the ledger's unique index makes a
          // second refund of the same contribution impossible even if some
          // future path forgets the status filter above.
          refId: contribution._id.toString(),
          effectiveAt: new Date(),
        },
      ],
      { session },
    );

    contribution.status = 'refunded';
    contribution.refundedAt = new Date();
    await contribution.save({ session });

    // The goal's running total has to come down with it, or a cancelled or
    // departed member's coins would still count toward the price.
    await JointSavingsGoalModel.updateOne(
      { _id: contribution.goalId },
      { $inc: { contributedCoins: -contribution.amount } },
      { session },
    );

    refunds.push({
      userId: contribution.userId.toString(),
      amount: contribution.amount,
    });
  }

  return refunds;
}

export interface CancelResult {
  goal: IJointSavingsGoal;
  refunds: RefundLine[];
}

/**
 * Cancel the goal and give everyone their coins back (PDR-018).
 *
 * Only the creator or a household admin may cancel: the money belongs to
 * everyone who put it in, so a single contributor should not be able to
 * dissolve a goal the rest of the household is still saving for.
 */
export async function cancelGoal(
  householdId: string,
  userId: string,
  goalId: string,
  isAdmin: boolean,
): Promise<CancelResult> {
  const session = await mongoose.startSession();
  let result: CancelResult | null = null;

  try {
    await session.withTransaction(async () => {
      const goal = await JointSavingsGoalModel.findOne({
        _id: goalId,
        householdId: new Types.ObjectId(householdId),
      }).session(session);

      if (!goal) {
        throw new AppError('Savings goal not found', 404);
      }
      if (goal.status !== 'active') {
        throw new AppError(`This goal is already ${goal.status}`, 409);
      }
      if (!isAdmin && goal.createdBy.toString() !== userId) {
        throw new AppError('Only the goal creator or a household admin can cancel it', 403);
      }

      const refunds = await refundContributions({ goalId: goal._id }, session);

      goal.status = 'cancelled';
      goal.cancelledAt = new Date();
      goal.cancelledBy = new Types.ObjectId(userId);
      await goal.save({ session });

      result = { goal, refunds };
    });
  } finally {
    await session.endSession();
  }

  if (!result) {
    throw new AppError('Could not cancel the savings goal', 500);
  }
  return result;
}

/**
 * Give a departing member their still-active contributions back, inside the
 * caller's transaction (TD-066-DESIGN §4: "La baja de miembro llama al mismo
 * reembolso dentro de la transacción de membresía antes de retirar sus
 * permisos; no toca aportes de otros miembros").
 *
 * Scoped to that member and that household, so nobody else's money moves.
 */
export async function refundDepartingMember(
  householdId: string,
  userId: string,
  session: ClientSession,
): Promise<RefundLine[]> {
  return refundContributions(
    {
      householdId: new Types.ObjectId(householdId),
      userId: new Types.ObjectId(userId),
    },
    session,
  );
}

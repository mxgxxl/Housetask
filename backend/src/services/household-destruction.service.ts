import mongoose, { ClientSession, Types } from 'mongoose';

import { AdoptionRequestModel } from '../models/AdoptionRequest';
import { EconomyLedgerModel } from '../models/EconomyLedger';
import { HouseholdModel, IHousehold } from '../models/Household';
import { HouseholdDestructionModel, IHouseholdDestruction } from '../models/HouseholdDestruction';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { HouseholdProgressModel } from '../models/HouseholdProgress';
import { HouseholdXpLedgerModel } from '../models/HouseholdXpLedger';
import { JointSavingsGoalModel } from '../models/JointSavingsGoal';
import { PetModel } from '../models/Pet';
import { ShoppingItemModel } from '../models/ShoppingItem';
import { TaskModel } from '../models/Task';
import { AppError } from '../middleware/error.middleware';
import { emitToHousehold } from '../config/socket';
import { logger } from '../utils/logger';
import { refundContributionsForHousehold } from './economy-p1-savings.service';

/**
 * Household destruction with a grace period (TD-067, PDR-022 D4).
 *
 * Three commands and a deadline: the creator schedules, which starts a 24-hour
 * clock; they may cancel at any point before it expires; once it has expired
 * the destruction can be confirmed, by the creator or by the scheduled job.
 *
 * ── Why a grace period at all ────────────────────────────────────────────
 * Everything else PDR-022 added is reversible by hand — a demotion can be
 * re-promoted, a transfer transferred back, a departure re-joined with the
 * invite code. Destruction is the one operation with no manual undo, so the
 * undo is built into the flow instead. `docs/TD-067-DESIGN.md` had specified
 * immediate destruction; PDR-022 D4 supersedes that.
 *
 * ── Why a soft delete ────────────────────────────────────────────────────
 * The design doc also specified a clean hard delete. PDR-022 D4 supersedes
 * that too, and the invite code is the concrete reason: `inviteCode` is
 * unique, so removing the document returns an eight-character code to the
 * pool. Someone who still has that code in a chat would eventually paste it
 * and land in a stranger's household. A destroyed household keeps its row and
 * its code, and answers 404 forever.
 *
 * ── What the cascade touches, and what it must not ───────────────────────
 * The line is ownership, not convenience: anything keyed on `householdId`
 * ALONE belongs to the household and goes; anything keyed on a `userId`
 * belongs to a person, travels with them, and is left exactly as it is
 * (PDR-017 — personal XP, level, titles and wallet are portable, and a
 * household ending must not be able to take them). The single exception in
 * both directions is the joint savings goal, which is household-owned but
 * holds personal money: it is refunded first, then cancelled (Hard Rule 16b).
 */

/** How long the creator has to change their mind (PDR-022 D4). */
export const DESTRUCTION_GRACE_PERIOD_MS = 24 * 60 * 60 * 1000;

/**
 * Load a live household, or 404.
 *
 * "Live" is the load-bearing word: once `isDeleted` is set, a household is
 * gone as far as the API is concerned, and every path that could otherwise
 * resurrect or re-destroy it has to agree on that.
 */
async function activeHousehold(householdId: string, session?: ClientSession): Promise<IHousehold> {
  const query = HouseholdModel.findOne({ _id: householdId, isDeleted: { $ne: true } });
  const household = session ? await query.session(session) : await query;
  if (!household) {
    throw new AppError('Household not found', 404);
  }
  return household;
}

/** PDR-022 D4: only the creator may schedule, cancel or confirm. */
function assertCreator(household: IHousehold, userId: string): void {
  if (household.createdBy.toString() !== userId) {
    throw new AppError('Only the household creator can delete this household', 403);
  }
}

/**
 * Start the grace period (PDR-022 D4).
 *
 * Idempotent by way of the unique index rather than a read-then-write: the one
 * person allowed to do this may well tap it on two devices, and the second tap
 * must find the first deadline instead of setting a new one. Returning the
 * existing row — rather than a 409 — is what makes the client's "scheduled for
 * X" screen correct no matter which request it was the answer to.
 */
export async function scheduleDestruction(
  householdId: string,
  userId: string,
): Promise<IHouseholdDestruction> {
  const household = await activeHousehold(householdId);
  assertCreator(household, userId);

  const existing = await HouseholdDestructionModel.findOne({
    householdId: new Types.ObjectId(householdId),
  });
  if (existing) return existing;

  let scheduled: IHouseholdDestruction;
  try {
    scheduled = await HouseholdDestructionModel.create({
      householdId: new Types.ObjectId(householdId),
      scheduledBy: new Types.ObjectId(userId),
      scheduledAt: new Date(Date.now() + DESTRUCTION_GRACE_PERIOD_MS),
    });
  } catch (err) {
    if ((err as { code?: number }).code === 11000) {
      // The concurrent tap won. Its row is the answer.
      const winner = await HouseholdDestructionModel.findOne({
        householdId: new Types.ObjectId(householdId),
      });
      if (winner) return winner;
    }
    throw err;
  }

  logger.warn('Household destruction scheduled', {
    householdId,
    userId,
    scheduledAt: scheduled.scheduledAt.toISOString(),
  });

  emitToHousehold(householdId, 'household:destruction_scheduled', {
    householdId,
    scheduledAt: scheduled.scheduledAt,
    scheduledBy: userId,
  });

  return scheduled;
}

/**
 * Call the whole thing off (PDR-022 D4).
 *
 * Nothing to undo: the grace period exists precisely so that no destructive
 * work happens until it expires. Deleting the row is the entire cancellation.
 */
export async function cancelDestruction(householdId: string, userId: string): Promise<void> {
  const household = await activeHousehold(householdId);
  assertCreator(household, userId);

  const deleted = await HouseholdDestructionModel.deleteOne({
    householdId: new Types.ObjectId(householdId),
  });
  if (deleted.deletedCount === 0) {
    throw new AppError('This household is not scheduled for deletion', 404);
  }

  logger.info('Household destruction cancelled', { householdId, userId });

  emitToHousehold(householdId, 'household:destruction_cancelled', { householdId });
}

/** The pending destruction for a household, or null. Any member may read it. */
export async function destructionStatus(
  householdId: string,
): Promise<IHouseholdDestruction | null> {
  return HouseholdDestructionModel.findOne({ householdId: new Types.ObjectId(householdId) });
}

/**
 * Destroy the household for real, in one transaction.
 *
 * The order matters in exactly one place: the savings refund runs BEFORE the
 * memberships are deleted, for the same reason `removeMemberInTransaction`
 * refunds before it deletes one (Hard Rule 16b). After the memberships are
 * gone, the people whose coins are locked in the goal are no longer members of
 * anything, and a refund that failed then would have nobody to fail loudly to.
 *
 * Everything else is order-independent, because a transaction is what makes it
 * all-or-nothing: either the household and every child are gone together, or
 * nothing moved and the household is still there to try again.
 *
 * Shared by the endpoint and the scheduled job so the two can never drift —
 * the same arrangement `purgeDeletedTasks` has with `scripts/purge-trash.ts`
 * (TD-048).
 */
async function destroyInTransaction(householdId: string, session: ClientSession): Promise<void> {
  const householdObjectId = new Types.ObjectId(householdId);

  // Money first (Hard Rule 16b). Not best-effort: a destruction that cannot
  // return the household's pooled coins must fail as a unit.
  await refundContributionsForHousehold(householdId, session);
  await JointSavingsGoalModel.updateMany(
    { householdId: householdObjectId, status: 'active' },
    { $set: { status: 'cancelled', cancelledAt: new Date() } },
    { session },
  );

  // Tasks are soft-deleted rather than removed, so the household's trash and
  // its history stay internally consistent with PDR-006 and the retention job
  // (TD-048) eventually reclaims them on the same schedule as any other trash.
  await TaskModel.updateMany(
    { householdId: householdObjectId, isDeleted: { $ne: true } },
    { $set: { isDeleted: true, deletedAt: new Date() } },
    { session },
  );

  // Household-owned and not portable: they cannot exist without the household
  // and nobody carries them anywhere (PDR-017).
  await ShoppingItemModel.deleteMany({ householdId: householdObjectId }, { session });
  await PetModel.deleteMany({ householdId: householdObjectId }, { session });
  await AdoptionRequestModel.deleteMany({ householdId: householdObjectId }, { session });
  await EconomyLedgerModel.deleteMany({ householdId: householdObjectId }, { session });
  await HouseholdXpLedgerModel.deleteMany({ householdId: householdObjectId }, { session });
  await HouseholdProgressModel.deleteMany({ householdId: householdObjectId }, { session });

  // Deleting the memberships is what actually cuts access — `requireMembership`
  // answers on their absence — so it happens after the refund and before the
  // household is marked gone.
  await HouseholdMemberModel.deleteMany({ householdId: householdObjectId }, { session });

  await HouseholdModel.updateOne(
    { _id: householdObjectId },
    { $set: { isDeleted: true, deletedAt: new Date() } },
    { session },
  );

  await HouseholdDestructionModel.deleteOne({ householdId: householdObjectId }, { session });
}

/**
 * Who was in the household, captured BEFORE the memberships are deleted.
 *
 * `household:destroyed` has to reach people who, by the time it is emitted,
 * are no longer members of anything — so the recipients cannot be recomputed
 * after the commit. Hard Rule 8 is still satisfied: the list comes from a
 * membership check, just one taken a moment earlier.
 */
async function captureMembers(householdId: string): Promise<string[]> {
  const rows = await HouseholdMemberModel.find({
    householdId: new Types.ObjectId(householdId),
  }).select('userId');
  return rows.map((r) => r.userId.toString());
}

/**
 * Confirm a scheduled destruction whose grace period has expired.
 *
 * `force` skips only the deadline, never the authorization — it exists for the
 * scheduled job, which has already selected on `scheduledAt <= now` and has no
 * user to be the creator.
 */
export async function confirmDestruction(
  householdId: string,
  userId: string | null,
): Promise<void> {
  const household = await activeHousehold(householdId);
  if (userId !== null) {
    assertCreator(household, userId);
  }

  const scheduled = await HouseholdDestructionModel.findOne({
    householdId: new Types.ObjectId(householdId),
  });
  if (!scheduled) {
    // Destroying without scheduling would be exactly the un-undoable action the
    // grace period exists to prevent, so this is a 400 and not a shortcut.
    throw new AppError('This household is not scheduled for deletion', 400);
  }
  if (scheduled.scheduledAt.getTime() > Date.now()) {
    throw new AppError(
      'The grace period has not expired yet. Cancel the deletion or wait until it does.',
      400,
    );
  }

  const memberIds = await captureMembers(householdId);

  const session = await mongoose.startSession();
  try {
    await session.withTransaction(async () => {
      // Re-read inside the transaction: between the checks above and here, a
      // cancel could have landed. Everything this callback does must be safe
      // to repeat, and it is — each pass re-derives from current state.
      const still = await HouseholdDestructionModel.findOne({
        householdId: new Types.ObjectId(householdId),
      }).session(session);
      if (!still) {
        throw new AppError('This household is not scheduled for deletion', 400);
      }
      await destroyInTransaction(householdId, session);
    });
  } finally {
    await session.endSession();
  }

  logger.warn('Household destroyed', { householdId, confirmedBy: userId ?? 'scheduled-job' });

  // After the commit, never inside it, and to the room captured before the
  // memberships were deleted.
  emitToHousehold(householdId, 'household:destroyed', {
    householdId,
    destroyedAt: new Date(),
    memberIds,
  });
}

/**
 * Destroy every household whose grace period has expired (PDR-022 D4).
 *
 * The counterpart to the manual confirm, sharing `destroyInTransaction` so the
 * two can never cascade differently — `purgeDeletedTasks` has the same
 * relationship with its endpoint and its script (TD-048).
 *
 * One household failing does not stop the rest: each has its own transaction,
 * so a single bad row cannot hold the whole batch hostage. Failures are logged
 * and the row stays, which means the next run retries it.
 */
export async function destroyExpiredHouseholds(now: Date = new Date()): Promise<number> {
  const due = await HouseholdDestructionModel.find({ scheduledAt: { $lte: now } });

  let destroyed = 0;
  for (const row of due) {
    try {
      await confirmDestruction(row.householdId.toString(), null);
      destroyed += 1;
    } catch (err) {
      logger.error('Scheduled household destruction failed', {
        householdId: row.householdId.toString(),
        error: (err as Error).message,
      });
    }
  }
  return destroyed;
}

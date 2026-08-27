import mongoose, { ClientSession, Types } from 'mongoose';

import { AppError } from '../middleware/error.middleware';
import { HouseholdProgressModel } from '../models/HouseholdProgress';
import { HouseholdXpLedgerModel } from '../models/HouseholdXpLedger';
import { IRewardGrant, RewardGrantModel } from '../models/RewardGrant';
import { ITask, TaskModel } from '../models/Task';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { PersonalXpLedgerModel } from '../models/PersonalXpLedger';
import { UserProgressModel } from '../models/UserProgress';
import { IBudgetAllocation, WeeklyPersonalBudgetModel } from '../models/WeeklyPersonalBudget';
import {
  DEFAULT_TASK_COINS,
  HOUSEHOLD_LEVEL_CURVE_FACTOR,
  HOUSEHOLD_LEVEL_UNLOCKS,
  HOUSEHOLD_TASK_MILESTONES,
  PERSONAL_LEVEL_CURVE_FACTOR,
  PERSONAL_LEVEL_UNLOCKS,
  PERSONAL_TASK_MILESTONES,
  TASK_HOUSEHOLD_XP,
  TASK_PERSONAL_XP,
  WEEKLY_CAP_COINS,
  levelForXp,
  milestoneCrossed,
  unlocksForLevel,
} from '../config/economy-p1';
import { TASK_COINS } from '../config/economy';
import {
  availableCoins,
  dayIndexIn,
  effectiveDayKey,
  releasedOnDay,
  releasedThroughDay,
  resolveTimeZone,
  validateOccurredAt,
  weekKey,
} from '../utils/economy-period';
import { emitToHousehold, emitToUser } from '../config/socket';
import { buildAutomaticPlan, resolveAllocationForTask } from './economy-p1-budget.service';
import { ActivityResult, recordUsefulActivity } from './economy-p1-streak.service';
import { grantCoins } from './economy.service';
import { isP1Enabled } from './feature-flag.service';
import { logger } from '../utils/logger';
import * as taskService from './task.service';

/** What one completion paid out. Zero coins is a real outcome, not "nothing". */
export interface RewardSummary {
  coins: number;
  personalXp: number;
  householdXp: number;
}

export interface CompleteTaskP1Result {
  task: ITask;
  /**
   * `null` when no reward was produced BY THIS REQUEST: P1 is off for the
   * household, or the task's reward already belongs to a different member or
   * a different client operation. A genuine retry of the same operation gets
   * its original amounts back instead.
   */
  reward: RewardSummary | null;
  /** The receipt this completion is recorded under, when there is one. */
  receiptId: string | null;
}

export interface CompleteTaskP1Input {
  householdId: string;
  userId: string;
  taskId: string;
  /**
   * Client-claimed completion instant. Optional: the legacy PATCH paths have
   * no trustworthy offline timestamp to offer (owner decision P7), so they
   * pass nothing and the server uses its own clock.
   */
  occurredAt?: Date;
  /**
   * IANA zone the member's day and week boundaries are computed in.
   *
   * Comes from the request today because NOTHING PERSISTS IT YET: neither
   * `User` nor `HouseholdMember` has a timezone field, and inventing one is a
   * schema decision beyond this stop. Once a week's budget exists, ITS
   * snapshotted `periodTimeZone` wins over whatever the request claims — that
   * is what the snapshot is for (TD-066-DESIGN §3).
   */
  timeZone?: string;
  /**
   * The client's stable id for this logical completion, surviving retries.
   *
   * Sourced from the `Idempotency-Key` header, which is exactly that by Hard
   * Rule 13. Deliberately not a second body field saying the same thing.
   */
  operationId: string;
}

function isDuplicateKeyError(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: number }).code === 11000;
}

/**
 * Complete a task and pay for it, server-authoritative (TD-066-DESIGN §4).
 *
 * ── The claim is the design ──────────────────────────────────────────────
 * The transaction opens by INSERTING a `RewardGrant`. Its unique index
 * `{householdId, taskId, kind}` is what makes the completion exclusive: a
 * retry, a replayed offline operation, or two devices racing all collide on
 * it instead of paying twice. Everything after the claim is written knowing
 * it is already the only writer for this task.
 *
 * That ordering matters. Checking "is it already completed?" and then writing
 * would be a read-then-write race that a transaction alone does not close,
 * because the two requests touch different documents and Mongo has nothing to
 * serialize them on. The unique index is the serialization point.
 *
 * ── What is NOT best-effort here ─────────────────────────────────────────
 * Fase A's `grantCoins` swallows every failure so a coin problem can never
 * break a completion. P1 inverts that for its own writes (§4): a task must
 * not be declared complete without leaving its economic receipt, so a
 * transient failure rolls the whole thing back and the `Idempotency-Key`
 * makes the retry safe. The user-visible consequence — a completion can now
 * fail where it used to half-succeed — is the intended trade.
 */
export async function completeTaskWithReward(
  input: CompleteTaskP1Input,
): Promise<CompleteTaskP1Result> {
  const { householdId, userId, taskId } = input;

  // Flag OFF is the shipped state of every household until B11 activates it,
  // so this is the hot path today. It delegates to the untouched Fase A
  // service: same writes, same events, same response, no P1 document created.
  if (!(await isP1Enabled(householdId))) {
    const task = await taskService.completeTask(householdId, userId, taskId);
    return { task, reward: null, receiptId: null };
  }

  const now = new Date();
  const occurredAt = input.occurredAt ?? now;

  // The server decides the week and the day; the client only proposes when it
  // happened, and only within a bounded window (§9: a manipulated or ancient
  // offline timestamp must be refused outright, not quietly honoured).
  const rejection = validateOccurredAt(occurredAt, now);
  if (rejection) {
    throw new AppError(
      rejection === 'too_old'
        ? 'occurredAt is outside the accepted window'
        : rejection === 'too_far_future'
          ? 'occurredAt is in the future'
          : 'occurredAt is not a valid date',
      400,
    );
  }

  const session = await mongoose.startSession();
  let outcome: TransactionOutcome | null = null;

  try {
    await session.withTransaction(async () => {
      // withTransaction may re-run this callback on a transient error, so it
      // re-reads and recomputes everything on each attempt rather than
      // closing over a previous attempt's state.
      outcome = await runRewardTransaction(input, occurredAt, session);
    });
  } catch (err) {
    if (isDuplicateKeyError(err)) {
      // The claim was already taken. Not an error: it is the idempotency
      // guarantee doing its job, so answer from the existing receipt.
      return replayExistingGrant(input);
    }
    throw err;
  } finally {
    await session.endSession();
  }

  if (!outcome) {
    // withTransaction resolved without running the callback to completion,
    // which should be impossible. Failing loudly beats returning a task the
    // caller would read as "completed and paid".
    throw new AppError('Completion transaction produced no result', 500);
  }

  return afterCommit(input, outcome);
}

/** Weekly-budget snapshot as it stands right after a grant (B5 payload). */
export interface BudgetSummary {
  weekKey: string;
  /** Coins still claimable this week after this grant. */
  remaining: number;
  /** Coins today's allocation released on its own — 0 on Sunday (PDR-013). */
  dailyReleased: number;
}

/** Household XP as it stands right after a grant (B5 payload). */
export interface HouseholdProgressSummary {
  householdXp: number;
  level: number;
}

interface TransactionOutcome {
  task: ITask;
  reward: RewardSummary;
  receiptId: string;
  /**
   * Carried out of the transaction rather than re-read after it: these are
   * the values that were actually committed, and re-reading could pick up a
   * concurrent completion's numbers instead — which would make the socket
   * payload disagree with the receipt the same request just returned.
   */
  budget: BudgetSummary;
  householdProgress: HouseholdProgressSummary;
  /** Before/after figures for both tracks, so B7 can spot what was crossed. */
  personalDelta: ProgressDelta;
  householdDelta: ProgressDelta;
  /** What the completion did to the member's streak and ice reserve (B9). */
  streak: ActivityResult;
}

async function runRewardTransaction(
  input: CompleteTaskP1Input,
  occurredAt: Date,
  session: ClientSession,
): Promise<TransactionOutcome> {
  const { householdId, userId, taskId, operationId } = input;

  const task = await TaskModel.findOne({
    _id: taskId,
    householdId,
    isDeleted: { $ne: true },
  }).session(session);

  if (!task) {
    throw new AppError('Task not found', 404);
  }

  // ── 1. Claim the completion. Everything else depends on winning this. ──
  const requestedZone = resolveTimeZone(input.timeZone);
  const provisionalWeekKey = weekKey(occurredAt, requestedZone);

  const budget = await resolveWeeklyBudget(
    userId,
    householdId,
    provisionalWeekKey,
    requestedZone,
    session,
  );

  // The budget's stored zone wins: it was snapshotted when the week opened,
  // and a device that changed zone mid-week must not re-slice a week that is
  // already being settled under another one.
  const effectiveZone = budget.periodTimeZone;
  const dayIndex = dayIndexIn(occurredAt, effectiveZone);
  const dayKey = effectiveDayKey(occurredAt, effectiveZone);

  const released = releasedThroughDay(budget.weeklyCap, dayIndex);
  const available = availableCoins(budget.weeklyCap, dayIndex, budget.grantedCoins);

  // TD-066 B8: what the task is worth comes from the member's weekly plan.
  // `null` means no plan covers it — a member's very first completion, before
  // any plan has been built — and falls back to the flat default rather than
  // paying nothing, because "we have not planned yet" must not read as "this
  // was worthless".
  const allocation = resolveAllocationForTask(budget.allocations ?? [], task, userId);
  const planned = allocation?.coinAmount ?? DEFAULT_TASK_COINS;

  // Never pay more than the day has released. XP is untouched by this: PDR-013
  // makes Sunday and an exhausted budget stop the coins, not the progress.
  const coinAward = Math.min(planned, available);

  const [grant] = await RewardGrantModel.create(
    [
      {
        householdId: new Types.ObjectId(householdId),
        userId: new Types.ObjectId(userId),
        taskId: new Types.ObjectId(taskId),
        kind: 'task_first_completion' as const,
        completionOperationId: operationId,
        effectiveAt: occurredAt,
        effectiveDayKey: dayKey,
        coinAwarded: coinAward,
        personalXpAwarded: TASK_PERSONAL_XP,
        householdXpAwarded: TASK_HOUSEHOLD_XP,
        weeklyBudgetId: budget._id,
        status: 'granted' as const,
      },
    ],
    { session },
  );

  // ── 2. Money and progress, all inside the same transaction. ──
  if (coinAward > 0) {
    // A zero-coin completion writes no entry at all: an amount-zero row would
    // be noise in a wallet history that people read. The receipt above still
    // records that the payout was zero, so the two are distinguishable.
    await PersonalCoinLedgerModel.create(
      [
        {
          userId: new Types.ObjectId(userId),
          householdId: new Types.ObjectId(householdId),
          amount: coinAward,
          reason: 'task_first_completion' as const,
          refType: 'task' as const,
          refId: taskId,
          weekKey: budget.weekKey,
          effectiveAt: occurredAt,
        },
      ],
      { session },
    );
  }

  await PersonalXpLedgerModel.create(
    [
      {
        userId: new Types.ObjectId(userId),
        amount: TASK_PERSONAL_XP,
        reason: 'task_first_completion' as const,
        refType: 'task' as const,
        refId: taskId,
      },
    ],
    { session },
  );

  await HouseholdXpLedgerModel.create(
    [
      {
        householdId: new Types.ObjectId(householdId),
        amount: TASK_HOUSEHOLD_XP,
        reason: 'task_first_completion' as const,
        refType: 'task' as const,
        refId: taskId,
      },
    ],
    { session },
  );

  await WeeklyPersonalBudgetModel.updateOne(
    { _id: budget._id },
    { $inc: { grantedCoins: coinAward }, $set: { releasedCoins: released } },
    { session },
  );

  const personalProgress = await bumpProgress(
    UserProgressModel,
    { userId: new Types.ObjectId(userId) },
    TASK_PERSONAL_XP,
    PERSONAL_LEVEL_CURVE_FACTOR,
    session,
  );
  const householdProgress = await bumpProgress(
    HouseholdProgressModel,
    { householdId: new Types.ObjectId(householdId) },
    TASK_HOUSEHOLD_XP,
    HOUSEHOLD_LEVEL_CURVE_FACTOR,
    session,
  );

  // ── 3. The streak, inside the same transaction (B9). ──
  // A completion that rolls back must not have advanced a flame or spent an
  // ice, so this is not best-effort work that happens afterwards.
  const streak = await recordUsefulActivity(userId, occurredAt, effectiveZone, new Date(), session);

  // ── 4. Only now is the task itself completed. ──
  task.status = 'completed';
  // The instant it actually happened, not the instant it reached us: for an
  // offline completion those differ, and the truthful one is what the receipt
  // and the streak already agree on.
  task.completedAt = occurredAt;
  task.completedBy = new Types.ObjectId(userId);
  await task.save({ session });

  return {
    task,
    reward: {
      coins: coinAward,
      personalXp: TASK_PERSONAL_XP,
      householdXp: TASK_HOUSEHOLD_XP,
    },
    receiptId: grant._id.toString(),
    budget: {
      weekKey: budget.weekKey,
      // `available` was computed BEFORE this grant, so the coins just paid
      // have to come off it — the client is told what is left, not what was
      // left a moment ago.
      remaining: available - coinAward,
      dailyReleased: releasedOnDay(budget.weeklyCap, dayIndex),
    },
    // Renamed on the way out: `xp` is what the projection calls it, but the
    // socket payload sits next to `personalXp` on the client, where an
    // unqualified `xp` would be ambiguous about whose it is.
    householdProgress: {
      householdXp: householdProgress.xp,
      level: householdProgress.level,
    },
    personalDelta: personalProgress,
    householdDelta: householdProgress,
    streak,
  };
}

/**
 * Find or open this member's budget for the week.
 *
 * `upsert` rather than find-then-create: two first-completions racing at the
 * start of a fresh week would otherwise both create one, and the unique index
 * would abort one whole reward transaction over a document neither of them
 * actually disagreed about. The upsert makes the loser read the winner's row.
 */
async function resolveWeeklyBudget(
  userId: string,
  householdId: string,
  key: string,
  timeZone: string,
  session: ClientSession,
): Promise<{
  _id: Types.ObjectId;
  weekKey: string;
  weeklyCap: number;
  grantedCoins: number;
  periodTimeZone: string;
  allocations: IBudgetAllocation[];
}> {
  // The automatic plan is built as the week OPENS, not lazily on the first
  // read (TD-066 B8). Two reasons: a member must be paid their planned
  // amount from their very first completion of the week rather than a flat
  // default until they happen to visit a screen, and freezing the plan at the
  // start of the week is what makes it a plan — one that changed every time
  // the household added a chore would silently reprice work already done.
  const plan = await buildAutomaticPlan(householdId, userId, WEEKLY_CAP_COINS, session);

  const budget = await WeeklyPersonalBudgetModel.findOneAndUpdate(
    {
      userId: new Types.ObjectId(userId),
      householdId: new Types.ObjectId(householdId),
      weekKey: key,
    },
    {
      $setOnInsert: {
        periodTimeZone: timeZone,
        weeklyCap: WEEKLY_CAP_COINS,
        releasedCoins: 0,
        grantedCoins: 0,
        planVersion: 1,
        allocations: plan,
      },
    },
    { upsert: true, new: true, session },
  );

  if (!budget) {
    throw new AppError('Could not resolve the weekly budget', 500);
  }
  return budget;
}

/**
 * Add XP to a projection and recompute its level, creating it if absent.
 *
 * Read-modify-write on one document inside a transaction is safe: a
 * concurrent write to the same document raises a WriteConflict that
 * `withTransaction` retries, rather than silently interleaving. The `$inc` is
 * still used for the XP itself so the retry converges instead of replaying a
 * stale total.
 */
/** What one projection looked like before and after a grant (B7). */
export interface ProgressDelta {
  xp: number;
  level: number;
  /** The level held BEFORE this grant; equal to `level` when it did not rise. */
  previousLevel: number;
  tasksCompleted: number;
  previousTasksCompleted: number;
}

async function bumpProgress(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  projection: mongoose.Model<any>,
  filter: Record<string, unknown>,
  xpDelta: number,
  curveFactor: number,
  session: ClientSession,
): Promise<ProgressDelta> {
  const updated = (await projection.findOneAndUpdate(
    filter,
    { $inc: { xp: xpDelta, tasksCompleted: 1 } },
    { upsert: true, new: true, session, setDefaultsOnInsert: true },
  )) as { xp: number; tasksCompleted: number } | null;

  if (!updated) {
    throw new AppError('Could not update progress projection', 500);
  }

  // Level is derived, never accumulated: recomputing from the authoritative
  // total means a replayed or out-of-order grant cannot drift it.
  const level = levelForXp(updated.xp, curveFactor);

  // The BEFORE values are reconstructed by subtracting this grant's own
  // deltas rather than read in a separate query. One `$inc` with `new: true`
  // is atomic; a read-then-write pair around it would leave a window in which
  // a concurrent grant could make two requests both believe they crossed the
  // same threshold, and announce the same level-up twice.
  const previousLevel = levelForXp(Math.max(0, updated.xp - xpDelta), curveFactor);

  await projection.updateOne(filter, { $set: { level } }, { session });

  return {
    xp: updated.xp,
    level,
    previousLevel,
    tasksCompleted: updated.tasksCompleted,
    previousTasksCompleted: updated.tasksCompleted - 1,
  };
}

/**
 * Answer a request whose claim was already taken.
 *
 * A genuine retry — same member, same client operation — gets its original
 * amounts back, which is what makes the endpoint safe to call twice. Anyone
 * else gets `reward: null`: the task is complete, but this request earned
 * nothing and must not be shown someone else's payout.
 */
async function replayExistingGrant(input: CompleteTaskP1Input): Promise<CompleteTaskP1Result> {
  const { householdId, taskId, userId, operationId } = input;

  const [grant, task] = await Promise.all([
    RewardGrantModel.findOne({
      householdId,
      taskId,
      kind: 'task_first_completion',
    }),
    TaskModel.findOne({ _id: taskId, householdId, isDeleted: { $ne: true } }),
  ]);

  if (!task) {
    throw new AppError('Task not found', 404);
  }
  await populateTask(task);

  const isSameOperation =
    !!grant && grant.userId.toString() === userId && grant.completionOperationId === operationId;

  if (!grant || !isSameOperation) {
    return { task, reward: null, receiptId: grant ? grant._id.toString() : null };
  }

  return {
    task,
    reward: summarize(grant),
    receiptId: grant._id.toString(),
  };
}

function summarize(grant: IRewardGrant): RewardSummary {
  return {
    coins: grant.coinAwarded,
    personalXp: grant.personalXpAwarded,
    householdXp: grant.householdXpAwarded,
  };
}

async function populateTask(task: ITask): Promise<ITask> {
  return task.populate([
    { path: 'assignedTo', select: 'name email avatarUrl' },
    { path: 'createdBy', select: 'name email avatarUrl' },
    { path: 'completedBy', select: 'name email avatarUrl' },
  ]);
}

/**
 * Everything that must NOT be inside the transaction, in the order it has to
 * happen after the commit.
 *
 * Recurrence, push and socket emission are all best-effort by existing
 * contract, and none of them can be rolled back — a socket event cannot be
 * un-emitted. Running them inside the transaction would mean a late abort
 * broadcasting a completion that never happened.
 */
async function afterCommit(
  input: CompleteTaskP1Input,
  outcome: TransactionOutcome,
): Promise<CompleteTaskP1Result> {
  const { householdId, userId, taskId } = input;
  const { task } = outcome;

  try {
    await taskService.generateNextInstance(task);
  } catch (err) {
    logger.error('Error generating next recurrence', (err as Error).message);
  }

  // Owner decision P2(b), 2026-08-26: the Fase A household grant keeps
  // running IN PARALLEL with the personal one during the migration. Without
  // it the household ledger would stop growing the moment P1 switches on,
  // and the pet shop — which still spends that balance (§6.5) — would become
  // unaffordable. Still best-effort, exactly as it is on the Fase A path: it
  // funds a coexisting economy, not this one's receipt.
  try {
    await grantCoins(householdId, TASK_COINS, 'task_complete', taskId);
  } catch (err) {
    logger.error('Error granting Fase A task-complete coins', (err as Error).message);
  }

  await populateTask(task);
  taskService.notifyTaskCompleted(task, userId);
  emitToHousehold(householdId, 'task:completed', task.toJSON());

  // ── P1 realtime (B5), strictly after the commit ──────────────────────────
  // A socket event cannot be un-emitted. Emitting any of these inside the
  // transaction would mean a late abort had already told the client its
  // wallet grew — and the client would have no way to learn otherwise.
  //
  // The split is not cosmetic: coins, personal XP and the weekly budget go to
  // the member ALONE (PDR-012 makes the wallet personal, so broadcasting it
  // to the household room would hand every member everyone else's balance),
  // while household XP is shared by definition (PDR-017) and goes to the
  // household room.
  emitToUser(userId, 'economy:reward', {
    receiptId: outcome.receiptId,
    coins: outcome.reward.coins,
    personalXp: outcome.reward.personalXp,
  });
  emitToUser(userId, 'economy:budget_updated', outcome.budget);
  emitToHousehold(householdId, 'household:xp_updated', outcome.householdProgress);

  emitProgressEvents(householdId, userId, outcome);

  return { task, reward: outcome.reward, receiptId: outcome.receiptId };
}

/**
 * Announce a level or a milestone, but only when this completion is the one
 * that crossed it (TD-066 B7).
 *
 * ── Why nothing records "already announced" ─────────────────────────────
 * Both tracks are monotonic counters that the reward transaction advances
 * exactly once per task — the `RewardGrant` unique index is what guarantees
 * the "once". So "was below, is now at or above" is true for exactly one
 * completion per threshold, and a separate "levels already granted" table
 * would be a second source of truth that could disagree with the first.
 *
 * A retry never reaches here: it returns through `replayExistingGrant`, which
 * increments nothing.
 *
 * The two tracks are split by audience, like the wallet events above.
 * A personal level is the member's own (PDR-017: titles and badges), so it
 * goes to their room alone; a household level belongs to everyone and unlocks
 * shared cosmetics, so it goes to the household room and reads as
 * "lo habéis conseguido juntos" (UX-P1-SPEC §3).
 */
function emitProgressEvents(
  householdId: string,
  userId: string,
  outcome: TransactionOutcome,
): void {
  const { personalDelta, householdDelta } = outcome;

  if (personalDelta.level > personalDelta.previousLevel) {
    emitToUser(userId, 'economy:level_up', {
      track: 'personal',
      level: personalDelta.level,
      previousLevel: personalDelta.previousLevel,
      xp: personalDelta.xp,
      unlocks: unlocksForLevel(personalDelta.level, PERSONAL_LEVEL_UNLOCKS),
    });
  }

  if (householdDelta.level > householdDelta.previousLevel) {
    emitToHousehold(householdId, 'household:level_up', {
      track: 'household',
      level: householdDelta.level,
      previousLevel: householdDelta.previousLevel,
      xp: householdDelta.xp,
      unlocks: unlocksForLevel(householdDelta.level, HOUSEHOLD_LEVEL_UNLOCKS),
    });
  }

  const personalMilestone = milestoneCrossed(
    personalDelta.previousTasksCompleted,
    personalDelta.tasksCompleted,
    PERSONAL_TASK_MILESTONES,
  );
  if (personalMilestone !== null) {
    emitToUser(userId, 'economy:milestone', {
      kind: 'tasks_completed',
      value: personalMilestone,
      total: personalDelta.tasksCompleted,
    });
  }

  const householdMilestone = milestoneCrossed(
    householdDelta.previousTasksCompleted,
    householdDelta.tasksCompleted,
    HOUSEHOLD_TASK_MILESTONES,
  );
  if (householdMilestone !== null) {
    emitToHousehold(householdId, 'household:milestone', {
      kind: 'tasks_completed',
      value: householdMilestone,
      total: householdDelta.tasksCompleted,
    });
  }

  emitStreakEvents(userId, outcome.streak);
}

/**
 * Announce what the completion did to the streak (B9).
 *
 * All personal, all to the member's own room: a flame, an ice reserve and a
 * missed day are exactly the things UX-P1-SPEC §0 rules out turning into a
 * way of keeping score between housemates.
 *
 * `economy:streak_updated` always fires — the header carries the flame, so it
 * has to move on every completion. The other three are events, not state, and
 * fire only when they actually happened.
 */
function emitStreakEvents(userId: string, streak: ActivityResult): void {
  emitToUser(userId, 'economy:streak_updated', {
    current: streak.currentCount,
    longest: streak.longestCount,
    iceReserve: streak.iceReserve,
  });

  for (const day of streak.close.closed) {
    if (day.closeState === 'ice_covered') {
      // "Ayer fue un día complicado. Un hielo cubrió tu racha 🔥 12"
      // (UX-P1-SPEC §7) — a banner of relief, shown when the app reopens.
      emitToUser(userId, 'economy:ice_consumed', {
        dayKey: day.dayKey,
        iceReserve: streak.iceReserve,
        current: streak.currentCount,
      });
    } else if (day.closeState === 'broken') {
      emitToUser(userId, 'economy:streak_broken', { dayKey: day.dayKey });
    }
  }

  if (streak.iceRefunded) {
    emitToUser(userId, 'economy:ice_refunded', { iceReserve: streak.iceReserve });
  }

  if (streak.milestoneReached !== null) {
    emitToUser(userId, 'economy:streak_milestone', {
      value: streak.milestoneReached,
      current: streak.currentCount,
      iceReserve: streak.iceReserve,
    });
  }
}

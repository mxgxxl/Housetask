import { ClientSession, Types } from 'mongoose';

import { AppError } from '../middleware/error.middleware';
import { IRecurrenceRule, ITask, TaskModel } from '../models/Task';
import { IBudgetAllocation, WeeklyPersonalBudgetModel } from '../models/WeeklyPersonalBudget';
import { COMMON_TRANCHE_FRACTION, WEEKLY_CAP_COINS } from '../config/economy-p1';

/**
 * The weekly plan: what each line of work is worth to one member
 * (TD-066 B8, PDR-011).
 *
 * ── The shape of the problem ─────────────────────────────────────────────
 * A member has a weekly ceiling (200 🪙, PDR-012) and a set of recurring
 * commitments. The plan divides the ceiling among those commitments by how
 * often each is expected to happen, so that doing everything exactly as
 * expected consumes exactly the ceiling — no more (that would be inflation,
 * which PDR-011 exists to bound) and no less (which would make the ceiling a
 * lie).
 *
 * Everything here is deterministic: the same household and the same member
 * produce the same plan every time. That is what makes "volver a automático"
 * possible without keeping a second copy of the plan around — recomputing and
 * dropping the manual marks restores it exactly.
 *
 * ── Frequencies are scaled integers ──────────────────────────────────────
 * A weekly frequency is naturally fractional (a monthly chore happens about
 * 0.23 times a week). Rather than carry floats through the weighting, they
 * are expressed in hundredths of a completion per week — daily is 700, weekly
 * is 100 — so the arithmetic that decides money stays exact.
 */

/** Hundredths of a completion per week. Weekly = 100. */
const FREQUENCY_SCALE = 100;

/**
 * Weeks in a month, ×100. A month is not a whole number of weeks, and
 * pretending it is four would over-pay monthly chores by about 8%.
 */
const WEEKS_PER_MONTH_SCALED = 435;

/**
 * The `allocationKey` every unassigned task is funded from (owner decision
 * P3): one common tranche rather than an attribution to a member who never
 * claimed the task.
 */
export const COMMON_TRANCHE_KEY = 'common:unassigned';

/**
 * The `allocationKey` for one-off tasks assigned to the member.
 *
 * Aggregated into a single line rather than one per task: an ad-hoc task
 * exists for days and is then gone, so a per-task line would make the plan
 * churn constantly and every stepper the user adjusted would vanish with the
 * task it belonged to.
 */
export const ADHOC_ASSIGNED_KEY = 'adhoc:assigned';

/** Stable identity of a recurring series, which outlives each occurrence. */
export function seriesKey(task: Pick<ITask, '_id' | 'parentTaskId'>): string {
  return `rule:${(task.parentTaskId ?? task._id).toString()}`;
}

/**
 * How many times a week this task is expected to happen, ×100.
 *
 * A non-recurring task counts as one: it happens once and is done. The
 * recurrence cases mirror `utils/recurrence.ts`'s own reading of the rule, so
 * the plan and the generator cannot disagree about what "every two days"
 * means.
 */
export function expectedWeeklyFrequency(
  isRecurring: boolean,
  rule?: IRecurrenceRule | null,
): number {
  if (!isRecurring || !rule?.type) {
    return FREQUENCY_SCALE;
  }

  const interval = Math.max(1, rule.interval ?? 1);

  switch (rule.type) {
    case 'daily':
      return Math.round((7 * FREQUENCY_SCALE) / interval);
    case 'weekly': {
      // An explicit day list is the real frequency: "Mondays and Thursdays"
      // is twice a week, not once.
      const days = rule.daysOfWeek?.length ?? 1;
      return Math.round((Math.max(1, days) * FREQUENCY_SCALE) / interval);
    }
    case 'monthly':
      return Math.max(1, Math.round(WEEKS_PER_MONTH_SCALED / interval / (FREQUENCY_SCALE / 100)));
    case 'custom':
    default:
      // No agreed meaning to read, so it is treated as a weekly commitment —
      // the middle of the range, and deliberately not zero, which would make
      // the task pay nothing.
      return FREQUENCY_SCALE;
  }
}

/**
 * Split `total` across `weights` without losing or inventing a unit.
 *
 * The same difference-of-floors technique `releasedOnDay` uses, and for the
 * same reason: handing each line `floor(total * w / sum)` independently drops
 * the remainder, so a plan built that way would quietly hand back fewer coins
 * than the ceiling promises.
 */
function splitProportionally(total: number, weights: number[]): number[] {
  const sum = weights.reduce((a, b) => a + b, 0);
  if (sum <= 0) {
    return weights.map(() => 0);
  }

  const shares: number[] = [];
  let cumulativeWeight = 0;
  let cumulativeShare = 0;

  for (const weight of weights) {
    cumulativeWeight += weight;
    const upTo = Math.floor((total * cumulativeWeight) / sum);
    shares.push(upTo - cumulativeShare);
    cumulativeShare = upTo;
  }

  return shares;
}

/** One line of work the plan has to fund, before it has a price. */
interface PlanLine {
  allocationKey: string;
  taskOrRuleId?: Types.ObjectId;
  /** Hundredths of a completion per week. */
  expectedFrequency: number;
}

/**
 * The lines a member's plan covers, derived from the household's open work.
 *
 * Reads only PENDING, non-deleted tasks: a plan is about what is still to be
 * done this week, and including completed ones would keep paying for a
 * commitment that no longer exists.
 */
async function collectLines(
  householdId: string,
  userId: string,
  session?: ClientSession,
): Promise<{ named: PlanLine[]; common: PlanLine }> {
  const query = TaskModel.find({
    householdId: new Types.ObjectId(householdId),
    isDeleted: { $ne: true },
    status: 'pending',
  }).select('_id parentTaskId assignedTo isRecurring recurrenceRule');

  const tasks = await (session ? query.session(session) : query).lean();

  const named = new Map<string, PlanLine>();
  let adhocAssignedFrequency = 0;
  let commonFrequency = 0;

  for (const task of tasks) {
    const frequency = expectedWeeklyFrequency(task.isRecurring, task.recurrenceRule);
    const assignees = (task.assignedTo ?? []).map((id) => id.toString());

    if (assignees.length === 0) {
      // Owner decision P3: nobody claimed it, so it is funded from the shared
      // tranche instead of being attributed to whoever happens to do it.
      commonFrequency += frequency;
      continue;
    }

    if (!assignees.includes(userId)) {
      // Someone else's commitment. It does not consume THIS member's ceiling;
      // if they complete it anyway they fall back to the common tranche, so
      // helping out is still paid.
      continue;
    }

    if (task.isRecurring) {
      // Keyed on the series, not the occurrence: a recurring task creates a
      // new document every week, so a per-occurrence key would make the line
      // — and any stepper the user adjusted on it — expire every week.
      const key = seriesKey(task);
      const existing = named.get(key);
      if (!existing) {
        named.set(key, {
          allocationKey: key,
          taskOrRuleId: task.parentTaskId ?? task._id,
          expectedFrequency: frequency,
        });
      }
      continue;
    }

    adhocAssignedFrequency += frequency;
  }

  const lines = [...named.values()].sort((a, b) => a.allocationKey.localeCompare(b.allocationKey));

  if (adhocAssignedFrequency > 0) {
    lines.push({
      allocationKey: ADHOC_ASSIGNED_KEY,
      expectedFrequency: adhocAssignedFrequency,
    });
  }

  return {
    named: lines,
    common: { allocationKey: COMMON_TRANCHE_KEY, expectedFrequency: commonFrequency },
  };
}

/**
 * Build the deterministic automatic plan for one member (PDR-011).
 *
 * The ceiling is split in two before anything else: `COMMON_TRANCHE_FRACTION`
 * of it funds unassigned work, the rest funds the member's own commitments.
 * That order matters — taking the tranche off the top means a household that
 * never assigns anything still earns from the whole ceiling, which is what
 * keeps PDR-011's "cero configuración por defecto" true.
 *
 * A line's `coinAmount` is its share divided by how often it is expected, so
 * doing it exactly as often as expected consumes exactly its share.
 */
export async function buildAutomaticPlan(
  householdId: string,
  userId: string,
  weeklyCap: number = WEEKLY_CAP_COINS,
  session?: ClientSession,
): Promise<IBudgetAllocation[]> {
  const { named, common } = await collectLines(householdId, userId, session);

  const commonBudget = Math.floor(weeklyCap * COMMON_TRANCHE_FRACTION);
  const namedBudget = weeklyCap - commonBudget;

  const shares = splitProportionally(
    namedBudget,
    named.map((line) => line.expectedFrequency),
  );

  const allocations: IBudgetAllocation[] = named.map((line, index) => ({
    allocationKey: line.allocationKey,
    ...(line.taskOrRuleId ? { taskOrRuleId: line.taskOrRuleId } : {}),
    expectedFrequency: line.expectedFrequency,
    // Integer coins per completion. A line whose share divides to less than
    // one coin pays 0 rather than being rounded up: rounding up is how a plan
    // starts promising more than the ceiling, and the ceiling is the whole
    // point of PDR-011.
    coinAmount: coinsPerCompletion(shares[index], line.expectedFrequency),
    mode: 'automatic' as const,
  }));

  allocations.push({
    allocationKey: COMMON_TRANCHE_KEY,
    expectedFrequency: common.expectedFrequency,
    coinAmount: coinsPerCompletion(commonBudget, common.expectedFrequency),
    mode: 'automatic' as const,
  });

  return allocations;
}

/**
 * What one completion of a line is worth, given its weekly share.
 *
 * `expectedFrequency` is scaled by FREQUENCY_SCALE, so the division undoes
 * that scaling. A line nobody is expected to do gets the whole share for a
 * single completion — there is nothing to spread it over.
 */
function coinsPerCompletion(share: number, expectedFrequency: number): number {
  if (expectedFrequency <= 0) {
    return share;
  }
  return Math.floor((share * FREQUENCY_SCALE) / expectedFrequency);
}

/** What a manual plan promises over a full week, in coins. */
export function planWeeklyCost(allocations: IBudgetAllocation[]): number {
  return allocations.reduce(
    (total, a) => total + Math.floor((a.coinAmount * a.expectedFrequency) / FREQUENCY_SCALE),
    0,
  );
}

export interface ManualAllocationInput {
  allocationKey: string;
  coinAmount: number;
}

/**
 * Apply manual overrides on top of the automatic plan.
 *
 * Only `coinAmount` is a user's to change. `expectedFrequency` is an
 * observation about the household's work, not a preference — letting a member
 * edit it would let them raise their own ceiling by claiming a chore happens
 * ten times a week, which is exactly the inflation the cap prevents.
 *
 * Overriding an unknown `allocationKey` is refused rather than ignored: a
 * silent no-op would let a client believe it had saved a change it had not.
 */
export function applyManualOverrides(
  automatic: IBudgetAllocation[],
  overrides: ManualAllocationInput[],
): IBudgetAllocation[] {
  const byKey = new Map(automatic.map((a) => [a.allocationKey, a]));

  for (const override of overrides) {
    if (!byKey.has(override.allocationKey)) {
      throw new AppError(`Unknown allocation: ${override.allocationKey}`, 400);
    }
  }

  const applied = automatic.map((allocation) => {
    const override = overrides.find((o) => o.allocationKey === allocation.allocationKey);
    if (!override) return allocation;
    return { ...allocation, coinAmount: override.coinAmount, mode: 'manual' as const };
  });

  return applied;
}

export interface UpdateBudgetInput {
  householdId: string;
  userId: string;
  weekKey: string;
  periodTimeZone: string;
  mode: 'automatic' | 'manual';
  allocations?: ManualAllocationInput[];
}

/**
 * Rewrite one member's plan for one week (PDR-011's "ajustar reparto" and
 * "volver a automático").
 *
 * Scoped to a single `weekKey` by construction: the document is unique on
 * `(userId, householdId, weekKey)`, so an edit cannot reach last week's
 * settled numbers or next week's.
 *
 * `planVersion` only ever increases. It is what lets a client that edited a
 * stale plan be told to refetch instead of silently overwriting a newer edit
 * made from another device.
 */
export async function updateWeeklyBudget(input: UpdateBudgetInput): Promise<{
  weekKey: string;
  periodTimeZone: string;
  weeklyCap: number;
  planVersion: number;
  allocations: IBudgetAllocation[];
}> {
  const { householdId, userId, weekKey, periodTimeZone, mode } = input;

  const existing = await WeeklyPersonalBudgetModel.findOne({
    userId: new Types.ObjectId(userId),
    householdId: new Types.ObjectId(householdId),
    weekKey,
  });

  const weeklyCap = existing?.weeklyCap ?? WEEKLY_CAP_COINS;
  const automatic = await buildAutomaticPlan(householdId, userId, weeklyCap);

  let allocations = automatic;
  if (mode === 'manual') {
    allocations = applyManualOverrides(automatic, input.allocations ?? []);

    const cost = planWeeklyCost(allocations);
    if (cost > weeklyCap) {
      throw new AppError(
        `The plan promises ${cost} coins a week, above the ${weeklyCap} ceiling`,
        400,
      );
    }
  }

  const updated = await WeeklyPersonalBudgetModel.findOneAndUpdate(
    {
      userId: new Types.ObjectId(userId),
      householdId: new Types.ObjectId(householdId),
      weekKey,
    },
    {
      $set: { allocations },
      $inc: { planVersion: 1 },
      $setOnInsert: {
        periodTimeZone,
        weeklyCap,
        releasedCoins: 0,
        grantedCoins: 0,
      },
    },
    { upsert: true, new: true },
  );

  if (!updated) {
    throw new AppError('Could not update the weekly budget', 500);
  }

  return {
    weekKey: updated.weekKey,
    periodTimeZone: updated.periodTimeZone,
    weeklyCap: updated.weeklyCap,
    planVersion: updated.planVersion,
    allocations: updated.allocations,
  };
}

/**
 * What this task is worth to this member under their plan.
 *
 * Returns `null` when no plan covers it, which the reward path reads as "fall
 * back to the flat default" — a member completing something on their very
 * first day, before any plan has been built, must still be paid.
 *
 * ── Who a task belongs to ────────────────────────────────────────────────
 * Approved decision 3 of TD-066-DESIGN pays whoever COMPLETES a task, not its
 * assignees. So a task assigned to two people appears in BOTH their plans and
 * the completer is paid from their own line; nothing is split between people.
 * A member completing someone else's assigned task is paid from the common
 * tranche — helping out is still work.
 */
export function resolveAllocationForTask(
  allocations: IBudgetAllocation[],
  task: Pick<ITask, '_id' | 'parentTaskId' | 'assignedTo' | 'isRecurring'>,
  userId: string,
): IBudgetAllocation | null {
  if (allocations.length === 0) return null;

  const assignees = (task.assignedTo ?? []).map((id) => id.toString());
  const byKey = new Map(allocations.map((a) => [a.allocationKey, a]));

  if (assignees.includes(userId)) {
    if (task.isRecurring) {
      const line = byKey.get(seriesKey(task));
      if (line) return line;
    } else {
      const line = byKey.get(ADHOC_ASSIGNED_KEY);
      if (line) return line;
    }
  }

  return byKey.get(COMMON_TRANCHE_KEY) ?? null;
}

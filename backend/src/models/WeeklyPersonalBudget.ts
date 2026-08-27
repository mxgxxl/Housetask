import { Schema, model, Document, Types } from 'mongoose';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * How one allocation of the weekly plan was decided.
 *
 * `automatic` is the deterministic split by expected frequency (PDR-011);
 * `manual` marks a row the member edited in "Ajustar reparto". The
 * distinction is what makes "volver a automático" possible without keeping a
 * second copy of the plan around: recomputing the automatic values and
 * dropping every `manual` mark restores it exactly.
 */
export type AllocationMode = 'automatic' | 'manual';

/**
 * One line of a member's weekly plan: what a given task or rule is worth to
 * them this week.
 */
export interface IBudgetAllocation {
  /**
   * Stable identity of what this line funds, independent of any document id.
   *
   * A recurring series generates a new Task document per occurrence, so
   * keying a plan line on a task `_id` would make it expire every week. The
   * allocation key is what survives that — and it is also where the common
   * tranche for unassigned tasks lives (owner decision P3), which has no
   * document to point at.
   */
  allocationKey: string;
  /** The Task or recurrence rule this funds, when one exists. */
  taskOrRuleId?: Types.ObjectId;
  /** Times per week this is expected to happen; drives the automatic split. */
  expectedFrequency: number;
  /** Coins one completion of this line pays. */
  coinAmount: number;
  mode: AllocationMode;
}

const budgetAllocationSchema = new Schema<IBudgetAllocation>(
  {
    allocationKey: { type: String, required: true },
    taskOrRuleId: { type: Schema.Types.ObjectId },
    expectedFrequency: { type: Number, required: true, min: 0 },
    coinAmount: { type: Number, required: true, min: 0 },
    mode: { type: String, enum: ['automatic', 'manual'], required: true, default: 'automatic' },
  },
  { _id: false },
);

/**
 * One member's coin budget for one ISO week in one household (PDR-011,
 * PDR-012, PDR-013).
 *
 * Scoped to `(userId, householdId, weekKey)` rather than to the user alone,
 * even though the WALLET is personal and unscoped. The budget is a cap on
 * what a household's tasks can pay that member, so a member of two
 * households has two budgets feeding one wallet. Merging them would let one
 * household's activity consume the other's allowance.
 *
 * `periodTimeZone` is snapshotted at creation and never recomputed: it is
 * what makes a settled week reproducible after the member moves or their
 * device reports a different zone (approved decision 1, owner decision P8).
 */
export interface IWeeklyPersonalBudget extends Document {
  _id: Types.ObjectId;
  userId: Types.ObjectId;
  householdId: Types.ObjectId;
  /** ISO week key, `YYYY-Www`, derived in `periodTimeZone`. */
  weekKey: string;
  /** IANA zone this week's day boundaries were computed in. */
  periodTimeZone: string;
  /** The member's ceiling for the week (PDR-012: identical for everyone). */
  weeklyCap: number;
  /**
   * Coins released so far this week, Monday through today.
   *
   * Materialized rather than always recomputed from the day index because it
   * is what a grant checks against under a transaction; recomputing it would
   * mean the check and the write disagree about "today" if the transaction
   * spans midnight.
   */
  releasedCoins: number;
  /** Coins actually paid out of this budget so far. */
  grantedCoins: number;
  /**
   * Bumped on every plan change, so a client that edited a stale plan can be
   * told to refetch instead of silently overwriting someone's newer edit.
   */
  planVersion: number;
  allocations: IBudgetAllocation[];
  createdAt: Date;
  updatedAt: Date;
}

const weeklyPersonalBudgetSchema = new Schema<IWeeklyPersonalBudget>(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    householdId: { type: Schema.Types.ObjectId, ref: 'Household', required: true },
    weekKey: { type: String, required: true },
    periodTimeZone: { type: String, required: true },
    weeklyCap: { type: Number, required: true, min: 0 },
    releasedCoins: { type: Number, required: true, default: 0, min: 0 },
    grantedCoins: { type: Number, required: true, default: 0, min: 0 },
    planVersion: { type: Number, required: true, default: 1, min: 1 },
    allocations: { type: [budgetAllocationSchema], default: [] },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

/**
 * One budget per member per household per week.
 *
 * Also the concurrency guard: two simultaneous first-completions in a fresh
 * week both try to create the budget, and exactly one wins with a
 * duplicate-key error for the other to retry against the existing row —
 * rather than two budgets each granting the full cap.
 */
weeklyPersonalBudgetSchema.index({ userId: 1, householdId: 1, weekKey: 1 }, { unique: true });

export const WeeklyPersonalBudgetModel = model<IWeeklyPersonalBudget>(
  'WeeklyPersonalBudget',
  weeklyPersonalBudgetSchema,
);

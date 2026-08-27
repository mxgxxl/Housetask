import { Schema, model, Document, Types } from 'mongoose';
import { RewardGrantKind, RewardGrantStatus } from '../types/economy-p1';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * The idempotent RECEIPT that ties one task completion to everything it paid
 * out (TD-066-DESIGN §3, §4).
 *
 * This is the keystone of the P1 write path, not a log. The reward
 * transaction CLAIMS a completion by inserting this document first; the
 * unique index below is what turns a retry, a replayed offline operation, a
 * duplicate socket event or a race between two devices into a duplicate-key
 * error instead of a second payout. Everything after the claim — coins, both
 * XP ledgers, the budget, the streak — is written knowing the claim is
 * already exclusive.
 *
 * TD-066-DESIGN §9 names double-reward as risk number one precisely because
 * the app has three paths that can complete a task (the P1 command, the
 * legacy `PATCH .../complete`, and a generic `PATCH` setting
 * `status: 'completed'`). All three route through the same service in B4, and
 * this receipt is why that is safe: whichever arrives second finds the claim
 * taken and returns the original receipt rather than paying again.
 *
 * It also makes the payout AUDITABLE. Storing what was actually awarded — as
 * opposed to recomputing it from today's constants — means a receipt still
 * explains itself after the economy is retuned.
 */
export interface IRewardGrant extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  /**
   * Who earned it: the member who COMPLETED the task, not its assignees
   * (approved decision 3 of TD-066-DESIGN — a task assigned to two people
   * pays whoever actually did it).
   */
  userId: Types.ObjectId;
  taskId: Types.ObjectId;
  kind: RewardGrantKind;
  /**
   * The client's stable operation id for this completion, generated once and
   * persisted before the optimistic UI confirms (TD-066-DESIGN §7).
   *
   * A second, independent idempotency key alongside `taskId`: the task-scoped
   * index stops a double payout for the same task, while this one lets a
   * client that never saw the response recognise its OWN earlier request
   * rather than being told the task was already completed by someone else.
   */
  completionOperationId: string;
  /** Server-validated completion instant (may be older than `createdAt`). */
  effectiveAt: Date;
  /** `YYYY-MM-DD` in the member's zone; the day the streak counts it on. */
  effectiveDayKey: string;
  /** What was actually paid, after the weekly budget was applied. */
  coinAwarded: number;
  personalXpAwarded: number;
  householdXpAwarded: number;
  /** The budget this drew from; absent if none applied (e.g. a Sunday). */
  weeklyBudgetId?: Types.ObjectId;
  status: RewardGrantStatus;
  createdAt: Date;
  updatedAt: Date;
}

const rewardGrantSchema = new Schema<IRewardGrant>(
  {
    householdId: { type: Schema.Types.ObjectId, ref: 'Household', required: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    taskId: { type: Schema.Types.ObjectId, ref: 'Task', required: true },
    kind: { type: String, enum: ['task_first_completion'], required: true },
    completionOperationId: { type: String, required: true },
    effectiveAt: { type: Date, required: true },
    effectiveDayKey: { type: String, required: true },
    // Zero is a legitimate award, not a missing value: a completion on an
    // exhausted budget pays 0 coins and still grants XP (§3). Defaulting
    // these to 0 rather than leaving them optional keeps "paid nothing" and
    // "did not record" distinguishable.
    coinAwarded: { type: Number, required: true, default: 0, min: 0 },
    personalXpAwarded: { type: Number, required: true, default: 0, min: 0 },
    householdXpAwarded: { type: Number, required: true, default: 0, min: 0 },
    weeklyBudgetId: { type: Schema.Types.ObjectId, ref: 'WeeklyPersonalBudget' },
    status: {
      type: String,
      enum: ['granted', 'reverted'],
      required: true,
      default: 'granted',
    },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

/**
 * One reward per task per kind — the guarantee the whole write path rests on.
 *
 * Scoped by household as well as task even though a task belongs to exactly
 * one household: it keeps the index aligned with every other household-scoped
 * query and costs nothing, while making a cross-household id mix-up
 * impossible to express.
 *
 * `kind` is in the key so a future non-completion reward for the same task
 * can exist without weakening this one.
 */
rewardGrantSchema.index({ householdId: 1, taskId: 1, kind: 1 }, { unique: true });

/**
 * The client-operation guarantee, per household.
 *
 * Household-scoped rather than global because the id is generated on a device
 * with no coordination — a UUID collision across households should not be an
 * error, while the same operation replayed into the same household must be.
 */
rewardGrantSchema.index({ householdId: 1, completionOperationId: 1 }, { unique: true });

// "What did this member earn recently" for the wallet and streak screens.
rewardGrantSchema.index({ userId: 1, effectiveAt: -1 });

export const RewardGrantModel = model<IRewardGrant>('RewardGrant', rewardGrantSchema);

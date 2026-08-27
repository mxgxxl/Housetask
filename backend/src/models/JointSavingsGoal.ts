import { Schema, model, Document, Types } from 'mongoose';
import { SavingsGoalStatus } from '../types/economy-p1';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * A household's joint savings goal for a shared item (PDR-018).
 *
 * Explicitly NOT a common wallet. PDR-018 keeps every coin personal and makes
 * this a cooperative mini-mission instead: members move coins OUT of their own
 * wallets into a goal, each move stays attributable to its author, and if the
 * goal never completes every coin goes back where it came from. That is why
 * `contributedCoins` here is a denormalized total for display and threshold
 * checks, while `SavingsContribution` holds the per-member truth that a refund
 * is computed from.
 *
 * "Desbloqueado por X" (UX-P1-SPEC §6) is the other path to the same item —
 * one member paying the full price from their own wallet — and it does not
 * involve this collection at all.
 */
export interface IJointSavingsGoal extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  status: SavingsGoalStatus;
  /** What class of shared item this saves for (e.g. a cosmetic, the pet). */
  itemType: string;
  /** The catalog id of the item; a catalog key, not an ObjectId. */
  itemId: string;
  /** Price to reach, in coins. */
  targetCoins: number;
  /**
   * Sum of the goal's ACTIVE contributions.
   *
   * Denormalized so the threshold check is one atomic `$inc` and compare
   * rather than an aggregation inside the contribution transaction. The
   * contributions remain the source of truth: a refund recomputes from them.
   */
  contributedCoins: number;
  createdBy: Types.ObjectId;
  /** Set when `contributedCoins` first reaches `targetCoins`. */
  unlockedAt?: Date;
  /** Set when the goal is cancelled and its contributions refunded. */
  cancelledAt?: Date;
  /** Who cancelled it — the creator or a household admin. */
  cancelledBy?: Types.ObjectId;
  createdAt: Date;
  updatedAt: Date;
}

const jointSavingsGoalSchema = new Schema<IJointSavingsGoal>(
  {
    householdId: { type: Schema.Types.ObjectId, ref: 'Household', required: true },
    status: {
      type: String,
      enum: ['active', 'unlocked', 'cancelled'],
      required: true,
      default: 'active',
    },
    itemType: { type: String, required: true, trim: true },
    itemId: { type: String, required: true, trim: true },
    targetCoins: { type: Number, required: true, min: 1 },
    contributedCoins: { type: Number, required: true, default: 0, min: 0 },
    createdBy: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    unlockedAt: { type: Date },
    cancelledAt: { type: Date },
    cancelledBy: { type: Schema.Types.ObjectId, ref: 'User' },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

/**
 * At most ONE active goal per household (PDR-018: "En v1 hay una sola meta
 * activa"), enforced by a PARTIAL unique index.
 *
 * Partial is what makes this work at all: a plain unique index on
 * `householdId` would also forbid a second CANCELLED goal, so a household
 * could never save for anything again after abandoning one attempt. The
 * filter narrows the constraint to exactly the rule product stated — one
 * active at a time, any number of finished ones in history.
 *
 * It is also the concurrency guard. Two members creating a goal at the same
 * moment is a plausible race in a household of two looking at the same empty
 * state; without this, both succeed and the household has two goals it has no
 * UI to choose between.
 */
jointSavingsGoalSchema.index(
  { householdId: 1 },
  { unique: true, partialFilterExpression: { status: 'active' } },
);

// The history view: every goal a household has had, newest first.
jointSavingsGoalSchema.index({ householdId: 1, createdAt: -1 });

export const JointSavingsGoalModel = model<IJointSavingsGoal>(
  'JointSavingsGoal',
  jointSavingsGoalSchema,
);

import { Schema, model, Document, Types } from 'mongoose';
import { SavingsContributionStatus } from '../types/economy-p1';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * One member's contribution to a joint savings goal (PDR-018).
 *
 * This is the per-member truth a refund is computed from — the goal's
 * `contributedCoins` is only a denormalized total. Both the cancel path and
 * the member-leaves path walk these rows: cancelling refunds every `active`
 * contribution, and a departure refunds only that member's, deliberately
 * leaving everyone else's untouched (TD-066-DESIGN §4).
 *
 * Each row is paired with a `PersonalCoinLedger` debit when created and, if
 * refunded, a matching credit. The ledger keeps the money; this keeps the
 * attribution — "Tú: 40 · Ana: 28" (UX-P1-SPEC §6) — and the two are written
 * in the same transaction so a wallet can never be debited without a
 * contribution to show for it.
 */
export interface ISavingsContribution extends Document {
  _id: Types.ObjectId;
  goalId: Types.ObjectId;
  /** Denormalized from the goal so a household's contributions list is one query. */
  householdId: Types.ObjectId;
  userId: Types.ObjectId;
  /** Always positive; a refund flips `status`, it does not negate the amount. */
  amount: number;
  status: SavingsContributionStatus;
  /**
   * The client's stable operation id for this contribution.
   *
   * A contribution is a real debit, so it is NOT queued offline under
   * last-write-wins (TD-066-DESIGN §7 is explicit that a monetary debit must
   * not silently adopt LWW semantics). This still exists because an online
   * request can be retried after a timeout, and paying twice for one tap is
   * the failure that matters most here.
   */
  operationId: string;
  createdAt: Date;
  refundedAt?: Date;
  updatedAt: Date;
}

const savingsContributionSchema = new Schema<ISavingsContribution>(
  {
    goalId: { type: Schema.Types.ObjectId, ref: 'JointSavingsGoal', required: true },
    householdId: { type: Schema.Types.ObjectId, ref: 'Household', required: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    amount: { type: Number, required: true, min: 1 },
    status: {
      type: String,
      enum: ['active', 'applied', 'refunded'],
      required: true,
      default: 'active',
    },
    operationId: { type: String, required: true },
    refundedAt: { type: Date },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

/**
 * One contribution per client operation, per goal.
 *
 * Goal-scoped rather than global for the same reason `RewardGrant` scopes its
 * operation id by household: the id comes from an uncoordinated device, so a
 * collision across two goals should not be an error while a replay into the
 * same goal must be.
 */
savingsContributionSchema.index({ goalId: 1, operationId: 1 }, { unique: true });

// The two reads the refund paths need: everything in a goal grouped by
// member (cancel), and one member's contributions to it (departure).
savingsContributionSchema.index({ goalId: 1, userId: 1 });

export const SavingsContributionModel = model<ISavingsContribution>(
  'SavingsContribution',
  savingsContributionSchema,
);

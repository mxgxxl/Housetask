import { Schema, model, Document, Types } from 'mongoose';
import { P1RefType, PersonalCoinReason } from '../types/economy-p1';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * One entry in a member's PERSONAL coin wallet (TD-066, PDR-012).
 *
 * The wallet balance is never stored as a running counter — it is always
 * `sum(amount)` over a user's entries, the same discipline `EconomyLedger`
 * uses for the Fase A household balance. A ledger that is the single source
 * of truth cannot drift out of sync with a cached total, and a wrong balance
 * in a shared household is the kind of bug people notice and do not forgive.
 *
 * `householdId` is carried for CONTEXT AND AUDIT only, never as part of the
 * balance query: PDR-012 makes the wallet personal and portable, so a member
 * in two households has one wallet, not two. Recording which household an
 * entry came from is what makes "where did these coins come from" answerable
 * later; scoping the balance by it would quietly reintroduce the household
 * purse PDR-018 explicitly rejects.
 *
 * Fase A's `EconomyLedger` is NOT replaced by this collection. Both stay live
 * through the whole migration (TD-066-DESIGN §6.5): the pet and its cosmetics
 * keep spending the household balance until a later round moves them.
 */
export interface IPersonalCoinLedgerEntry extends Document {
  _id: Types.ObjectId;
  userId: Types.ObjectId;
  /** Audit context: which household this movement happened in. */
  householdId: Types.ObjectId;
  /** Positive to earn, negative to spend. */
  amount: number;
  reason: PersonalCoinReason;
  refType: P1RefType;
  refId: string;
  /**
   * The budget week this entry counted against, when it was budget-bound.
   * Absent for movements that no weekly cap governs (a refund, the legacy
   * credit), which is why it is optional rather than defaulted.
   */
  weekKey?: string;
  /**
   * When the movement is considered to have happened — the server-validated
   * `occurredAt` for an offline completion, not the moment the row was
   * written. `createdAt` still records the latter, so a late sync is visible
   * as the gap between the two.
   */
  effectiveAt: Date;
  createdAt: Date;
}

const personalCoinLedgerSchema = new Schema<IPersonalCoinLedgerEntry>(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    householdId: { type: Schema.Types.ObjectId, ref: 'Household', required: true },
    amount: { type: Number, required: true },
    reason: {
      type: String,
      enum: [
        'task_first_completion',
        'legacy_balance',
        'savings_contribution',
        'savings_refund',
        'ice_purchase',
      ],
      required: true,
    },
    // Both required (R7). See types/economy-p1.ts for why the Fase A pattern
    // of an optional refId is a trap rather than a convenience.
    refType: {
      type: String,
      enum: ['task', 'savings_contribution', 'legacy_migration', 'ice_purchase'],
      required: true,
    },
    refId: { type: String, required: true },
    weekKey: { type: String },
    effectiveAt: { type: Date, required: true },
  },
  { timestamps: { createdAt: true, updatedAt: false }, ...jsonSchemaOptions },
);

/**
 * The idempotency guarantee: a retried completion, a replayed offline
 * operation, or a duplicate socket-driven write hits a duplicate-key error
 * instead of paying twice.
 *
 * Keyed on the USER, not the household: the wallet is personal, so two
 * members completing the same task in two households would be two different
 * entries and must not collide — while one member retrying the same
 * completion must.
 */
personalCoinLedgerSchema.index({ userId: 1, reason: 1, refType: 1, refId: 1 }, { unique: true });

// Supports both the balance aggregation and the "recent movements" list the
// wallet screen shows: equality on userId, then a scan in createdAt order.
personalCoinLedgerSchema.index({ userId: 1, createdAt: -1 });

export const PersonalCoinLedgerModel = model<IPersonalCoinLedgerEntry>(
  'PersonalCoinLedger',
  personalCoinLedgerSchema,
);

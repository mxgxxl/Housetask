import { Schema, model, Document, Types } from 'mongoose';

export type EconomyReason =
  | 'task_complete'
  | 'purchase_complete'
  | 'feed'
  | 'play'
  | 'cosmetic_buy'
  | 'adoption_bonus';

/**
 * One entry in a household's coin ledger. The balance is never stored as a
 * running counter — it is always `sum(amount)` over a household's entries
 * (economy.service.ts's `getBalance`) — so the ledger itself is the single
 * source of truth and can't drift out of sync with a cached total.
 *
 * The unique (householdId, refId, reason) index is what makes granting
 * idempotent: a second `grantCoins` call for the same task/purchase/
 * cosmetic/etc. and reason hits a duplicate-key error instead of a second
 * row (PDR-001).
 *
 * `refId` is a plain string, not an ObjectId reference: `task_complete`/
 * `purchase_complete` pass a real Task/ShoppingItem id, but
 * `cosmetic_buy` passes a catalog id (e.g. `"hat"`, config/economy.ts's
 * COSMETICS) and `adoption_bonus` passes a synthesized
 * `adoption-<householdId>` key (PDR-001 A2) — neither is a valid ObjectId
 * hex string, so a strict ObjectId type would throw a cast error on every
 * A2 grant. String is the common type that fits every reason.
 */
export interface IEconomyLedgerEntry extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  amount: number;
  reason: EconomyReason;
  refId?: string;
  createdAt: Date;
}

const economyLedgerSchema = new Schema<IEconomyLedgerEntry>(
  {
    householdId: {
      type: Schema.Types.ObjectId,
      ref: 'Household',
      required: true,
      index: true,
    },
    amount: { type: Number, required: true },
    reason: {
      type: String,
      enum: ['task_complete', 'purchase_complete', 'feed', 'play', 'cosmetic_buy', 'adoption_bonus'],
      required: true,
    },
    refId: { type: String },
  },
  { timestamps: { createdAt: true, updatedAt: false } },
);

economyLedgerSchema.index({ householdId: 1, refId: 1, reason: 1 }, { unique: true });

// Supports getDailyEarned's "sum earned today" scan: equality on householdId,
// then a range on createdAt. Without this it would fall back to scanning
// every entry the household has ever earned.
economyLedgerSchema.index({ householdId: 1, createdAt: -1 });

export const EconomyLedgerModel = model<IEconomyLedgerEntry>('EconomyLedger', economyLedgerSchema);

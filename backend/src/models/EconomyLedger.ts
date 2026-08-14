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
 * idempotent: a second `grantCoins` call for the same task/purchase and
 * reason hits a duplicate-key error instead of a second row (PDR-001).
 * This currently only covers `task_complete`/`purchase_complete`, the only
 * reasons wired to a `refId` this round — see economy.service.ts's
 * `grantCoins` doc comment for what a future refId-less reason (feed/play/
 * cosmetic_buy/adoption_bonus) will need before it can reuse this index.
 */
export interface IEconomyLedgerEntry extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  amount: number;
  reason: EconomyReason;
  refId?: Types.ObjectId;
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
    refId: { type: Schema.Types.ObjectId },
  },
  { timestamps: { createdAt: true, updatedAt: false } },
);

economyLedgerSchema.index({ householdId: 1, refId: 1, reason: 1 }, { unique: true });

// Supports getDailyEarned's "sum earned today" scan: equality on householdId,
// then a range on createdAt. Without this it would fall back to scanning
// every entry the household has ever earned.
economyLedgerSchema.index({ householdId: 1, createdAt: -1 });

export const EconomyLedgerModel = model<IEconomyLedgerEntry>('EconomyLedger', economyLedgerSchema);

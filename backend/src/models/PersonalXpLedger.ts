import { Schema, model, Document, Types } from 'mongoose';
import { P1RefType, XpReason } from '../types/economy-p1';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * One entry in a member's PORTABLE personal XP ledger (PDR-017).
 *
 * Deliberately carries no `householdId`, unlike the coin ledger which keeps
 * one for audit. Personal XP is the thing that must survive leaving a
 * household — "Tu nivel viaja contigo" (UX-P1-SPEC §4) — and a household
 * reference on the entry would invite a future query to scope XP by it,
 * which is precisely the portability PDR-017 exists to protect. If the
 * provenance of an XP grant is ever needed, `refId` points at the task and
 * the task knows its household.
 *
 * XP is never reduced when a member's weekly coin budget runs out
 * (TD-066-DESIGN §3): the coin ledger and this one are written in the same
 * transaction but are not the same decision.
 */
export interface IPersonalXpLedgerEntry extends Document {
  _id: Types.ObjectId;
  userId: Types.ObjectId;
  /** Always positive in P1: nothing revokes XP (PDR-019). */
  amount: number;
  reason: XpReason;
  refType: P1RefType;
  refId: string;
  createdAt: Date;
}

const personalXpLedgerSchema = new Schema<IPersonalXpLedgerEntry>(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    amount: { type: Number, required: true },
    reason: { type: String, enum: ['task_first_completion'], required: true },
    refType: {
      type: String,
      enum: ['task', 'savings_contribution', 'legacy_migration', 'ice_purchase'],
      required: true,
    },
    refId: { type: String, required: true },
  },
  { timestamps: { createdAt: true, updatedAt: false }, ...jsonSchemaOptions },
);

// Same anti-double-grant guarantee as the coin ledger. Both indexes must
// hold for one completion: the transaction writes coins and XP together, so
// a retry that got past one and not the other would leave the two tracks
// disagreeing about the same task.
personalXpLedgerSchema.index({ userId: 1, reason: 1, refType: 1, refId: 1 }, { unique: true });

// Rebuilding UserProgress from scratch, and any "XP earned since" query.
personalXpLedgerSchema.index({ userId: 1, createdAt: -1 });

export const PersonalXpLedgerModel = model<IPersonalXpLedgerEntry>(
  'PersonalXpLedger',
  personalXpLedgerSchema,
);

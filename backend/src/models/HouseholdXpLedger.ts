import { Schema, model, Document, Types } from 'mongoose';
import { P1RefType, XpReason } from '../types/economy-p1';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * One entry in a household's SHARED XP ledger (PDR-017).
 *
 * The mirror image of `PersonalXpLedger`: this one is scoped to the household
 * and does not travel. Its levels unlock shared cosmetics and the pet, while
 * the personal track unlocks titles and badges — "El nivel de hogar es de los
 * dos" (UX-P1-SPEC §4).
 *
 * One task completion writes to BOTH ledgers with the same `refId`. That is
 * intentional duplication, not redundancy: the two tracks advance at
 * different rates (a household pools every member's activity) and one of them
 * has to survive the other's owner leaving.
 */
export interface IHouseholdXpLedgerEntry extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  /** Always positive in P1. */
  amount: number;
  reason: XpReason;
  refType: P1RefType;
  refId: string;
  createdAt: Date;
}

const householdXpLedgerSchema = new Schema<IHouseholdXpLedgerEntry>(
  {
    householdId: { type: Schema.Types.ObjectId, ref: 'Household', required: true },
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

/**
 * Keyed on the HOUSEHOLD rather than the completing member.
 *
 * A task belongs to exactly one household, so this is what makes "one
 * household XP grant per task" true regardless of who completed it — and it
 * would still hold if a future rule let a second member re-trigger a grant.
 */
householdXpLedgerSchema.index(
  { householdId: 1, reason: 1, refType: 1, refId: 1 },
  { unique: true },
);

householdXpLedgerSchema.index({ householdId: 1, createdAt: -1 });

export const HouseholdXpLedgerModel = model<IHouseholdXpLedgerEntry>(
  'HouseholdXpLedger',
  householdXpLedgerSchema,
);

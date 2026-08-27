import { Schema, model, Document, Types } from 'mongoose';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * A household's shared XP total and level — a PROJECTION of
 * `HouseholdXpLedger`, on the same terms as `UserProgress` (TD-066-DESIGN §3):
 * written inside the transaction that moves it, rebuildable by summing the
 * ledger, and never the authority when the two disagree.
 *
 * Its unlocks are the household's (shared cosmetics, the pet), and unlike the
 * personal track it does not survive its household.
 */
export interface IHouseholdProgress extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  /** Cumulative household XP; equals `sum(HouseholdXpLedger.amount)`. */
  xp: number;
  /** Derived from `xp` via `levelForXp` with the household curve factor. */
  level: number;
  /**
   * First completions the household has been rewarded for, pooled across
   * every member. Same rationale and the same reconstructibility as
   * `UserProgress.tasksCompleted` (B7, not in design §3).
   */
  tasksCompleted: number;
  createdAt: Date;
  updatedAt: Date;
}

const householdProgressSchema = new Schema<IHouseholdProgress>(
  {
    householdId: {
      type: Schema.Types.ObjectId,
      ref: 'Household',
      required: true,
      unique: true,
    },
    xp: { type: Number, required: true, default: 0, min: 0 },
    level: { type: Number, required: true, default: 1, min: 1 },
    tasksCompleted: { type: Number, required: true, default: 0, min: 0 },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

export const HouseholdProgressModel = model<IHouseholdProgress>(
  'HouseholdProgress',
  householdProgressSchema,
);

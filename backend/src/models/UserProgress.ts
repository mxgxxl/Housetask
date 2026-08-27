import { Schema, model, Document, Types } from 'mongoose';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * A member's personal XP total and level — a PROJECTION of
 * `PersonalXpLedger`, never an independent source of truth (TD-066-DESIGN §3).
 *
 * Written in the same transaction as the ledger entry that moves it, so the
 * two can never disagree at rest. If they ever do, the ledger wins and this
 * document is rebuilt by summing it: that property is what makes keeping a
 * projection safe at all, and it is asserted directly in the B2 tests rather
 * than assumed.
 *
 * It exists because the alternative is aggregating a member's whole XP
 * history on every read of the persistent header (UX-P1-SPEC §2 puts the
 * level ring on screen at all times), which is a full-history scan to render
 * one number.
 *
 * Carries NO `householdId` (PDR-017): XP, level, titles and badges are
 * portable, so there is exactly one of these per user, not one per
 * membership.
 */
export interface IUserProgress extends Document {
  _id: Types.ObjectId;
  userId: Types.ObjectId;
  /** Cumulative personal XP; equals `sum(PersonalXpLedger.amount)`. */
  xp: number;
  /** Derived from `xp` via `levelForXp`; stored so reads need no math. */
  level: number;
  /**
   * First completions this member has been rewarded for, ever.
   *
   * NOT in TD-066-DESIGN §3: added in B7 so a task-count milestone can be
   * detected by comparing the value before and after one `$inc`, instead of
   * counting `RewardGrant` documents on every completion — a scan that grows
   * without bound for a number needed on the hot write path.
   *
   * Reconstructible like `xp` is: it equals the member's `RewardGrant` count.
   */
  tasksCompleted: number;
  createdAt: Date;
  updatedAt: Date;
}

const userProgressSchema = new Schema<IUserProgress>(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true, unique: true },
    xp: { type: Number, required: true, default: 0, min: 0 },
    // Level 1 is the floor: everyone starts there with 0 XP, and nothing in
    // P1 can demote (PDR-019: "nivel, XP y monedas permanecen intactos").
    level: { type: Number, required: true, default: 1, min: 1 },
    tasksCompleted: { type: Number, required: true, default: 0, min: 0 },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

export const UserProgressModel = model<IUserProgress>('UserProgress', userProgressSchema);

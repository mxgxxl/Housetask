import { Schema, model, Document, Types } from 'mongoose';
import { StreakScope } from '../types/economy-p1';
import { MAX_ICE_RESERVE } from '../config/economy-p1';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * A member's activity streak and ice reserve (PDR-019).
 *
 * Anchored to the ACCOUNT in v1 (owner decision P4, 2026-08-26), matching the
 * portability of personal XP: leaving a household must not reset a streak any
 * more than it resets a level. `scope`/`scopeId` keep the shape open for a
 * per-household streak without a migration, because TD-066-DESIGN §3 left
 * that question to product; nothing writes `household` in P1.
 *
 * The streak itself is derived state — `StreakDay` holds the evidence, this
 * holds the running answer — but it is NOT a pure projection like
 * `UserProgress`: `iceReserve` is a resource that gets spent and refunded, so
 * replaying the days is how you audit it, not how you rebuild it.
 */
export interface IPersonalStreak extends Document {
  _id: Types.ObjectId;
  userId: Types.ObjectId;
  scope: StreakScope;
  /** The household, when `scope` is `household`. Null for an account streak. */
  scopeId?: Types.ObjectId | null;
  /** Consecutive qualifying days; reset to 0 by an uncovered miss. */
  currentCount: number;
  /**
   * The highest `currentCount` ever reached, which a reset never lowers.
   *
   * NOT part of TD-066-DESIGN §3, which lists only `currentCount`: added in B6
   * because the read contract exposes a "longest" figure and the alternative
   * was deriving it by walking every `StreakDay` on every read. It also gives
   * the ice milestones (7/14/30/50/100, PDR-019) a monotonic number to be
   * judged against — judging them against `currentCount` would make an
   * already-earned milestone disappear the moment a streak breaks, which is
   * exactly the punitive tone PDR-019 rejects.
   *
   * Nothing writes it until B9; it stays 0 until then.
   */
  longestCount: number;
  /** Ices held, always within [0, MAX_ICE_RESERVE] (PDR-019). */
  iceReserve: number;
  /**
   * The last `YYYY-MM-DD` whose outcome has been decided.
   *
   * Days are closed lazily — on the next read or write that needs them
   * (TD-066-DESIGN §4) — rather than by a cron, so this marks how far the
   * lazy close has actually got. Absent until the first day closes.
   */
  lastClosedDayKey?: string;
  createdAt: Date;
  updatedAt: Date;
}

const personalStreakSchema = new Schema<IPersonalStreak>(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    scope: { type: String, enum: ['account', 'household'], required: true, default: 'account' },
    // Explicitly nullable rather than absent: the unique index below treats
    // two missing values as equal, which is exactly what makes "one account
    // streak per user" enforceable.
    scopeId: { type: Schema.Types.ObjectId, default: null },
    currentCount: { type: Number, required: true, default: 0, min: 0 },
    longestCount: { type: Number, required: true, default: 0, min: 0 },
    /**
     * Bounded in the SCHEMA, not only in the service that spends and refunds
     * it. The cap is a product rule (PDR-019: "tope de dos en reserva") and
     * approved decision 5 turns it into a correctness rule — a late-sync
     * refund is discarded when the reserve is full — so an off-by-one in a
     * future refund path should fail the write, not silently inflate the
     * protection people are shielded by.
     */
    iceReserve: { type: Number, required: true, default: 0, min: 0, max: MAX_ICE_RESERVE },
    lastClosedDayKey: { type: String },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

/**
 * One streak per user per scope.
 *
 * With `scopeId` defaulting to null, this makes exactly one `account` streak
 * per user possible while leaving room for one per household later.
 */
personalStreakSchema.index({ userId: 1, scope: 1, scopeId: 1 }, { unique: true });

export const PersonalStreakModel = model<IPersonalStreak>('PersonalStreak', personalStreakSchema);

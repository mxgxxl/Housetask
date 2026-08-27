import { Schema, model, Document, Types } from 'mongoose';
import { StreakDayCloseState } from '../types/economy-p1';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * One day of a streak, and the evidence behind its outcome (PDR-019).
 *
 * Kept as its own document rather than folded into `PersonalStreak` because a
 * day's verdict is REVISABLE: a completion that happened offline on Tuesday
 * and syncs on Thursday must be able to reopen Tuesday, restore the ice it
 * consumed, and leave a trace that it did. A running counter cannot do that;
 * a per-day row with the activity count and the ice flags can.
 *
 * It is also what the streak calendar renders — 🔥 / ❄️ / 🌿 / hueco
 * (UX-P1-SPEC §4) — so the display and the accounting read the same rows
 * instead of deriving the same thing twice.
 */
export interface IStreakDay extends Document {
  _id: Types.ObjectId;
  streakId: Types.ObjectId;
  /** `YYYY-MM-DD` in the member's zone at the time the day was resolved. */
  dayKey: string;
  /**
   * How many qualifying activities landed on this day.
   *
   * A count rather than a boolean so a late sync can increment it without
   * having to know whether the day was already active — and so "how busy was
   * that day" stays answerable for the load work in TD-069.
   */
  usefulActivityCount: number;
  /** An ice was spent to cover this day. */
  iceConsumed: boolean;
  /**
   * A consumed ice was later returned because activity arrived late.
   *
   * Separate from clearing `iceConsumed` on purpose: the day WAS covered, and
   * erasing that would lose the audit trail for a refund that approved
   * decision 5 makes conditional. `iceConsumed && iceRefunded` is a real,
   * meaningful state.
   */
  iceRefunded: boolean;
  closeState: StreakDayCloseState;
  createdAt: Date;
  updatedAt: Date;
}

const streakDaySchema = new Schema<IStreakDay>(
  {
    streakId: { type: Schema.Types.ObjectId, ref: 'PersonalStreak', required: true },
    dayKey: { type: String, required: true },
    usefulActivityCount: { type: Number, required: true, default: 0, min: 0 },
    iceConsumed: { type: Boolean, required: true, default: false },
    iceRefunded: { type: Boolean, required: true, default: false },
    closeState: {
      type: String,
      enum: ['open', 'active', 'ice_covered', 'broken', 'rest'],
      required: true,
      default: 'open',
    },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

/**
 * One row per streak per day.
 *
 * The guard against double-processing a lazy close: two concurrent requests
 * that both notice yesterday is unresolved race to create this row, and
 * exactly one wins — so an ice is consumed once, not once per request that
 * happened to arrive first thing in the morning.
 */
streakDaySchema.index({ streakId: 1, dayKey: 1 }, { unique: true });

// Rendering the streak calendar, and finding the days a late sync may still
// reopen: newest first within one streak.
streakDaySchema.index({ streakId: 1, dayKey: -1 });

export const StreakDayModel = model<IStreakDay>('StreakDay', streakDaySchema);

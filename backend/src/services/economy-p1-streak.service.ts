import { ClientSession, Types } from 'mongoose';

import { AppError } from '../middleware/error.middleware';
import { IPersonalStreak, PersonalStreakModel } from '../models/PersonalStreak';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { StreakDayCloseState } from '../types/economy-p1';
import { IStreakDay, StreakDayModel } from '../models/StreakDay';
import {
  ICE_PRICE_COINS,
  MAX_ICE_RESERVE,
  STREAK_ICE_MILESTONES,
  milestoneCrossed,
} from '../config/economy-p1';
import { SUNDAY_INDEX, effectiveDayKey, resolveTimeZone } from '../utils/economy-period';

/**
 * Streaks, ice and the late-sync refund (TD-066 B9, PDR-019).
 *
 * ── Why days close lazily ────────────────────────────────────────────────
 * A streak needs a verdict for every day, but nothing runs at midnight. Rather
 * than add a cron — infrastructure whose failure would be silent, and whose
 * timezone would have to be guessed for every member at once — days are closed
 * on the next read or write that needs them (TD-066-DESIGN §4). The unique
 * index on `(streakId, dayKey)` is what makes that safe under concurrency:
 * two requests arriving together race to create the same day, and exactly one
 * wins, so an ice is consumed once rather than once per request.
 *
 * ── Why the count moves on activity, not on close ───────────────────────
 * `currentCount` is incremented the moment a day records its FIRST useful
 * activity, not when that day is later closed. Otherwise the flame would not
 * move until tomorrow, and "🔥 12" would be a number about the past rather
 * than about what the user just did — which is the opposite of the immediate,
 * low-ceremony feedback UX-P1-SPEC §3 asks for.
 */

const DAY_MS = 24 * 60 * 60 * 1000;

/** `YYYY-MM-DD` → the same calendar day as a UTC anchor for date arithmetic. */
function dayKeyToAnchor(dayKey: string): Date {
  const [year, month, day] = dayKey.split('-').map(Number);
  return new Date(Date.UTC(year, month - 1, day));
}

function anchorToDayKey(anchor: Date): string {
  return anchor.toISOString().slice(0, 10);
}

/** Day index (0 = Monday … 6 = Sunday) of a `YYYY-MM-DD` key. */
export function dayIndexOfKey(dayKey: string): number {
  return (dayKeyToAnchor(dayKey).getUTCDay() + 6) % 7;
}

function nextDayKey(dayKey: string): string {
  return anchorToDayKey(new Date(dayKeyToAnchor(dayKey).getTime() + DAY_MS));
}

/** How many whole days separate two `YYYY-MM-DD` keys. */
function daysBetween(from: string, to: string): number {
  return Math.round((dayKeyToAnchor(to).getTime() - dayKeyToAnchor(from).getTime()) / DAY_MS);
}

/**
 * The member's account-scoped streak, created on first use.
 *
 * Account-scoped by owner decision P4: a streak travels with the person, like
 * personal XP (PDR-017), so leaving a household never costs one.
 */
export async function ensureStreak(
  userId: string,
  session?: ClientSession,
): Promise<IPersonalStreak> {
  const filter = { userId: new Types.ObjectId(userId), scope: 'account' as const, scopeId: null };

  const run = async (): Promise<IPersonalStreak | null> => {
    const query = PersonalStreakModel.findOneAndUpdate(
      filter,
      { $setOnInsert: { currentCount: 0, longestCount: 0, iceReserve: 0 } },
      { upsert: true, new: true, setDefaultsOnInsert: true },
    );
    return session ? query.session(session) : query;
  };

  let streak: IPersonalStreak | null;
  try {
    streak = await run();
  } catch (err) {
    // An upsert is not atomic against a concurrent upsert on the same key:
    // two tasks completed at the same instant by the same member both find no
    // streak and both try to insert one, and the unique index rejects the
    // loser. That is the index doing its job, not a failure — but letting it
    // propagate would abort a whole reward transaction over a document the
    // two requests did not actually disagree about, and the member would see
    // a 500 for completing two tasks quickly.
    if (typeof err === 'object' && err !== null && (err as { code?: number }).code === 11000) {
      const query = PersonalStreakModel.findOne(filter);
      streak = await (session ? query.session(session) : query);
    } else {
      throw err;
    }
  }

  if (!streak) {
    throw new AppError('Could not resolve the personal streak', 500);
  }
  return streak;
}

/** What closing a stretch of days did, so the caller can announce it. */
export interface CloseResult {
  /** Days closed by this call, oldest first. */
  closed: { dayKey: string; closeState: StreakDayCloseState }[];
  icesConsumed: number;
  streakBroken: boolean;
}

/**
 * Give every day up to (but excluding) `todayKey` a verdict.
 *
 * Bounded to `MAX_CLOSE_DAYS` in one pass. A member returning after months
 * would otherwise walk hundreds of days inside a reward transaction; the
 * streak is broken long before that anyway, so the walk is capped and the
 * pointer jumps forward.
 */
const MAX_CLOSE_DAYS = 60;

export async function closeDaysUpTo(
  streak: IPersonalStreak,
  todayKey: string,
  session?: ClientSession,
): Promise<CloseResult> {
  const result: CloseResult = { closed: [], icesConsumed: 0, streakBroken: false };

  if (!streak.lastClosedDayKey) {
    // Nothing has ever been closed. There is no history to judge, so the day
    // before today becomes the starting point rather than inventing verdicts
    // for days that predate the member's first activity.
    streak.lastClosedDayKey = anchorToDayKey(new Date(dayKeyToAnchor(todayKey).getTime() - DAY_MS));
  }

  let cursor = nextDayKey(streak.lastClosedDayKey);
  const gap = daysBetween(cursor, todayKey);

  if (gap > MAX_CLOSE_DAYS) {
    // Far too long to be a protectable absence: the streak is gone and no ice
    // is spent covering days nobody expected to be covered.
    streak.currentCount = 0;
    streak.lastClosedDayKey = anchorToDayKey(new Date(dayKeyToAnchor(todayKey).getTime() - DAY_MS));
    result.streakBroken = true;
    cursor = todayKey;
  }

  while (daysBetween(cursor, todayKey) > 0) {
    const day = await findOrCreateDay(streak, cursor, session);
    const isRestDay = dayIndexOfKey(cursor) === SUNDAY_INDEX;

    let closeState: StreakDayCloseState;
    if (isRestDay) {
      // PDR-013/PDR-019: Sunday is rest by design. It neither breaks a streak
      // nor spends an ice protecting one.
      closeState = 'rest';
    } else if (day.usefulActivityCount > 0) {
      closeState = 'active';
    } else if (streak.iceReserve > 0) {
      streak.iceReserve -= 1;
      day.iceConsumed = true;
      result.icesConsumed += 1;
      closeState = 'ice_covered';
    } else {
      streak.currentCount = 0;
      result.streakBroken = true;
      closeState = 'broken';
    }

    day.closeState = closeState;
    await day.save({ session });

    result.closed.push({ dayKey: cursor, closeState });
    streak.lastClosedDayKey = cursor;
    cursor = nextDayKey(cursor);
  }

  return result;
}

async function findOrCreateDay(
  streak: IPersonalStreak,
  dayKey: string,
  session?: ClientSession,
): Promise<IStreakDay> {
  const query = StreakDayModel.findOneAndUpdate(
    { streakId: streak._id, dayKey },
    { $setOnInsert: { usefulActivityCount: 0, iceConsumed: false, iceRefunded: false } },
    { upsert: true, new: true, setDefaultsOnInsert: true },
  );
  const day = await (session ? query.session(session) : query);
  if (!day) {
    throw new AppError('Could not resolve the streak day', 500);
  }
  return day;
}

/** What recording one completion did to the streak, for the caller to announce. */
export interface ActivityResult {
  currentCount: number;
  longestCount: number;
  iceReserve: number;
  /** A streak milestone reached by this completion, if any (PDR-019). */
  milestoneReached: number | null;
  /** True when a late sync gave back an ice this call. */
  iceRefunded: boolean;
  close: CloseResult;
}

/**
 * Record one useful activity and bring the streak up to date.
 *
 * Order matters: past days are closed FIRST, so a break that happened
 * yesterday cannot wipe the increment this completion is about to make.
 *
 * A completion whose `occurredAt` lands on an already-closed day is the late
 * offline sync of TD-066-DESIGN §4. It still counts as activity, and if that
 * day had been covered by an ice the ice comes back — but only when the
 * reserve has room, which is approved decision 5's reading of PDR-019:
 * "refund if there is capacity", not unconditionally. At two ices the
 * protection already did its job and returning a third would reintroduce the
 * inflation the cap exists to prevent.
 */
export async function recordUsefulActivity(
  userId: string,
  occurredAt: Date,
  timeZone: string,
  now: Date,
  session?: ClientSession,
): Promise<ActivityResult> {
  const zone = resolveTimeZone(timeZone);
  const streak = await ensureStreak(userId, session);
  // Captured before anything moves. Reconstructing it afterwards by
  // subtracting one would be wrong whenever the longest run did NOT change —
  // a member at 30 whose current run reaches 7 would look like they had just
  // crossed 30 and be handed an ice they earned months ago.
  const longestBefore = streak.longestCount;

  const todayKey = effectiveDayKey(now, zone);
  const activityKey = effectiveDayKey(occurredAt, zone);

  const close = await closeDaysUpTo(streak, todayKey, session);

  const day = await findOrCreateDay(streak, activityKey, session);
  const wasFirstActivity = day.usefulActivityCount === 0;
  day.usefulActivityCount += 1;

  let iceRefunded = false;
  if (day.closeState === 'open') {
    // Today, or a day still awaiting its verdict. The flame moves now rather
    // than tomorrow.
    if (wasFirstActivity && dayIndexOfKey(activityKey) !== SUNDAY_INDEX) {
      streak.currentCount += 1;
    } else if (wasFirstActivity) {
      // Sunday grants XP and never breaks a streak (PDR-013), but it is a
      // rest day: it does not extend the count either.
      streak.currentCount += 0;
    }
  } else if (day.closeState === 'ice_covered' && day.iceConsumed && !day.iceRefunded) {
    if (streak.iceReserve < MAX_ICE_RESERVE) {
      streak.iceReserve += 1;
      day.iceRefunded = true;
      // The day WAS covered; `iceConsumed` stays true so the audit trail of
      // what happened survives alongside the correction (see StreakDay).
      day.closeState = 'active';
      iceRefunded = true;
    }
    // At the cap the refund is discarded on purpose (approved decision 5).
  }
  // A day already closed as `broken` keeps its verdict. PDR-019's refund is
  // about ice, and nothing in the design un-breaks a streak retroactively —
  // doing so would mean replaying every later day's verdict, including ices
  // already spent. The activity is still recorded, so the history is honest.

  await day.save({ session });

  if (streak.currentCount > streak.longestCount) {
    streak.longestCount = streak.currentCount;
  }

  // Milestones are judged against the LONGEST run, which only ever grows, so
  // each is granted exactly once in a member's life and nothing has to record
  // which have already fired. Judging them against `currentCount` would let a
  // reset re-award them, and would also disagree with the read contract,
  // which derives "reached" from the same monotonic number (B7).
  const milestoneReached = milestoneCrossed(
    longestBefore,
    streak.longestCount,
    STREAK_ICE_MILESTONES,
  );
  if (milestoneReached !== null && streak.iceReserve < MAX_ICE_RESERVE) {
    streak.iceReserve += 1;
  }

  await streak.save({ session });

  return {
    currentCount: streak.currentCount,
    longestCount: streak.longestCount,
    iceReserve: streak.iceReserve,
    milestoneReached,
    iceRefunded,
    close,
  };
}

export interface BuyIceResult {
  iceReserve: number;
  spent: number;
  balance: number;
}

/**
 * Buy one ice for `ICE_PRICE_COINS` from the member's personal wallet
 * (PDR-019).
 *
 * Refused at the cap rather than taking the money and discarding the ice, and
 * refused on an insufficient balance rather than allowing a negative wallet —
 * the ledger sums to the balance, so a debit past zero would not just look
 * wrong, it would BE the balance.
 *
 * `operationId` makes the purchase idempotent through the ledger's unique
 * index: a retried tap after a timeout hits a duplicate key instead of buying
 * a second ice.
 */
export async function buyIce(
  userId: string,
  householdId: string,
  operationId: string,
  session: ClientSession,
): Promise<BuyIceResult> {
  const streak = await ensureStreak(userId, session);

  if (streak.iceReserve >= MAX_ICE_RESERVE) {
    throw new AppError(`You already hold the maximum of ${MAX_ICE_RESERVE} ices`, 409);
  }

  const [balanceRow] = await PersonalCoinLedgerModel.aggregate<{ total: number }>([
    { $match: { userId: new Types.ObjectId(userId) } },
    { $group: { _id: null, total: { $sum: '$amount' } } },
  ]).session(session);
  const balance = balanceRow?.total ?? 0;

  if (balance < ICE_PRICE_COINS) {
    throw new AppError(`An ice costs ${ICE_PRICE_COINS} coins; your balance is ${balance}`, 400);
  }

  await PersonalCoinLedgerModel.create(
    [
      {
        userId: new Types.ObjectId(userId),
        householdId: new Types.ObjectId(householdId),
        amount: -ICE_PRICE_COINS,
        reason: 'ice_purchase' as const,
        refType: 'ice_purchase' as const,
        refId: operationId,
        effectiveAt: new Date(),
      },
    ],
    { session },
  );

  streak.iceReserve += 1;
  await streak.save({ session });

  return {
    iceReserve: streak.iceReserve,
    spent: ICE_PRICE_COINS,
    balance: balance - ICE_PRICE_COINS,
  };
}

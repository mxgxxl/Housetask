/**
 * Calendar and budget arithmetic for the P1 economy (TD-066).
 *
 * Every function here is pure: no database, no clock of its own (the instant
 * is always a parameter), no logging on the hot path. That is deliberate —
 * this is the layer where an off-by-one becomes coin inflation, so it has to
 * be exhaustively testable without a Mongo replica set standing by.
 *
 * ── Why IANA, and what exactly is stored ─────────────────────────────────
 * Approved decision 1 of TD-066-DESIGN, confirmed by owner decision P8
 * (2026-08-26): instants are stored in UTC, as they always have been, but
 * `weekKey` and `effectiveDayKey` are DERIVED in the household member's IANA
 * zone. The zone is snapshotted into `WeeklyPersonalBudget.periodTimeZone` so
 * a budget stays reproducible even if the member later moves.
 *
 * The alternative — grouping in UTC — was allowed as a v1 fallback and
 * rejected: a Madrid user completing a task at 00:30 local on Monday would
 * have it counted against Sunday, the one day of the week that releases no
 * coins (PDR-013). That is not a rounding difference, it is a silently
 * unpaid task, and retro-deriving the correct week later is strictly harder
 * than getting it right now.
 *
 * The host process's own timezone is never consulted. Every civil-date
 * computation goes through `Intl.DateTimeFormat` with an explicit `timeZone`,
 * so the result does not depend on where the server happens to run — a
 * property the tests pin directly.
 */

import {
  BUDGET_ALLOCATION_DAYS,
  FALLBACK_TIME_ZONE,
  OCCURRED_AT_MAX_FUTURE_MS,
  OCCURRED_AT_MAX_PAST_MS,
} from '../config/economy-p1';

/** A civil (wall-clock) date in some timezone, with no time component. */
export interface CivilDate {
  year: number;
  month: number; // 1-12
  day: number; // 1-31
}

/**
 * Day index within a P1 week: 0 = Monday … 5 = Saturday, 6 = Sunday.
 *
 * Monday-based rather than JavaScript's Sunday-based `getDay()`, because the
 * whole budget model is "six allocations Monday through Saturday, Sunday
 * rests" (PDR-013). Keeping Sunday at index 6 means "is this a rest day" is
 * `index === SUNDAY_INDEX` and "does this day release coins" is
 * `index < BUDGET_ALLOCATION_DAYS` — both readable, neither needing a
 * conversion at the call site.
 */
export const SUNDAY_INDEX = 6;

/**
 * Whether a string is a timezone this runtime can actually resolve.
 *
 * `Intl.DateTimeFormat` throws `RangeError` for an unknown zone, which is the
 * only reliable validity check available — there is no exposed list to match
 * against, and a hardcoded one would rot with every tzdata update.
 */
export function isValidTimeZone(timeZone: string): boolean {
  if (!timeZone) {
    return false;
  }
  try {
    new Intl.DateTimeFormat('en-US', { timeZone });
    return true;
  } catch {
    return false;
  }
}

/**
 * Resolve a stored/claimed timezone to one that is safe to compute with.
 *
 * Returns FALLBACK_TIME_ZONE (UTC) for anything missing or unresolvable.
 * Deliberately does NOT log: this runs on every reward and every budget read,
 * and a per-request warning for one household with a bad zone would be pure
 * noise. Callers that WRITE a zone (the budget writer in B8) should validate
 * with `isValidTimeZone` and complain once, at the point where a human can
 * still fix the input.
 */
export function resolveTimeZone(timeZone?: string | null): string {
  if (timeZone && isValidTimeZone(timeZone)) {
    return timeZone;
  }
  return FALLBACK_TIME_ZONE;
}

/**
 * The civil date an instant falls on, as seen from `timeZone`.
 *
 * Uses `formatToParts` with explicit numeric fields rather than parsing a
 * formatted string: locale formatting varies (and `en-US` would give
 * MM/DD/YYYY), while the parts are named and unambiguous regardless of
 * locale. The `en-US` locale tag is therefore irrelevant to the output — only
 * `timeZone` is.
 */
export function civilDateIn(instant: Date, timeZone: string): CivilDate {
  const zone = resolveTimeZone(timeZone);
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: zone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(instant);

  const read = (type: Intl.DateTimeFormatPartTypes): number => {
    const part = parts.find((p) => p.type === type);
    if (!part) {
      // Unreachable with the options above; a missing part would mean the
      // runtime's Intl is not the one this module was written against, and
      // silently defaulting to 0 would produce a plausible-looking wrong
      // date rather than an obvious failure.
      throw new Error(`Intl.DateTimeFormat returned no "${type}" part for zone ${zone}`);
    }
    return Number(part.value);
  };

  return { year: read('year'), month: read('month'), day: read('day') };
}

/**
 * A civil date as a UTC-midnight `Date`.
 *
 * The returned value is NOT the instant that civil date started in any real
 * timezone — it is a position on the proleptic calendar, used only for
 * day-arithmetic (weekday, week number, day differences) where the offset
 * cancels out. Keeping the arithmetic in UTC is what stops the host
 * timezone's DST rules from leaking into a computation about a different
 * zone entirely.
 */
function civilToUtcAnchor(date: CivilDate): Date {
  return new Date(Date.UTC(date.year, date.month - 1, date.day));
}

/**
 * Day index (0 = Monday … 6 = Sunday) of an instant in `timeZone`.
 */
export function dayIndexIn(instant: Date, timeZone: string): number {
  const anchor = civilToUtcAnchor(civilDateIn(instant, timeZone));
  // getUTCDay: 0 = Sunday … 6 = Saturday. Rotate so Monday is 0.
  return (anchor.getUTCDay() + 6) % 7;
}

/** Whether an instant falls on the weekly rest day in `timeZone` (PDR-013). */
export function isRestDay(instant: Date, timeZone: string): boolean {
  return dayIndexIn(instant, timeZone) === SUNDAY_INDEX;
}

/**
 * The calendar day an instant belongs to, as `YYYY-MM-DD` in `timeZone`.
 *
 * This is the `effectiveDayKey` of TD-066-DESIGN §3/§4 — the key a
 * `StreakDay` is unique on, and the day a completion counts towards. A
 * string, not a Date, precisely because it must NOT be reinterpretable in
 * another zone: once the day is decided it is a label, and comparing two
 * labels can never accidentally reintroduce an offset.
 */
export function effectiveDayKey(instant: Date, timeZone: string): string {
  const { year, month, day } = civilDateIn(instant, timeZone);
  return `${pad4(year)}-${pad2(month)}-${pad2(day)}`;
}

/**
 * The ISO-8601 week an instant belongs to, as `YYYY-Www` in `timeZone`.
 *
 * ISO weeks start on Monday and belong to the year containing their Thursday,
 * which is why the ISO year in the key can differ from the calendar year at
 * the turn of a year (2026-12-31 is `2026-W53`; 2027-01-01 is also `2026-W53`).
 * That is the correct behaviour, not an artefact: a budget week must not be
 * split in two by a new year landing mid-week.
 */
export function weekKey(instant: Date, timeZone: string): string {
  const anchor = civilToUtcAnchor(civilDateIn(instant, timeZone));

  // Move to the Thursday of this ISO week: its calendar year IS the ISO year,
  // by definition of the ISO week-numbering rule.
  const dayIndex = (anchor.getUTCDay() + 6) % 7;
  const thursday = new Date(anchor);
  thursday.setUTCDate(thursday.getUTCDate() - dayIndex + 3);

  const isoYear = thursday.getUTCFullYear();

  // Week 1 is the one containing 4 January; find its Thursday the same way.
  const jan4 = new Date(Date.UTC(isoYear, 0, 4));
  const jan4DayIndex = (jan4.getUTCDay() + 6) % 7;
  const firstThursday = new Date(jan4);
  firstThursday.setUTCDate(firstThursday.getUTCDate() - jan4DayIndex + 3);

  const MS_PER_WEEK = 7 * 24 * 60 * 60 * 1000;
  // Both operands are UTC midnights exactly N weeks apart, so the division is
  // exact; Math.round guards only against a leap-second-style surprise.
  const week = 1 + Math.round((thursday.getTime() - firstThursday.getTime()) / MS_PER_WEEK);

  return `${pad4(isoYear)}-W${pad2(week)}`;
}

/**
 * Coins released on day `dayIndex` of a week whose ceiling is `weeklyCap`.
 *
 * The formula from TD-066-DESIGN §3:
 *
 *   releasedOnDay(d) = floor(cap × (d + 1) / 6) - floor(cap × d / 6)
 *
 * The difference-of-floors is the whole point: it distributes the remainder
 * of `cap / 6` across the six days without ever losing or inventing a coin,
 * so the six values sum to exactly `weeklyCap` for ANY cap — a property the
 * test suite asserts exhaustively rather than by example. Handing out
 * `floor(cap / 6)` six times would quietly burn up to five coins a week.
 *
 * Sunday (index 6) releases nothing (PDR-013).
 */
export function releasedOnDay(weeklyCap: number, dayIndex: number): number {
  assertCap(weeklyCap);
  assertDayIndex(dayIndex);

  if (dayIndex >= BUDGET_ALLOCATION_DAYS) {
    return 0;
  }
  return (
    Math.floor((weeklyCap * (dayIndex + 1)) / BUDGET_ALLOCATION_DAYS) -
    Math.floor((weeklyCap * dayIndex) / BUDGET_ALLOCATION_DAYS)
  );
}

/**
 * Coins released from Monday through `dayIndex` inclusive.
 *
 * Telescopes to `floor(cap × min(d + 1, 6) / 6)`, so by Saturday the whole
 * cap has been released and Sunday adds nothing — the unspent remainder stays
 * available through Sunday and expires only when `weekKey` changes (PDR-013:
 * "La asignación no gastada se acumula dentro de la semana y no caduca").
 */
export function releasedThroughDay(weeklyCap: number, dayIndex: number): number {
  assertCap(weeklyCap);
  assertDayIndex(dayIndex);

  const daysElapsed = Math.min(dayIndex + 1, BUDGET_ALLOCATION_DAYS);
  return Math.floor((weeklyCap * daysElapsed) / BUDGET_ALLOCATION_DAYS);
}

/**
 * Coins a member can still be granted right now.
 *
 * `available = releasedThroughToday - alreadyGranted`, floored at 0 so a
 * budget that was edited downward mid-week (B8's manual adjustment) can never
 * report a negative allowance to a caller that is about to subtract from it.
 *
 * A grant takes `min(want, available)`; XP is unaffected when this reaches
 * zero (TD-066-DESIGN §3).
 */
export function availableCoins(
  weeklyCap: number,
  dayIndex: number,
  grantedCoins: number,
): number {
  if (grantedCoins < 0) {
    throw new RangeError(`grantedCoins must be >= 0, got ${grantedCoins}`);
  }
  return Math.max(0, releasedThroughDay(weeklyCap, dayIndex) - grantedCoins);
}

/**
 * Why a client-supplied `occurredAt` was rejected, or `null` if it is usable.
 *
 * Returns a reason instead of throwing so the caller decides the HTTP shape;
 * TD-066-DESIGN §9 requires the rejection be recorded clearly and the reward
 * withheld, not that the request necessarily fail.
 */
export type OccurredAtRejection = 'too_old' | 'too_far_future' | 'invalid';

/**
 * Validate a client-claimed completion instant against the allowed window.
 *
 * The server never trusts the client's clock for anything that decides money:
 * `weekKey`/`effectiveDayKey` are derived server-side from whatever instant
 * survives this check (TD-066-DESIGN §9, "Hora offline manipulado o demasiado
 * antigua"). This only bounds how far that instant may sit from now.
 */
export function validateOccurredAt(occurredAt: Date, now: Date): OccurredAtRejection | null {
  const claimed = occurredAt.getTime();
  if (!Number.isFinite(claimed)) {
    return 'invalid';
  }

  const delta = claimed - now.getTime();
  if (delta > OCCURRED_AT_MAX_FUTURE_MS) {
    return 'too_far_future';
  }
  if (-delta > OCCURRED_AT_MAX_PAST_MS) {
    return 'too_old';
  }
  return null;
}

function assertCap(weeklyCap: number): void {
  if (!Number.isInteger(weeklyCap) || weeklyCap < 0) {
    throw new RangeError(`weeklyCap must be a non-negative integer, got ${weeklyCap}`);
  }
}

function assertDayIndex(dayIndex: number): void {
  if (!Number.isInteger(dayIndex) || dayIndex < 0 || dayIndex > SUNDAY_INDEX) {
    throw new RangeError(`dayIndex must be an integer in [0, ${SUNDAY_INDEX}], got ${dayIndex}`);
  }
}

function pad2(value: number): string {
  return String(value).padStart(2, '0');
}

function pad4(value: number): string {
  return String(value).padStart(4, '0');
}

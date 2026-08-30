import { COMMON_TRANCHE_FRACTION, WEEKLY_CAP_COINS } from '../config/economy-p1';
import { availableCoins, dayIndexIn } from '../utils/economy-period';

/**
 * What a completion actually pays, for suites written before B8 gave the
 * weekly plan a say.
 *
 * Until B8 every completion paid the flat `DEFAULT_TASK_COINS`. It now pays
 * whatever the member's plan prices the task at, capped by what the day has
 * released — so a hard-coded 5 in an older suite is not a regression, it is an
 * assertion that predates the mechanic. These helpers let those tests state
 * the rule instead of a number, which also keeps them correct on whichever
 * weekday the suite happens to run.
 */

/** The whole common tranche, before it is divided or capped (decision P3). */
export const COMMON_TRANCHE_BUDGET = Math.floor(WEEKLY_CAP_COINS * COMMON_TRANCHE_FRACTION);

/**
 * What ONE completion of an unassigned task is priced at.
 *
 * The tranche is split across every unassigned task the household had PENDING
 * when the week's plan was built — which is the first completion of the week,
 * not the moment of the call. `unassignedTaskCount` is therefore the count at
 * that instant, and stating it explicitly is the point: a test that assumed
 * "one task" while its household had two would pass on the wrong arithmetic.
 */
export function unassignedCoinAmount(unassignedTaskCount = 1): number {
  return Math.floor(COMMON_TRANCHE_BUDGET / Math.max(1, unassignedTaskCount));
}

/**
 * What an unassigned task actually pays on `dayIndex`: its planned price,
 * capped by what the day has released minus what is already granted.
 */
export function unassignedAward(
  dayIndex: number,
  unassignedTaskCount = 1,
  alreadyGranted = 0,
): number {
  return Math.min(
    unassignedCoinAmount(unassignedTaskCount),
    availableCoins(WEEKLY_CAP_COINS, dayIndex, alreadyGranted),
  );
}

/** The same, for a completion the server timestamps itself (no `occurredAt`). */
export function unassignedAwardToday(
  unassignedTaskCount = 1,
  alreadyGranted = 0,
  timeZone = 'UTC',
): number {
  return unassignedAward(dayIndexIn(new Date(), timeZone), unassignedTaskCount, alreadyGranted);
}

/**
 * A recent instant that falls on `dayIndex` and sits safely inside the
 * `occurredAt` window (TD-066-DESIGN §9).
 *
 * These dates used to be hard-coded ISO strings, and they EXPIRED. With
 * `OCCURRED_AT_MAX_PAST_MS` at seven days, `'2026-08-23T10:00:00.000Z'`
 * stopped validating at exactly 2026-08-30T10:00:00Z: one CI run at 09:56
 * passed and the next at 10:04 failed, with no code change in between. The
 * rejection surfaces as `res.body.data` being undefined — a `too_old` 4xx —
 * so it reads like a broken response shape rather than a stale fixture, which
 * is what makes it worth naming here.
 *
 * Anchoring two hours in the past and walking back at most six days puts the
 * result in (2h, 6d2h): never inside the five-minute future tolerance, never
 * at the seven-day edge, whichever day and hour the suite happens to run.
 */
export function recentInstantOnDay(dayIndex: number, timeZone = 'UTC'): string {
  const anchor = Date.now() - 2 * 60 * 60 * 1000;

  for (let daysBack = 0; daysBack < 7; daysBack++) {
    const candidate = new Date(anchor - daysBack * 24 * 60 * 60 * 1000);
    if (dayIndexIn(candidate, timeZone) === dayIndex) {
      return candidate.toISOString();
    }
  }

  // Unreachable: seven consecutive days contain every weekday exactly once.
  throw new Error(`no instant with dayIndex ${dayIndex} in the last week`);
}

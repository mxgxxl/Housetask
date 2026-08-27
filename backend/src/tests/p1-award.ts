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

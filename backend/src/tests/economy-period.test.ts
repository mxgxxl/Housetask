/**
 * B1 of TD-066: the pure arithmetic and calendar layer of the P1 economy,
 * plus the feature gate that keeps all of it dark until a household is
 * migrated.
 *
 * These are unit tests with no database and no HTTP: every function under
 * test takes its instant as a parameter and reads no clock of its own. That
 * is the whole reason B1 exists as a separate commit — this is the layer
 * where an off-by-one becomes coin inflation, and it should be provable
 * without a replica set standing by.
 *
 * The suite still pays for the shared Mongo connection in setup.ts (it is
 * `setupFilesAfterEnv`, so every suite gets it); that is a few hundred
 * milliseconds, not a dependency of anything asserted below.
 */

import {
  BUDGET_ALLOCATION_DAYS,
  FALLBACK_TIME_ZONE,
  HOUSEHOLD_LEVEL_CURVE_FACTOR,
  ICE_PRICE_COINS,
  MAX_ICE_RESERVE,
  OCCURRED_AT_MAX_FUTURE_MS,
  OCCURRED_AT_MAX_PAST_MS,
  PERSONAL_LEVEL_CURVE_FACTOR,
  STREAK_ICE_MILESTONES,
  WEEKLY_CAP_COINS,
  levelForXp,
  xpRequiredForLevel,
} from '../config/economy-p1';
import {
  SUNDAY_INDEX,
  availableCoins,
  civilDateIn,
  dayIndexIn,
  effectiveDayKey,
  isRestDay,
  isValidTimeZone,
  releasedOnDay,
  releasedThroughDay,
  resolveTimeZone,
  validateOccurredAt,
  weekKey,
} from '../utils/economy-period';
import {
  isKillSwitchOn,
  isP1Enabled,
  resetP1EnabledResolver,
  setP1EnabledResolver,
} from '../services/feature-flag.service';

const MADRID = 'Europe/Madrid';

describe('releasedOnDay — the six daily allocations (PDR-013)', () => {
  /**
   * The property TD-066-DESIGN §8 asks for by name: "pruebas de propiedades
   * para la suma de seis liberaciones".
   *
   * Asserted exhaustively over every cap from 0 to 1000 rather than at a
   * handful of examples, because the failure mode this guards against is
   * arithmetic, not behavioural: `floor(cap / 6)` six times loses up to five
   * coins a week, and it does so ONLY for caps that are not multiples of six.
   * A test that happened to pick 200, 300 and 600 would miss half of them.
   */
  it('releases exactly weeklyCap across Monday-Saturday, for every cap in 0..1000', () => {
    for (let cap = 0; cap <= 1000; cap++) {
      let total = 0;
      for (let day = 0; day < BUDGET_ALLOCATION_DAYS; day++) {
        total += releasedOnDay(cap, day);
      }
      expect(total).toBe(cap);
    }
  });

  it('never releases a negative or fractional amount', () => {
    for (const cap of [0, 1, 7, 50, 200, 1000]) {
      for (let day = 0; day <= SUNDAY_INDEX; day++) {
        const released = releasedOnDay(cap, day);
        expect(Number.isInteger(released)).toBe(true);
        expect(released).toBeGreaterThanOrEqual(0);
      }
    }
  });

  it('spreads the remainder instead of dropping it (cap 200 -> 33,33,34,33,33,34)', () => {
    // 200 / 6 is 33 with a remainder of 2, so two of the six days pay 34.
    // The difference-of-floors decides WHICH two: the days where the running
    // total crosses an integer boundary (Wednesday and Saturday). Handing out
    // floor(200/6) = 33 six times would pay 198 and burn 2 coins a week.
    const perDay = [0, 1, 2, 3, 4, 5].map((day) => releasedOnDay(WEEKLY_CAP_COINS, day));
    expect(perDay).toEqual([33, 33, 34, 33, 33, 34]);
    expect(perDay.reduce((a, b) => a + b, 0)).toBe(WEEKLY_CAP_COINS);
  });

  it('handles a cap smaller than the number of days without inventing coins', () => {
    // cap 1 across 6 days: exactly one day pays, the rest pay nothing.
    const perDay = [0, 1, 2, 3, 4, 5].map((day) => releasedOnDay(1, day));
    expect(perDay.filter((coins) => coins === 1)).toHaveLength(1);
    expect(perDay.reduce((a, b) => a + b, 0)).toBe(1);
  });

  it('rejects a malformed cap or day index instead of computing something plausible', () => {
    expect(() => releasedOnDay(-1, 0)).toThrow(RangeError);
    expect(() => releasedOnDay(1.5, 0)).toThrow(RangeError);
    expect(() => releasedOnDay(200, -1)).toThrow(RangeError);
    expect(() => releasedOnDay(200, 7)).toThrow(RangeError);
  });
});

describe('Sunday is a rest day and releases nothing (PDR-013)', () => {
  it('releasedOnDay returns 0 on Sunday for every cap', () => {
    for (const cap of [0, 1, 7, 50, 200, 1000]) {
      expect(releasedOnDay(cap, SUNDAY_INDEX)).toBe(0);
    }
  });

  it('the whole cap is already released by Saturday, so Sunday adds nothing', () => {
    for (const cap of [0, 1, 7, 50, 200, 1000]) {
      expect(releasedThroughDay(cap, 5)).toBe(cap);
      expect(releasedThroughDay(cap, SUNDAY_INDEX)).toBe(cap);
    }
  });

  it('unspent coins stay available on Sunday rather than expiring (PDR-013)', () => {
    // Spent 10 of 200 by Saturday: Sunday still offers the remaining 190.
    expect(availableCoins(WEEKLY_CAP_COINS, 5, 10)).toBe(190);
    expect(availableCoins(WEEKLY_CAP_COINS, SUNDAY_INDEX, 10)).toBe(190);
  });

  it('identifies Sunday as the rest day in the household timezone, not in UTC', () => {
    // 22:30Z on Saturday 2026-03-28 is already 23:30 Saturday in Madrid (CET).
    expect(isRestDay(new Date('2026-03-28T22:30:00Z'), MADRID)).toBe(false);
    // 23:30Z Saturday is 00:30 Sunday in Madrid: rest day locally, still
    // Saturday in UTC.
    expect(isRestDay(new Date('2026-03-28T23:30:00Z'), MADRID)).toBe(true);
    expect(isRestDay(new Date('2026-03-28T23:30:00Z'), 'UTC')).toBe(false);
  });
});

describe('availableCoins', () => {
  it('is what is released so far minus what has been granted', () => {
    // Monday of a 200-coin week releases 33.
    expect(availableCoins(WEEKLY_CAP_COINS, 0, 0)).toBe(33);
    expect(availableCoins(WEEKLY_CAP_COINS, 0, 20)).toBe(13);
    expect(availableCoins(WEEKLY_CAP_COINS, 0, 33)).toBe(0);
  });

  it('floors at zero when a mid-week budget cut leaves granted above released', () => {
    // B8 lets a member re-shape their own week; a downward edit must never
    // report a negative allowance to a caller about to subtract from it.
    expect(availableCoins(WEEKLY_CAP_COINS, 0, 500)).toBe(0);
  });

  it('rejects a negative granted total', () => {
    expect(() => availableCoins(WEEKLY_CAP_COINS, 0, -1)).toThrow(RangeError);
  });
});

describe('timezone resolution and the explicit UTC fallback', () => {
  it('accepts a real IANA zone', () => {
    expect(isValidTimeZone(MADRID)).toBe(true);
    expect(resolveTimeZone(MADRID)).toBe(MADRID);
  });

  it('falls back to UTC for a missing, empty or unresolvable zone', () => {
    expect(isValidTimeZone('Not/AZone')).toBe(false);
    expect(resolveTimeZone('Not/AZone')).toBe(FALLBACK_TIME_ZONE);
    expect(resolveTimeZone(undefined)).toBe(FALLBACK_TIME_ZONE);
    expect(resolveTimeZone(null)).toBe(FALLBACK_TIME_ZONE);
    expect(resolveTimeZone('')).toBe(FALLBACK_TIME_ZONE);
  });

  it('never throws on a bad zone — it degrades, so one bad row cannot 500 a reward', () => {
    const instant = new Date('2026-01-05T12:00:00Z');
    expect(() => weekKey(instant, 'Not/AZone')).not.toThrow();
    expect(weekKey(instant, 'Not/AZone')).toBe(weekKey(instant, 'UTC'));
    expect(effectiveDayKey(instant, 'Not/AZone')).toBe(effectiveDayKey(instant, 'UTC'));
    expect(dayIndexIn(instant, 'Not/AZone')).toBe(dayIndexIn(instant, 'UTC'));
  });

  it('does not consult the host process timezone', () => {
    // Pinning the contract rather than mutating process.env.TZ (which Node
    // only re-reads reliably at startup): an instant's civil date in an
    // explicit zone is a property of that zone alone.
    const instant = new Date('2026-07-15T23:30:00Z');
    expect(civilDateIn(instant, 'UTC')).toEqual({ year: 2026, month: 7, day: 15 });
    // Madrid is UTC+2 in July, so the same instant is already the 16th there.
    expect(civilDateIn(instant, MADRID)).toEqual({ year: 2026, month: 7, day: 16 });
    // And UTC-5 puts it back on the 15th, hours earlier.
    expect(civilDateIn(instant, 'America/New_York')).toEqual({ year: 2026, month: 7, day: 15 });
  });
});

describe('weekKey and effectiveDayKey across a Europe/Madrid DST boundary', () => {
  /**
   * The scenario the module was written for: a task completed just after
   * local midnight on Monday. Grouped in UTC it lands on Sunday — the one day
   * of the week that releases no coins — so the member silently goes unpaid.
   */
  it('a completion at 00:30 Monday in Madrid belongs to Monday, not to UTC Sunday', () => {
    // Winter (CET, UTC+1): local midnight is 23:00Z the previous day.
    const justAfterMidnight = new Date('2026-01-04T23:30:00Z');

    expect(effectiveDayKey(justAfterMidnight, MADRID)).toBe('2026-01-05');
    expect(dayIndexIn(justAfterMidnight, MADRID)).toBe(0); // Monday
    expect(isRestDay(justAfterMidnight, MADRID)).toBe(false);

    // The same instant read in UTC is still Sunday the 4th — the rest day.
    expect(effectiveDayKey(justAfterMidnight, 'UTC')).toBe('2026-01-04');
    expect(dayIndexIn(justAfterMidnight, 'UTC')).toBe(SUNDAY_INDEX);
    expect(isRestDay(justAfterMidnight, 'UTC')).toBe(true);

    // And it is a different budget week in each: W02 locally, W01 in UTC.
    expect(weekKey(justAfterMidnight, MADRID)).toBe('2026-W02');
    expect(weekKey(justAfterMidnight, 'UTC')).toBe('2026-W01');
  });

  it('tracks the boundary moving by an hour between CET and CEST', () => {
    // The assertion that a fixed +1 offset would fail. Local Monday 00:30 is
    // 23:30Z in winter but 22:30Z in summer, because Madrid is UTC+2 then.
    const winterMondayLocal = new Date('2026-01-04T23:30:00Z');
    const summerMondayLocal = new Date('2026-06-28T22:30:00Z');

    expect(dayIndexIn(winterMondayLocal, MADRID)).toBe(0);
    expect(dayIndexIn(summerMondayLocal, MADRID)).toBe(0);

    // An hour earlier in summer is still Sunday: the boundary really did move.
    expect(dayIndexIn(new Date('2026-06-28T21:30:00Z'), MADRID)).toBe(SUNDAY_INDEX);
    // Whereas the same 21:30Z in winter is nowhere near midnight.
    expect(dayIndexIn(new Date('2026-01-04T21:30:00Z'), MADRID)).toBe(SUNDAY_INDEX);
  });

  it('collapses the 23-hour spring-forward Sunday into one day key', () => {
    // 2026-03-29 is the last Sunday of March: 02:00 CET jumps to 03:00 CEST.
    const beforeJump = new Date('2026-03-29T00:30:00Z'); // 01:30 CET
    const afterJump = new Date('2026-03-29T01:30:00Z'); // 03:30 CEST

    expect(effectiveDayKey(beforeJump, MADRID)).toBe('2026-03-29');
    expect(effectiveDayKey(afterJump, MADRID)).toBe('2026-03-29');
    expect(isRestDay(beforeJump, MADRID)).toBe(true);
    expect(isRestDay(afterJump, MADRID)).toBe(true);
    expect(weekKey(beforeJump, MADRID)).toBe(weekKey(afterJump, MADRID));

    // The Monday that follows starts at 22:00Z, not 23:00Z, because DST is
    // now in effect.
    expect(effectiveDayKey(new Date('2026-03-29T22:30:00Z'), MADRID)).toBe('2026-03-30');
    expect(dayIndexIn(new Date('2026-03-29T22:30:00Z'), MADRID)).toBe(0);
  });

  it('collapses the 25-hour fall-back Sunday into one day key', () => {
    // 2026-10-25 is the last Sunday of October: 03:00 CEST falls to 02:00 CET.
    // The local hour 02:00-03:00 happens twice; both occurrences are the 25th.
    const firstPass = new Date('2026-10-25T00:30:00Z'); // 02:30 CEST
    const secondPass = new Date('2026-10-25T01:30:00Z'); // 02:30 CET

    expect(effectiveDayKey(firstPass, MADRID)).toBe('2026-10-25');
    expect(effectiveDayKey(secondPass, MADRID)).toBe('2026-10-25');
    expect(isRestDay(firstPass, MADRID)).toBe(true);
    expect(isRestDay(secondPass, MADRID)).toBe(true);

    // Sunday started at 22:00Z Saturday (still CEST) and ends at 23:00Z (CET).
    expect(effectiveDayKey(new Date('2026-10-24T22:30:00Z'), MADRID)).toBe('2026-10-25');
    expect(effectiveDayKey(new Date('2026-10-25T23:30:00Z'), MADRID)).toBe('2026-10-26');
  });
});

describe('weekKey — ISO-8601 week numbering', () => {
  it('starts weeks on Monday', () => {
    // 2026-01-04 is a Sunday, the last day of 2026-W01.
    expect(weekKey(new Date('2026-01-04T12:00:00Z'), 'UTC')).toBe('2026-W01');
    // 2026-01-05 is the Monday that opens W02.
    expect(weekKey(new Date('2026-01-05T12:00:00Z'), 'UTC')).toBe('2026-W02');
  });

  it('keeps a week whole across a calendar-year boundary', () => {
    // The ISO year is the one containing the week's Thursday, so a week is
    // never split in two by New Year — a budget week must not be either.
    expect(weekKey(new Date('2026-12-31T12:00:00Z'), 'UTC')).toBe('2026-W53');
    expect(weekKey(new Date('2027-01-01T12:00:00Z'), 'UTC')).toBe('2026-W53');
    expect(weekKey(new Date('2027-01-03T12:00:00Z'), 'UTC')).toBe('2026-W53');
    // 2027-01-04 is the Monday that finally opens 2027-W01.
    expect(weekKey(new Date('2027-01-04T12:00:00Z'), 'UTC')).toBe('2027-W01');
  });

  it('zero-pads the week number so keys sort lexicographically', () => {
    expect(weekKey(new Date('2026-01-05T12:00:00Z'), 'UTC')).toBe('2026-W02');
    const keys = [
      weekKey(new Date('2026-11-02T12:00:00Z'), 'UTC'),
      weekKey(new Date('2026-01-05T12:00:00Z'), 'UTC'),
    ];
    expect([...keys].sort()).toEqual(['2026-W02', '2026-W45']);
  });

  it('assigns every day of one week the same key', () => {
    const keys = new Set<string>();
    for (let day = 5; day <= 11; day++) {
      keys.add(weekKey(new Date(`2026-01-${String(day).padStart(2, '0')}T12:00:00Z`), 'UTC'));
    }
    expect([...keys]).toEqual(['2026-W02']);
  });
});

describe('effectiveDayKey', () => {
  it('formats as YYYY-MM-DD with zero padding', () => {
    expect(effectiveDayKey(new Date('2026-01-05T12:00:00Z'), 'UTC')).toBe('2026-01-05');
    expect(effectiveDayKey(new Date('2026-11-30T12:00:00Z'), 'UTC')).toBe('2026-11-30');
  });
});

describe('validateOccurredAt — the offline window (TD-066-DESIGN §9)', () => {
  const now = new Date('2026-08-26T12:00:00Z');

  it('accepts a recent past instant, which is the normal offline case', () => {
    expect(validateOccurredAt(new Date('2026-08-26T08:00:00Z'), now)).toBeNull();
    expect(validateOccurredAt(new Date('2026-08-23T12:00:00Z'), now)).toBeNull();
  });

  it('accepts small clock skew into the future', () => {
    const skewed = new Date(now.getTime() + OCCURRED_AT_MAX_FUTURE_MS - 1_000);
    expect(validateOccurredAt(skewed, now)).toBeNull();
  });

  it('rejects an instant beyond the future tolerance', () => {
    const tooFar = new Date(now.getTime() + OCCURRED_AT_MAX_FUTURE_MS + 1_000);
    expect(validateOccurredAt(tooFar, now)).toBe('too_far_future');
  });

  it('rejects an instant older than the window', () => {
    const tooOld = new Date(now.getTime() - OCCURRED_AT_MAX_PAST_MS - 1_000);
    expect(validateOccurredAt(tooOld, now)).toBe('too_old');
  });

  it('accepts the exact window boundaries rather than rejecting them', () => {
    expect(validateOccurredAt(new Date(now.getTime() - OCCURRED_AT_MAX_PAST_MS), now)).toBeNull();
    expect(validateOccurredAt(new Date(now.getTime() + OCCURRED_AT_MAX_FUTURE_MS), now)).toBeNull();
  });

  it('rejects an unparseable date', () => {
    expect(validateOccurredAt(new Date('nonsense'), now)).toBe('invalid');
  });
});

describe('level curves', () => {
  it('costs nothing to be at level 1', () => {
    expect(xpRequiredForLevel(1, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(0);
    expect(xpRequiredForLevel(1, HOUSEHOLD_LEVEL_CURVE_FACTOR)).toBe(0);
  });

  it('follows the documented personal thresholds', () => {
    expect(xpRequiredForLevel(2, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(100);
    expect(xpRequiredForLevel(3, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(300);
    expect(xpRequiredForLevel(5, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(1000);
    expect(xpRequiredForLevel(10, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(4500);
  });

  it('makes the household curve twice as steep as the personal one', () => {
    expect(xpRequiredForLevel(2, HOUSEHOLD_LEVEL_CURVE_FACTOR)).toBe(200);
    expect(xpRequiredForLevel(5, HOUSEHOLD_LEVEL_CURVE_FACTOR)).toBe(2000);
  });

  it('grows the step between levels linearly', () => {
    const steps = [2, 3, 4, 5, 6].map(
      (level) =>
        xpRequiredForLevel(level, PERSONAL_LEVEL_CURVE_FACTOR) -
        xpRequiredForLevel(level - 1, PERSONAL_LEVEL_CURVE_FACTOR),
    );
    expect(steps).toEqual([100, 200, 300, 400, 500]);
  });

  it('inverts exactly at a threshold, which is the common case', () => {
    // Every grant is a round number, so landing precisely on a boundary is
    // routine — it is exactly where a naive floor of the quadratic lands on
    // the wrong side.
    expect(levelForXp(99, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(1);
    expect(levelForXp(100, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(2);
    expect(levelForXp(101, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(2);
    expect(levelForXp(299, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(2);
    expect(levelForXp(300, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(3);
  });

  it('round-trips against xpRequiredForLevel for the first 200 levels', () => {
    for (const factor of [PERSONAL_LEVEL_CURVE_FACTOR, HOUSEHOLD_LEVEL_CURVE_FACTOR]) {
      for (let level = 1; level <= 200; level++) {
        const threshold = xpRequiredForLevel(level, factor);
        expect(levelForXp(threshold, factor)).toBe(level);
        if (level > 1) {
          expect(levelForXp(threshold - 1, factor)).toBe(level - 1);
        }
      }
    }
  });

  it('starts everyone at level 1 with zero XP', () => {
    expect(levelForXp(0, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(1);
    expect(levelForXp(0, HOUSEHOLD_LEVEL_CURVE_FACTOR)).toBe(1);
  });

  it('rejects nonsense input rather than returning a plausible level', () => {
    expect(() => xpRequiredForLevel(0, PERSONAL_LEVEL_CURVE_FACTOR)).toThrow(RangeError);
    expect(() => xpRequiredForLevel(1.5, PERSONAL_LEVEL_CURVE_FACTOR)).toThrow(RangeError);
    expect(() => levelForXp(-1, PERSONAL_LEVEL_CURVE_FACTOR)).toThrow(RangeError);
    expect(() => levelForXp(100, 0)).toThrow(RangeError);
  });
});

describe('product-fixed constants (PDR-019, UX-P1-SPEC)', () => {
  it('pins the ice rules so a refactor cannot quietly retune them', () => {
    expect(STREAK_ICE_MILESTONES).toEqual([7, 14, 30, 50, 100]);
    expect(ICE_PRICE_COINS).toBe(20);
    expect(MAX_ICE_RESERVE).toBe(2);
  });

  it('pins the weekly cap to the number in the UX copy', () => {
    // UX-P1-SPEC.md §4: «Cada semana tienes 200 🪙». Changing this constant
    // means changing that copy too.
    expect(WEEKLY_CAP_COINS).toBe(200);
    expect(BUDGET_ALLOCATION_DAYS).toBe(6);
  });
});

describe('P1 feature flag (TD-066-DESIGN §6)', () => {
  const originalKillSwitch = process.env.P1_ECONOMY_KILL_SWITCH;

  afterEach(() => {
    resetP1EnabledResolver();
    if (originalKillSwitch === undefined) {
      delete process.env.P1_ECONOMY_KILL_SWITCH;
    } else {
      process.env.P1_ECONOMY_KILL_SWITCH = originalKillSwitch;
    }
  });

  it('is OFF by default — the shipped state of every commit until activation', () => {
    return expect(isP1Enabled('household-1')).resolves.toBe(false);
  });

  it('is OFF for a missing household id', async () => {
    setP1EnabledResolver(async () => true);
    await expect(isP1Enabled('')).resolves.toBe(false);
  });

  it('reports what a registered resolver says', async () => {
    setP1EnabledResolver(async (householdId) => householdId === 'migrated');
    await expect(isP1Enabled('migrated')).resolves.toBe(true);
    await expect(isP1Enabled('not-migrated')).resolves.toBe(false);
  });

  it('fails CLOSED when the resolver throws', async () => {
    // Falling back to Fase A is always recoverable; writing personal ledgers
    // for a household whose legacy balance was never snapshotted is not.
    setP1EnabledResolver(() => Promise.reject(new Error('mongo down')));
    await expect(isP1Enabled('migrated')).resolves.toBe(false);
  });

  it('lets the kill switch override an enabled resolver', async () => {
    setP1EnabledResolver(async () => true);
    process.env.P1_ECONOMY_KILL_SWITCH = 'true';
    expect(isKillSwitchOn()).toBe(true);
    await expect(isP1Enabled('migrated')).resolves.toBe(false);
  });

  it('arms the kill switch only on the exact string "true"', async () => {
    setP1EnabledResolver(async () => true);

    for (const value of ['1', 'yes', 'false', 'TRUE', '']) {
      process.env.P1_ECONOMY_KILL_SWITCH = value;
      expect(isKillSwitchOn()).toBe(false);
      await expect(isP1Enabled('migrated')).resolves.toBe(true);
    }
  });

  it('reads the kill switch per call, so it can stop a running incident', async () => {
    setP1EnabledResolver(async () => true);
    await expect(isP1Enabled('migrated')).resolves.toBe(true);

    process.env.P1_ECONOMY_KILL_SWITCH = 'true';
    await expect(isP1Enabled('migrated')).resolves.toBe(false);

    delete process.env.P1_ECONOMY_KILL_SWITCH;
    await expect(isP1Enabled('migrated')).resolves.toBe(true);
  });
});

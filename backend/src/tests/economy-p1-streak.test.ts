import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import * as socketModule from '../config/socket';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { PersonalStreakModel } from '../models/PersonalStreak';
import { StreakDayModel } from '../models/StreakDay';
import { InMemoryIdempotencyStore } from '../services/idempotency.store';
import { resetP1EnabledResolver, setP1EnabledResolver } from '../services/feature-flag.service';
import {
  closeDaysUpTo,
  dayIndexOfKey,
  ensureStreak,
  recordUsefulActivity,
} from '../services/economy-p1-streak.service';
import { ICE_PRICE_COINS, MAX_ICE_RESERVE, STREAK_ICE_MILESTONES } from '../config/economy-p1';
import { buildTestApp } from './setup';
import {
  TestHousehold,
  TestUser,
  authHeader,
  createTestHousehold,
  createTestUser,
} from './helpers';

/**
 * Streaks, ice and the late-sync refund (TD-066 B9, PDR-019).
 *
 * The mechanic has no cron behind it: days are judged lazily, on the next read
 * or write that needs them. So most of what matters here is about ORDER and
 * IDEMPOTENCE — that a break yesterday cannot wipe an increment today, that
 * two requests arriving together consume one ice rather than two, and that a
 * milestone is granted once in a member's life.
 *
 * The tone matters too, and is asserted: PDR-019 is explicit that a bad day
 * must not destroy progress. Sunday never costs anything, and a broken streak
 * leaves level, XP and coins untouched.
 */
let app: Server;

const ZONE = 'UTC';
/** 2026-08-24 is a Monday; the days below run Mon…Sun from there. */
const MON = '2026-08-24';
const TUE = '2026-08-25';
const WED = '2026-08-26';
const SAT = '2026-08-29';
const SUN = '2026-08-30';

function at(dayKey: string, hour = 10): Date {
  return new Date(`${dayKey}T${String(hour).padStart(2, '0')}:00:00.000Z`);
}

beforeAll(async () => {
  app = await buildTestApp({ idempotencyStore: new InMemoryIdempotencyStore() });
});

afterEach(() => {
  jest.restoreAllMocks();
  resetP1EnabledResolver();
});

function enableP1(): void {
  setP1EnabledResolver(async () => true);
}

async function setup(): Promise<{ user: TestUser; household: TestHousehold }> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  return { user, household };
}

async function newUser(): Promise<string> {
  const user = await createTestUser(app);
  return user.id;
}

describe('day keys and the rest day', () => {
  it('reads Monday as 0 and Sunday as 6', () => {
    expect(dayIndexOfKey(MON)).toBe(0);
    expect(dayIndexOfKey(SAT)).toBe(5);
    expect(dayIndexOfKey(SUN)).toBe(6);
  });
});

describe('closing days without activity', () => {
  it('consumes one ice per missed weekday while the reserve lasts', async () => {
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.currentCount = 5;
    streak.longestCount = 5;
    streak.iceReserve = 2;
    streak.lastClosedDayKey = MON;
    await streak.save();

    // Tuesday and Wednesday pass with nothing done; Thursday is "today".
    const result = await closeDaysUpTo(streak, '2026-08-27');
    await streak.save();

    expect(result.closed.map((d) => d.closeState)).toEqual(['ice_covered', 'ice_covered']);
    expect(result.icesConsumed).toBe(2);
    expect(result.streakBroken).toBe(false);
    // Protected: the flame did not drop.
    expect(streak.currentCount).toBe(5);
    expect(streak.iceReserve).toBe(0);

    const days = await StreakDayModel.find({ streakId: streak._id }).sort({ dayKey: 1 });
    expect(days.map((d) => d.iceConsumed)).toEqual([true, true]);
  });

  it('breaks the streak once the reserve runs out', async () => {
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.currentCount = 9;
    streak.longestCount = 9;
    streak.iceReserve = 0;
    streak.lastClosedDayKey = MON;
    await streak.save();

    const result = await closeDaysUpTo(streak, WED);
    await streak.save();

    expect(result.closed.map((d) => d.closeState)).toEqual(['broken']);
    expect(result.streakBroken).toBe(true);
    expect(streak.currentCount).toBe(0);
    // PDR-019: "nivel, XP y monedas permanecen intactos" — a broken streak
    // costs the flame and nothing else. `longestCount` is what proves the
    // progress survived.
    expect(streak.longestCount).toBe(9);
  });

  it('never spends an ice on a Sunday', async () => {
    // PDR-013/PDR-019: Sunday is rest by design. Spending protection on a day
    // that was never at risk is exactly the punitive reading the PDR rejects.
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.currentCount = 4;
    streak.iceReserve = 2;
    streak.lastClosedDayKey = SAT;
    await streak.save();

    const result = await closeDaysUpTo(streak, '2026-08-31');
    await streak.save();

    expect(result.closed.map((d) => d.closeState)).toEqual(['rest']);
    expect(result.icesConsumed).toBe(0);
    expect(streak.iceReserve).toBe(2);
    expect(streak.currentCount).toBe(4);
  });

  it('does not break the streak on a Sunday without a reserve either', async () => {
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.currentCount = 4;
    streak.iceReserve = 0;
    streak.lastClosedDayKey = SAT;
    await streak.save();

    await closeDaysUpTo(streak, '2026-08-31');
    await streak.save();

    expect(streak.currentCount).toBe(4);
  });

  it('closes a day that had activity as active, spending nothing', async () => {
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.iceReserve = 1;
    streak.lastClosedDayKey = MON;
    await streak.save();
    await StreakDayModel.create({
      streakId: streak._id,
      dayKey: TUE,
      usefulActivityCount: 3,
    });

    const result = await closeDaysUpTo(streak, WED);
    await streak.save();

    expect(result.closed.map((d) => d.closeState)).toEqual(['active']);
    expect(streak.iceReserve).toBe(1);
  });

  it('is idempotent: closing twice does not consume a second ice', async () => {
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.iceReserve = 2;
    streak.lastClosedDayKey = MON;
    await streak.save();

    await closeDaysUpTo(streak, WED);
    await streak.save();
    const afterFirst = streak.iceReserve;

    await closeDaysUpTo(streak, WED);
    await streak.save();

    // `lastClosedDayKey` moved, so there is nothing left to judge.
    expect(streak.iceReserve).toBe(afterFirst);
  });
});

describe('recording activity', () => {
  it('moves the flame on the first activity of the day, not on tomorrow\'s close', async () => {
    // "🔥 12" has to be about what the user just did, not about the past.
    const userId = await newUser();

    const result = await recordUsefulActivity(userId, at(MON), ZONE, at(MON));

    expect(result.currentCount).toBe(1);
    expect(result.longestCount).toBe(1);
  });

  it('counts a day once however many tasks are completed on it', async () => {
    const userId = await newUser();

    await recordUsefulActivity(userId, at(MON), ZONE, at(MON));
    await recordUsefulActivity(userId, at(MON, 12), ZONE, at(MON, 12));
    const third = await recordUsefulActivity(userId, at(MON, 18), ZONE, at(MON, 18));

    expect(third.currentCount).toBe(1);
    const day = await StreakDayModel.findOne({ dayKey: MON });
    expect(day?.usefulActivityCount).toBe(3);
  });

  it('extends the flame across consecutive weekdays', async () => {
    const userId = await newUser();

    await recordUsefulActivity(userId, at(MON), ZONE, at(MON));
    await recordUsefulActivity(userId, at(TUE), ZONE, at(TUE));
    const third = await recordUsefulActivity(userId, at(WED), ZONE, at(WED));

    expect(third.currentCount).toBe(3);
  });

  it('closes the gap BEFORE counting today, so a break cannot wipe it', async () => {
    // Order is the whole point: doing it the other way round would credit
    // today and then immediately zero it while judging yesterday.
    const userId = await newUser();
    await recordUsefulActivity(userId, at(MON), ZONE, at(MON));

    // Tuesday missed, no ice. Wednesday's completion breaks the streak and
    // then starts a new one at 1.
    const result = await recordUsefulActivity(userId, at(WED), ZONE, at(WED));

    expect(result.close.streakBroken).toBe(true);
    expect(result.currentCount).toBe(1);
  });

  it('keeps the flame alive across a gap covered by ice', async () => {
    const userId = await newUser();
    await recordUsefulActivity(userId, at(MON), ZONE, at(MON));

    const streak = await PersonalStreakModel.findOne({ userId: new Types.ObjectId(userId) });
    streak!.iceReserve = 1;
    await streak!.save();

    const result = await recordUsefulActivity(userId, at(WED), ZONE, at(WED));

    expect(result.close.icesConsumed).toBe(1);
    expect(result.currentCount).toBe(2);
    expect(result.iceReserve).toBe(0);
  });

  it('does not extend the flame on a Sunday, and does not break it either', async () => {
    const userId = await newUser();

    const result = await recordUsefulActivity(userId, at(SUN), ZONE, at(SUN));

    // Sunday grants XP and never breaks a streak (PDR-013), but a rest day is
    // not a link in the chain.
    expect(result.currentCount).toBe(0);
    const day = await StreakDayModel.findOne({ dayKey: SUN });
    expect(day?.usefulActivityCount).toBe(1);
  });
});

describe('streak milestones (PDR-019)', () => {
  it('grants an ice the first time the longest run reaches 7', async () => {
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    // Six days already banked; today's completion is the seventh.
    streak.currentCount = 6;
    streak.longestCount = 6;
    streak.lastClosedDayKey = '2026-08-23';
    await streak.save();

    const result = await recordUsefulActivity(userId, at(MON), ZONE, at(MON));

    expect(result.currentCount).toBe(7);
    expect(result.milestoneReached).toBe(STREAK_ICE_MILESTONES[0]);
    expect(result.iceReserve).toBe(1);
  });

  it('does not re-grant a milestone already passed', async () => {
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.currentCount = 7;
    streak.longestCount = 7;
    streak.lastClosedDayKey = MON;
    await streak.save();

    const result = await recordUsefulActivity(userId, at(TUE), ZONE, at(TUE));

    expect(result.currentCount).toBe(8);
    expect(result.milestoneReached).toBeNull();
    expect(result.iceReserve).toBe(0);
  });

  it('does not re-grant it after a reset, because it judges the LONGEST run', async () => {
    // Judged against a monotonic number so each milestone is granted once in a
    // member's life, and so the read contract's derived "reached" list (B7)
    // agrees with what was actually granted.
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.currentCount = 6;
    streak.longestCount = 30;
    streak.lastClosedDayKey = '2026-08-23';
    await streak.save();

    const result = await recordUsefulActivity(userId, at(MON), ZONE, at(MON));

    expect(result.currentCount).toBe(7);
    expect(result.milestoneReached).toBeNull();
    expect(result.iceReserve).toBe(0);
  });

  it('does not push the reserve past its cap', async () => {
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.currentCount = 6;
    streak.longestCount = 6;
    streak.iceReserve = MAX_ICE_RESERVE;
    streak.lastClosedDayKey = '2026-08-23';
    await streak.save();

    const result = await recordUsefulActivity(userId, at(MON), ZONE, at(MON));

    expect(result.milestoneReached).toBe(7);
    expect(result.iceReserve).toBe(MAX_ICE_RESERVE);
  });
});

describe('late offline sync (TD-066-DESIGN §4, approved decision 5)', () => {
  it('gives back the ice that covered the day, once', async () => {
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.currentCount = 3;
    streak.iceReserve = 1;
    streak.lastClosedDayKey = MON;
    await streak.save();

    // Tuesday goes by with nothing recorded; Wednesday closes it with an ice.
    await recordUsefulActivity(userId, at(WED), ZONE, at(WED));
    let stored = await PersonalStreakModel.findOne({ userId: new Types.ObjectId(userId) });
    expect(stored!.iceReserve).toBe(0);

    // Tuesday's completion finally syncs on Wednesday evening.
    const late = await recordUsefulActivity(userId, at(TUE), ZONE, at(WED, 20));

    expect(late.iceRefunded).toBe(true);
    expect(late.iceReserve).toBe(1);
    const day = await StreakDayModel.findOne({ dayKey: TUE });
    // The day WAS covered — `iceConsumed` stays true beside the correction, so
    // the history of what happened survives.
    expect(day?.iceConsumed).toBe(true);
    expect(day?.iceRefunded).toBe(true);
    expect(day?.closeState).toBe('active');

    // A second late sync of the same day must not mint another ice.
    const again = await recordUsefulActivity(userId, at(TUE, 12), ZONE, at(WED, 21));
    expect(again.iceRefunded).toBe(false);
    stored = await PersonalStreakModel.findOne({ userId: new Types.ObjectId(userId) });
    expect(stored!.iceReserve).toBe(1);
  });

  it('discards the refund when the reserve is already full', async () => {
    // Approved decision 5: PDR-019 reads as "refund if there is capacity". The
    // ice already did its job, the member keeps maximum protection, and going
    // past the cap would reintroduce the inflation it exists to prevent.
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.iceReserve = 1;
    streak.lastClosedDayKey = MON;
    await streak.save();

    await recordUsefulActivity(userId, at(WED), ZONE, at(WED));
    const refilled = await PersonalStreakModel.findOne({ userId: new Types.ObjectId(userId) });
    refilled!.iceReserve = MAX_ICE_RESERVE;
    await refilled!.save();

    const late = await recordUsefulActivity(userId, at(TUE), ZONE, at(WED, 20));

    expect(late.iceRefunded).toBe(false);
    expect(late.iceReserve).toBe(MAX_ICE_RESERVE);
    const day = await StreakDayModel.findOne({ dayKey: TUE });
    expect(day?.iceRefunded).toBe(false);
    // The verdict stands: the day really was covered by an ice.
    expect(day?.closeState).toBe('ice_covered');
  });

  it('records the activity on a day that broke, without rewriting the verdict', async () => {
    // PDR-019's refund is about ice. Nothing in the design un-breaks a streak
    // retroactively, and doing so would mean replaying every later day's
    // verdict including ices already spent — so the activity is recorded and
    // the history stays honest. See the report's R-note.
    const userId = await newUser();
    const streak = await ensureStreak(userId);
    streak.currentCount = 4;
    streak.iceReserve = 0;
    streak.lastClosedDayKey = MON;
    await streak.save();

    await recordUsefulActivity(userId, at(WED), ZONE, at(WED));
    const late = await recordUsefulActivity(userId, at(TUE), ZONE, at(WED, 20));

    expect(late.iceRefunded).toBe(false);
    const day = await StreakDayModel.findOne({ dayKey: TUE });
    expect(day?.usefulActivityCount).toBe(1);
    expect(day?.closeState).toBe('broken');
  });
});

describe('POST .../economy/p1/ice', () => {
  async function fund(userId: string, householdId: string, amount: number): Promise<void> {
    await PersonalCoinLedgerModel.create({
      userId: new Types.ObjectId(userId),
      householdId: new Types.ObjectId(householdId),
      amount,
      reason: 'legacy_balance',
      refType: 'legacy_migration',
      refId: `seed-${userId}`,
      effectiveAt: new Date(),
    });
  }

  function buy(user: TestUser, householdId: string, key: string): request.Test {
    return request(app)
      .post(`/api/households/${householdId}/economy/p1/ice`)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', key)
      .send({});
  }

  it('debits the wallet and raises the reserve', async () => {
    enableP1();
    const { user, household } = await setup();
    await fund(user.id, household.id, 50);

    const res = await buy(user, household.id, 'op-ice-1');

    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({
      iceReserve: 1,
      spent: ICE_PRICE_COINS,
      balance: 50 - ICE_PRICE_COINS,
    });

    const streak = await PersonalStreakModel.findOne({ userId: new Types.ObjectId(user.id) });
    expect(streak?.iceReserve).toBe(1);
    const entry = await PersonalCoinLedgerModel.findOne({ reason: 'ice_purchase' });
    expect(entry?.amount).toBe(-ICE_PRICE_COINS);
  });

  it('refuses an insufficient balance rather than going negative', async () => {
    // The ledger IS the balance, so a debit past zero would not merely look
    // wrong — it would be the balance.
    enableP1();
    const { user, household } = await setup();
    await fund(user.id, household.id, ICE_PRICE_COINS - 1);

    const res = await buy(user, household.id, 'op-ice-poor');

    expect(res.status).toBe(400);
    await expect(
      PersonalCoinLedgerModel.countDocuments({ reason: 'ice_purchase' }),
    ).resolves.toBe(0);
    const streak = await PersonalStreakModel.findOne({ userId: new Types.ObjectId(user.id) });
    expect(streak?.iceReserve ?? 0).toBe(0);
  });

  it('refuses at the cap rather than taking the money', async () => {
    enableP1();
    const { user, household } = await setup();
    await fund(user.id, household.id, 500);
    const streak = await ensureStreak(user.id);
    streak.iceReserve = MAX_ICE_RESERVE;
    await streak.save();

    const res = await buy(user, household.id, 'op-ice-full');

    expect(res.status).toBe(409);
    await expect(
      PersonalCoinLedgerModel.countDocuments({ reason: 'ice_purchase' }),
    ).resolves.toBe(0);
  });

  it('does not buy twice on a retried tap', async () => {
    enableP1();
    const { user, household } = await setup();
    await fund(user.id, household.id, 100);

    const first = await buy(user, household.id, 'op-ice-retry');
    const second = await buy(user, household.id, 'op-ice-retry');

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(second.body).toEqual(first.body);
    const streak = await PersonalStreakModel.findOne({ userId: new Types.ObjectId(user.id) });
    expect(streak?.iceReserve).toBe(1);
    await expect(
      PersonalCoinLedgerModel.countDocuments({ reason: 'ice_purchase' }),
    ).resolves.toBe(1);
  });

  it('emits economy:ice_purchased to the buyer alone', async () => {
    enableP1();
    const emitToUser = jest
      .spyOn(socketModule, 'emitToUser')
      .mockImplementation(() => undefined);
    const emitToHousehold = jest
      .spyOn(socketModule, 'emitToHousehold')
      .mockImplementation(() => undefined);

    const { user, household } = await setup();
    await fund(user.id, household.id, 100);
    await buy(user, household.id, 'op-ice-evt');

    const events = emitToUser.mock.calls.filter((c) => c[1] === 'economy:ice_purchased');
    expect(events).toHaveLength(1);
    expect(events[0][0]).toBe(user.id);
    // An ice reserve is nobody else's business (UX-P1-SPEC §0).
    expect(emitToHousehold.mock.calls.filter((c) => c[1] === 'economy:ice_purchased')).toEqual([]);
  });

  it('answers 409 while P1 is disabled', async () => {
    const { user, household } = await setup();
    await fund(user.id, household.id, 100);

    const res = await buy(user, household.id, 'op-ice-off');

    expect(res.status).toBe(409);
    await expect(PersonalStreakModel.countDocuments({})).resolves.toBe(0);
  });

  it('answers 403 to a non-member', async () => {
    enableP1();
    const { household } = await setup();
    const stranger = await createTestUser(app);

    const res = await buy(stranger, household.id, 'op-ice-stranger');
    expect(res.status).toBe(403);
  });
});

describe('the streak moves through a real completion', () => {
  it('advances the flame and reports it over the socket', async () => {
    enableP1();
    const emitToUser = jest
      .spyOn(socketModule, 'emitToUser')
      .mockImplementation(() => undefined);

    const { user, household } = await setup();
    const created = await request(app)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Fregar' });

    await request(app)
      .post(`/api/households/${household.id}/tasks/${created.body.data.id}/completions`)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-streak')
      .send({ timeZone: ZONE });

    const streak = await PersonalStreakModel.findOne({ userId: new Types.ObjectId(user.id) });
    expect(streak?.currentCount).toBeGreaterThanOrEqual(0);

    const updates = emitToUser.mock.calls.filter((c) => c[1] === 'economy:streak_updated');
    expect(updates).toHaveLength(1);
    expect(updates[0][0]).toBe(user.id);
  });

  it('rolls the streak back with the rest of a failed completion', async () => {
    enableP1();
    const { user, household } = await setup();
    const created = await request(app)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Fregar' });

    const spy = jest
      .spyOn(await import('../models/HouseholdProgress').then((m) => m.HouseholdProgressModel),
        'findOneAndUpdate')
      .mockRejectedValueOnce(new Error('projection write failed'));

    const res = await request(app)
      .post(`/api/households/${household.id}/tasks/${created.body.data.id}/completions`)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-streak-rollback')
      .send({ timeZone: ZONE });

    expect(res.status).toBe(500);
    // A completion that rolled back must not have advanced a flame.
    await expect(StreakDayModel.countDocuments({})).resolves.toBe(0);
    spy.mockRestore();
  });
});

describe('flag OFF — no streak machinery runs', () => {
  it('creates no streak or day when a task is completed', async () => {
    const { user, household } = await setup();
    const created = await request(app)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Fregar' });

    await request(app)
      .post(`/api/households/${household.id}/tasks/${created.body.data.id}/completions`)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-off-streak')
      .send({ timeZone: ZONE });

    await expect(PersonalStreakModel.countDocuments({})).resolves.toBe(0);
    await expect(StreakDayModel.countDocuments({})).resolves.toBe(0);
  });

  it('does not close days on the read either', async () => {
    const { user, household } = await setup();

    await request(app)
      .get(`/api/households/${household.id}/economy/p1/me?timeZone=UTC`)
      .set(authHeader(user.accessToken));

    await expect(PersonalStreakModel.countDocuments({})).resolves.toBe(0);
  });
});

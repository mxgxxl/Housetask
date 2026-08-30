import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { HouseholdProgressModel } from '../models/HouseholdProgress';
import { JointSavingsGoalModel } from '../models/JointSavingsGoal';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { PersonalStreakModel } from '../models/PersonalStreak';
import { SavingsContributionModel } from '../models/SavingsContribution';
import { UserProgressModel } from '../models/UserProgress';
import { InMemoryIdempotencyStore } from '../services/idempotency.store';
import { resetP1EnabledResolver, setP1EnabledResolver } from '../services/feature-flag.service';
import {
  HOUSEHOLD_LEVEL_CURVE_FACTOR,
  PERSONAL_LEVEL_CURVE_FACTOR,
  TASK_HOUSEHOLD_XP,
  TASK_PERSONAL_XP,
  WEEKLY_CAP_COINS,
  xpRequiredForLevel,
} from '../config/economy-p1';
import { dayIndexIn, releasedOnDay, releasedThroughDay, weekKey } from '../utils/economy-period';
import { unassignedAward } from './p1-award';
import { buildTestApp } from './setup';
import {
  TestHousehold,
  TestUser,
  authHeader,
  createTestHousehold,
  createTestUser,
  joinTestHousehold,
} from './helpers';

/**
 * The P1 read contract (TD-066 B6, design §5).
 *
 * Two properties matter more than the field list, and both are asserted
 * directly rather than assumed:
 *
 *  1. With the flag OFF — every household today — the endpoints answer a
 *     COMPLETE zeroed structure, not a 404 and not a partial object. A client
 *     shipped before its household is migrated must render an empty wallet,
 *     never an error state.
 *  2. The household endpoint carries no member's money. That is the line
 *     PDR-012 draws, and the only way to know it holds is to put a second
 *     member's wallet in the database and check it does not come back.
 */
let app: Server;

const MONDAY = '2026-08-24T10:00:00.000Z';
const ZONE = 'UTC';

/** What an unassigned task pays on the pinned Monday, under the B8 plan. */
const MONDAY_AWARD = unassignedAward(0);

beforeAll(async () => {
  app = await buildTestApp({ idempotencyStore: new InMemoryIdempotencyStore() });
});

afterEach(() => {
  resetP1EnabledResolver();
});

function enableP1(): void {
  setP1EnabledResolver(async () => true);
}

function meUrl(householdId: string, timeZone = ZONE): string {
  return `/api/households/${householdId}/economy/p1/me?timeZone=${encodeURIComponent(timeZone)}`;
}

function householdUrl(householdId: string): string {
  return `/api/households/${householdId}/economy/p1/household`;
}

async function setup(): Promise<{ user: TestUser; household: TestHousehold }> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  return { user, household };
}

async function addTask(user: TestUser, householdId: string, title: string): Promise<string> {
  const res = await request(app)
    .post(`/api/households/${householdId}/tasks`)
    .set(authHeader(user.accessToken))
    .send({ title });
  return res.body.data.id;
}

async function completeTask(
  user: TestUser,
  householdId: string,
  taskId: string,
  key: string,
): Promise<void> {
  await request(app)
    .post(`/api/households/${householdId}/tasks/${taskId}/completions`)
    .set(authHeader(user.accessToken))
    .set('Idempotency-Key', key)
    .send({ occurredAt: MONDAY, timeZone: ZONE });
}

describe('GET .../economy/p1/me — flag OFF', () => {
  it('answers 200 with a complete zeroed structure, never a 404', async () => {
    const { user, household } = await setup();

    const res = await request(app).get(meUrl(household.id)).set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    // `enabled` is what tells a client to hide the UI rather than render
    // zeroes as if they were real numbers.
    expect(res.body.data.enabled).toBe(false);
    expect(res.body.data.wallet).toEqual({ balance: 0, dailyReleased: 0, remaining: 0 });
    expect(res.body.data.personalProgress).toEqual({
      xp: 0,
      level: 1,
      // B7 added this to the read contract: an unlock announced only over a
      // socket is forgotten on the next app launch. Empty at level 1, since
      // the first personal unlock is at level 2.
      unlocks: [],
      // F1: surfaced so the client can show the number a task-count milestone
      // celebrated.
      tasksCompleted: 0,
      xpIntoLevel: 0,
      xpForNextLevel: xpRequiredForLevel(2, PERSONAL_LEVEL_CURVE_FACTOR),
      xpToNextLevel: xpRequiredForLevel(2, PERSONAL_LEVEL_CURVE_FACTOR),
    });
    expect(res.body.data.streak).toEqual({
      current: 0,
      longest: 0,
      iceReserve: 0,
      iceMilestonesReached: [],
    });
    // Every key of the populated shape is present, so the client parses one
    // structure rather than two.
    expect(Object.keys(res.body.data.weeklyBudget).sort()).toEqual([
      'allocations',
      'grantedCoins',
      'periodTimeZone',
      'planVersion',
      'releasedCoins',
      'weekKey',
      'weeklyCap',
    ]);
    expect(res.body.data.weeklyBudget.allocations).toEqual([]);
  });

  it('writes nothing while answering', async () => {
    const { user, household } = await setup();
    await request(app).get(meUrl(household.id)).set(authHeader(user.accessToken));

    await expect(UserProgressModel.countDocuments({})).resolves.toBe(0);
    await expect(PersonalCoinLedgerModel.countDocuments({})).resolves.toBe(0);
  });
});

describe('GET .../economy/p1/me — flag ON', () => {
  it('reports the standing budget before the week has any completion', async () => {
    // "33 available today" must be true before you complete anything —
    // answering 0 until the first task inverts the meaning of the line
    // UX-P1-SPEC §4 renders.
    enableP1();
    const { user, household } = await setup();

    const res = await request(app).get(meUrl(household.id)).set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.enabled).toBe(true);
    expect(res.body.data.wallet.balance).toBe(0);
    expect(res.body.data.wallet.remaining).toBeGreaterThan(0);
    expect(res.body.data.weeklyBudget.weeklyCap).toBe(WEEKLY_CAP_COINS);
    expect(res.body.data.weeklyBudget.grantedCoins).toBe(0);
  });

  it('agrees with the ledgers after a real completion', async () => {
    enableP1();
    const { user, household } = await setup();
    const taskId = await addTask(user, household.id, 'Fregar');
    await completeTask(user, household.id, taskId, 'op-read-1');

    const res = await request(app).get(meUrl(household.id)).set(authHeader(user.accessToken));

    // The wallet is the SUM of the ledger, not a counter that could drift.
    const [aggregated] = await PersonalCoinLedgerModel.aggregate<{ total: number }>([
      { $match: { userId: new Types.ObjectId(user.id) } },
      { $group: { _id: null, total: { $sum: '$amount' } } },
    ]);
    expect(res.body.data.wallet.balance).toBe(aggregated.total);
    expect(res.body.data.wallet.balance).toBe(MONDAY_AWARD);

    expect(res.body.data.personalProgress.xp).toBe(TASK_PERSONAL_XP);
    expect(res.body.data.personalProgress.level).toBe(1);
    expect(res.body.data.personalProgress.xpIntoLevel).toBe(TASK_PERSONAL_XP);
    expect(res.body.data.personalProgress.xpToNextLevel).toBe(
      xpRequiredForLevel(2, PERSONAL_LEVEL_CURVE_FACTOR) - TASK_PERSONAL_XP,
    );

    expect(res.body.data.weeklyBudget.grantedCoins).toBe(MONDAY_AWARD);
    expect(res.body.data.weeklyBudget.weekKey).toBe(weekKey(new Date(MONDAY), ZONE));
  });

  it('reports remaining as what today released minus what was granted', async () => {
    enableP1();
    const { user, household } = await setup();
    const taskId = await addTask(user, household.id, 'Fregar');
    await completeTask(user, household.id, taskId, 'op-read-2');

    const res = await request(app).get(meUrl(household.id)).set(authHeader(user.accessToken));
    const budget = res.body.data.weeklyBudget;
    expect(budget.grantedCoins).toBe(MONDAY_AWARD);

    // The invariant a client may rely on. It only holds because the read
    // recomputes `releasedCoins` for TODAY instead of echoing the stored
    // checkpoint, which the write path last touched on the day of the
    // completion — Monday here, whatever day the suite actually runs.
    expect(res.body.data.wallet.remaining).toBe(budget.releasedCoins - budget.grantedCoins);
  });

  it('reads the wallet across households, because it is personal (PDR-012)', async () => {
    enableP1();
    const { user, household } = await setup();
    const other = await createTestHousehold(app, user, 'Segunda casa');

    const t1 = await addTask(user, household.id, 'Una');
    const t2 = await addTask(user, other.id, 'Otra');
    await completeTask(user, household.id, t1, 'op-cross-1');
    await completeTask(user, other.id, t2, 'op-cross-2');

    // One wallet, two budgets: asking either household reports the same
    // balance, because a member of two households does not have two purses.
    const fromFirst = await request(app).get(meUrl(household.id)).set(authHeader(user.accessToken));
    const fromSecond = await request(app).get(meUrl(other.id)).set(authHeader(user.accessToken));

    expect(fromFirst.body.data.wallet.balance).toBe(MONDAY_AWARD * 2);
    expect(fromSecond.body.data.wallet.balance).toBe(MONDAY_AWARD * 2);
    // ...but the per-household budget only counted its own grant. Each home
    // has its own weekly ceiling, so neither capped the other.
    expect(fromFirst.body.data.weeklyBudget.grantedCoins).toBe(MONDAY_AWARD);
    expect(fromSecond.body.data.weeklyBudget.grantedCoins).toBe(MONDAY_AWARD);
  });

  it('reports the streak and the milestones its longest run has passed', async () => {
    enableP1();
    const { user, household } = await setup();
    await PersonalStreakModel.create({
      userId: new Types.ObjectId(user.id),
      scope: 'account',
      currentCount: 3,
      longestCount: 15,
      iceReserve: 1,
    });

    const res = await request(app).get(meUrl(household.id)).set(authHeader(user.accessToken));

    expect(res.body.data.streak.current).toBe(3);
    expect(res.body.data.streak.longest).toBe(15);
    expect(res.body.data.streak.iceReserve).toBe(1);
    // Derived from the LONGEST run: a milestone already earned must not
    // vanish because a streak broke (PDR-019's non-punitive tone).
    expect(res.body.data.streak.iceMilestonesReached).toEqual([7, 14]);
  });

  it('honours the requested timezone when no budget has fixed one yet', async () => {
    enableP1();
    const { user, household } = await setup();

    const res = await request(app)
      .get(meUrl(household.id, 'Europe/Madrid'))
      .set(authHeader(user.accessToken));

    expect(res.body.data.weeklyBudget.periodTimeZone).toBe('Europe/Madrid');
  });

  it('lets the stored budget zone win over the request', async () => {
    enableP1();
    const { user, household } = await setup();
    const taskId = await addTask(user, household.id, 'Fregar');
    await completeTask(user, household.id, taskId, 'op-zone'); // snapshots UTC

    const res = await request(app)
      .get(meUrl(household.id, 'Europe/Madrid'))
      .set(authHeader(user.accessToken));

    // A device that changed zone mid-week must not re-slice a week that is
    // already being settled — same rule as the write path.
    expect(res.body.data.weeklyBudget.periodTimeZone).toBe(ZONE);
  });

  it('rejects an unknown IANA zone instead of falling back silently', async () => {
    enableP1();
    const { user, household } = await setup();

    const res = await request(app)
      .get(meUrl(household.id, 'Mars/Olympus'))
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(400);
    expect(res.body.success).toBe(false);
  });
});

describe('GET .../economy/p1/household', () => {
  it('answers a zeroed shape with the real roster while P1 is off', async () => {
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    const res = await request(app)
      .get(householdUrl(household.id))
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.enabled).toBe(false);
    expect(res.body.data.householdProgress.level).toBe(1);
    expect(res.body.data.activeSavingsGoal).toBeNull();
    // The roster is not economy data: an empty list here would make the
    // client show an empty household rather than one whose economy is off.
    expect(res.body.data.members).toHaveLength(2);
    expect(res.body.data.members.map((m: { name: string }) => m.name)).toEqual([
      user.name,
      mate.name,
    ]);
  });

  it('reports shared XP that matches the projection', async () => {
    enableP1();
    const { user, household } = await setup();
    const t1 = await addTask(user, household.id, 'Una');
    const t2 = await addTask(user, household.id, 'Otra');
    await completeTask(user, household.id, t1, 'op-hh-1');
    await completeTask(user, household.id, t2, 'op-hh-2');

    const res = await request(app)
      .get(householdUrl(household.id))
      .set(authHeader(user.accessToken));

    const stored = await HouseholdProgressModel.findOne({ householdId: household.id });
    expect(res.body.data.householdProgress.xp).toBe(stored?.xp);
    expect(res.body.data.householdProgress.xp).toBe(TASK_HOUSEHOLD_XP * 2);
    expect(res.body.data.householdProgress.xpToNextLevel).toBe(
      xpRequiredForLevel(2, HOUSEHOLD_LEVEL_CURVE_FACTOR) - TASK_HOUSEHOLD_XP * 2,
    );
  });

  it('NEVER exposes another member wallet, budget or streak', async () => {
    // The assertion the whole privacy line rests on. A second member is given
    // a real balance, a real budget and a real streak, and none of it may
    // appear anywhere in this response.
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    const mateTask = await addTask(mate, household.id, 'Tarea del compañero');
    await completeTask(mate, household.id, mateTask, 'op-mate');
    // The completion already created their streak (B9), so this fills it in
    // rather than inserting a second one — which the unique index forbids.
    await PersonalStreakModel.updateOne(
      { userId: new Types.ObjectId(mate.id), scope: 'account' },
      { $set: { currentCount: 9, longestCount: 9, iceReserve: 2 } },
    );

    const res = await request(app)
      .get(householdUrl(household.id))
      .set(authHeader(user.accessToken));

    const serialized = JSON.stringify(res.body);
    expect(serialized).not.toContain('wallet');
    expect(serialized).not.toContain('balance');
    expect(serialized).not.toContain('weeklyBudget');
    expect(serialized).not.toContain('grantedCoins');
    expect(serialized).not.toContain('iceReserve');
    expect(serialized).not.toContain('streak');

    // What IS shared: the mate's level and XP (owner decision), nothing else.
    const mateView = res.body.data.members.find(
      (m: { userId: string }) => m.userId === mate.id,
    );
    expect(mateView).toEqual({
      userId: mate.id,
      name: mate.name,
      avatarUrl: null,
      level: 1,
      xp: TASK_PERSONAL_XP,
    });
  });

  it('lists members in join order, not ranked by XP', async () => {
    // UX-P1-SPEC §8 rules out a leaderboard; a stable order is what stops a
    // client rendering one by accident.
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    // Give the LATER member more XP than the creator.
    const mateTask = await addTask(mate, household.id, 'Del compañero');
    await completeTask(mate, household.id, mateTask, 'op-order');

    const res = await request(app)
      .get(householdUrl(household.id))
      .set(authHeader(user.accessToken));

    const ids = res.body.data.members.map((m: { userId: string }) => m.userId);
    expect(ids).toEqual([user.id, mate.id]);
    expect(res.body.data.members[0].xp).toBeLessThan(res.body.data.members[1].xp);
  });

  it('shows the active savings goal with one figure per contributor', async () => {
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    const goal = await JointSavingsGoalModel.create({
      householdId: new Types.ObjectId(household.id),
      itemType: 'cosmetic',
      itemId: 'dragon-skin',
      targetCoins: 100,
      contributedCoins: 68,
      createdBy: new Types.ObjectId(user.id),
    });
    // Two contributions from the same member must read as one number: the UI
    // renders "Tú: 40 · Ana: 28", one figure per person.
    await SavingsContributionModel.create([
      {
        goalId: goal._id,
        householdId: new Types.ObjectId(household.id),
        userId: new Types.ObjectId(user.id),
        amount: 25,
        operationId: 'c1',
      },
      {
        goalId: goal._id,
        householdId: new Types.ObjectId(household.id),
        userId: new Types.ObjectId(user.id),
        amount: 15,
        operationId: 'c2',
      },
      {
        goalId: goal._id,
        householdId: new Types.ObjectId(household.id),
        userId: new Types.ObjectId(mate.id),
        amount: 28,
        operationId: 'c3',
      },
    ]);

    const res = await request(app)
      .get(householdUrl(household.id))
      .set(authHeader(user.accessToken));

    const view = res.body.data.activeSavingsGoal;
    expect(view.itemId).toBe('dragon-skin');
    expect(view.targetCoins).toBe(100);
    expect(view.contributedCoins).toBe(68);
    expect(view.contributions).toHaveLength(2);
    const mine = view.contributions.find((c: { userId: string }) => c.userId === user.id);
    expect(mine.amount).toBe(40);
    const theirs = view.contributions.find((c: { userId: string }) => c.userId === mate.id);
    expect(theirs).toEqual({ userId: mate.id, name: mate.name, amount: 28 });
  });

  it('ignores a cancelled goal', async () => {
    enableP1();
    const { user, household } = await setup();
    await JointSavingsGoalModel.create({
      householdId: new Types.ObjectId(household.id),
      itemType: 'cosmetic',
      itemId: 'hat',
      targetCoins: 20,
      status: 'cancelled',
      createdBy: new Types.ObjectId(user.id),
    });

    const res = await request(app)
      .get(householdUrl(household.id))
      .set(authHeader(user.accessToken));

    expect(res.body.data.activeSavingsGoal).toBeNull();
  });
});

describe('authorization — requireMembership is the single checkpoint', () => {
  it('answers 403 to a non-member on both endpoints', async () => {
    enableP1();
    const { household } = await setup();
    const stranger = await createTestUser(app);

    const me = await request(app).get(meUrl(household.id)).set(authHeader(stranger.accessToken));
    const hh = await request(app)
      .get(householdUrl(household.id))
      .set(authHeader(stranger.accessToken));

    expect(me.status).toBe(403);
    expect(hh.status).toBe(403);
  });

  it('answers 401 without a token', async () => {
    const { household } = await setup();
    await expect(
      request(app)
        .get(meUrl(household.id))
        .then((r) => r.status),
    ).resolves.toBe(401);
  });

  it('answers 404 for a household that does not exist', async () => {
    enableP1();
    const user = await createTestUser(app);
    const res = await request(app)
      .get(meUrl(new Types.ObjectId().toString()))
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(404);
  });

  it('returns the CALLER\'s economy, with no id to tamper with', async () => {
    // The member is taken from the access token, never from a param — there
    // is no way to ask this endpoint for someone else's wallet.
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    const mateTask = await addTask(mate, household.id, 'Del compañero');
    await completeTask(mate, household.id, mateTask, 'op-caller');

    const asOwner = await request(app).get(meUrl(household.id)).set(authHeader(user.accessToken));
    const asMate = await request(app).get(meUrl(household.id)).set(authHeader(mate.accessToken));

    expect(asOwner.body.data.wallet.balance).toBe(0);
    expect(asMate.body.data.wallet.balance).toBe(MONDAY_AWARD);
  });
});

describe('Fase A stays untouched', () => {
  it('keeps GET .../economy answering its own shape', async () => {
    // Design §6.5: the two economies coexist for the whole migration. The P1
    // routes are mounted under /p1 precisely so this one never moves.
    enableP1();
    const { user, household } = await setup();
    const taskId = await addTask(user, household.id, 'Fregar');
    await completeTask(user, household.id, taskId, 'op-fase-a');

    const res = await request(app)
      .get(`/api/households/${household.id}/economy`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(Object.keys(res.body.data).sort()).toEqual([
      'balance',
      'dailyEarned',
      'recentTransactions',
    ]);
    // Owner decision P2(b): the Fase A grant keeps running in parallel.
    expect(res.body.data.balance).toBeGreaterThan(0);
  });
});

describe('budget arithmetic surfaced by the read', () => {
  it('matches releasedOnDay/releasedThroughDay for the stored week', async () => {
    enableP1();
    const { user, household } = await setup();
    const taskId = await addTask(user, household.id, 'Fregar');
    await completeTask(user, household.id, taskId, 'op-arith');

    const res = await request(app).get(meUrl(household.id)).set(authHeader(user.accessToken));
    const budget = res.body.data.weeklyBudget;

    // Whatever today is when the suite runs, the reported figures must be the
    // ones the pure functions produce for that same day — the read must not
    // invent its own arithmetic.
    //
    // The day index comes from the clock, the same way the read derives it,
    // and NOT by inverting releasedCoins. That inversion is ambiguous exactly
    // once a week: releasedThroughDay telescopes at `min(d + 1, 6)`, so
    // Saturday and Sunday both equal the full cap, and a `.find()` over the
    // week returns Saturday on a Sunday. The test then demanded Saturday's
    // increment while the read correctly reported Sunday's zero (PDR-013), so
    // this suite failed every Sunday — and only on a Sunday.
    const dayIndex = dayIndexIn(new Date(), budget.periodTimeZone);
    expect(budget.releasedCoins).toBe(releasedThroughDay(budget.weeklyCap, dayIndex));
    expect(res.body.data.wallet.dailyReleased).toBe(releasedOnDay(budget.weeklyCap, dayIndex));
  });
});

import { Server } from 'http';
import request from 'supertest';

import * as socketModule from '../config/socket';
import { HouseholdProgressModel } from '../models/HouseholdProgress';
import { RewardGrantModel } from '../models/RewardGrant';
import { WeeklyPersonalBudgetModel } from '../models/WeeklyPersonalBudget';
import { InMemoryIdempotencyStore } from '../services/idempotency.store';
import { resetP1EnabledResolver, setP1EnabledResolver } from '../services/feature-flag.service';
import { TASK_HOUSEHOLD_XP, TASK_PERSONAL_XP, WEEKLY_CAP_COINS } from '../config/economy-p1';
import { releasedOnDay, releasedThroughDay, weekKey } from '../utils/economy-period';
import { recentInstantOnDay, unassignedAward } from './p1-award';
import { buildTestApp } from './setup';
import {
  TestHousehold,
  TestUser,
  authHeader,
  createTestHousehold,
  createTestUser,
} from './helpers';

/**
 * Which P1 events a completion emits, to whom, and — the part that matters
 * most — when NOT to emit at all (TD-066 B5).
 *
 * Complements socket-rooms.test.ts, which proves delivery with real clients.
 * This one proves the SERVICE asks for the right delivery: the two together
 * are what make "the wallet event reaches its owner alone" a property of the
 * system rather than of one layer.
 */
let app: Server;

let emitToUser: jest.SpyInstance;
let emitToHousehold: jest.SpyInstance;

// A recent Monday and Sunday, derived from the clock rather than pinned.
// Pinning the instant is what these used to do, and it kept the coin
// assertions independent of the day the suite runs — but a fixed date also
// EXPIRES: `occurredAt` is rejected as `too_old` past seven days, so
// '2026-08-23T10:00:00.000Z' stopped validating at 2026-08-30T10:00:00Z and
// took these suites down mid-morning. `recentInstantOnDay` keeps the property
// that mattered (a known day index) without the expiry.
const MONDAY = recentInstantOnDay(0);
const SUNDAY = recentInstantOnDay(6);
const ZONE = 'UTC';

/** What an unassigned task pays on that Monday, under the B8 plan. */
const MONDAY_AWARD = unassignedAward(0);
/** ...and on that Sunday, when the whole week's remainder is available. */
const SUNDAY_AWARD = unassignedAward(6);

beforeAll(async () => {
  app = await buildTestApp({ idempotencyStore: new InMemoryIdempotencyStore() });
});

beforeEach(() => {
  emitToUser = jest.spyOn(socketModule, 'emitToUser').mockImplementation(() => undefined);
  emitToHousehold = jest
    .spyOn(socketModule, 'emitToHousehold')
    .mockImplementation(() => undefined);
});

afterEach(() => {
  jest.restoreAllMocks();
  resetP1EnabledResolver();
});

function enableP1(): void {
  setP1EnabledResolver(async () => true);
}

async function setup(): Promise<{ user: TestUser; household: TestHousehold; taskId: string }> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  const res = await request(app)
    .post(`/api/households/${household.id}/tasks`)
    .set(authHeader(user.accessToken))
    .send({ title: 'Fregar los platos' });
  return { user, household, taskId: res.body.data.id };
}

async function addTask(user: TestUser, householdId: string, title: string): Promise<string> {
  const res = await request(app)
    .post(`/api/households/${householdId}/tasks`)
    .set(authHeader(user.accessToken))
    .send({ title });
  return res.body.data.id;
}

function complete(
  user: TestUser,
  householdId: string,
  taskId: string,
  key: string,
  body: Record<string, unknown> = { occurredAt: MONDAY, timeZone: ZONE },
): request.Test {
  return request(app)
    .post(`/api/households/${householdId}/tasks/${taskId}/completions`)
    .set(authHeader(user.accessToken))
    .set('Idempotency-Key', key)
    .send(body);
}

/** Payloads a spy received for one event name. */
function payloadsFor(spy: jest.SpyInstance, event: string): unknown[] {
  return spy.mock.calls.filter((call) => call[1] === event).map((call) => call[2]);
}

describe('flag ON — the three P1 events', () => {
  it('emits economy:reward to the completing member only', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const res = await complete(user, household.id, taskId, 'op-reward');
    expect(res.status).toBe(200);

    const rewards = emitToUser.mock.calls.filter((c) => c[1] === 'economy:reward');
    expect(rewards).toHaveLength(1);
    // Addressed to the member, never to the household.
    expect(rewards[0][0]).toBe(user.id);
    expect(rewards[0][2]).toEqual({
      receiptId: res.body.data.receiptId,
      coins: MONDAY_AWARD,
      personalXp: TASK_PERSONAL_XP,
    });

    // Personal amounts must not appear on the household channel at all.
    expect(payloadsFor(emitToHousehold, 'economy:reward')).toEqual([]);
    expect(payloadsFor(emitToHousehold, 'economy:budget_updated')).toEqual([]);
  });

  it('emits economy:budget_updated with what is left after this grant', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    await complete(user, household.id, taskId, 'op-budget');

    const budgets = emitToUser.mock.calls.filter((c) => c[1] === 'economy:budget_updated');
    expect(budgets).toHaveLength(1);
    expect(budgets[0][0]).toBe(user.id);
    expect(budgets[0][2]).toEqual({
      weekKey: weekKey(new Date(MONDAY), ZONE),
      // Monday releases the first of six allocations; this completion took
      // DEFAULT_TASK_COINS out of it.
      remaining: releasedThroughDay(WEEKLY_CAP_COINS, 0) - MONDAY_AWARD,
      dailyReleased: releasedOnDay(WEEKLY_CAP_COINS, 0),
    });
  });

  it('decreases `remaining` across successive completions', async () => {
    enableP1();
    const { user, household, taskId } = await setup();
    const second = await addTask(user, household.id, 'Otra');

    await complete(user, household.id, taskId, 'op-b1');
    await complete(user, household.id, second, 'op-b2');

    const remainings = payloadsFor(emitToUser, 'economy:budget_updated').map(
      (p) => (p as { remaining: number }).remaining,
    );
    // Monday's release is consumed entirely by the first completion, so the
    // second is granted nothing and `remaining` stays at zero.
    // Two unassigned tasks are pending when the plan is built, so the common
    // tranche is split between them.
    const firstAward = unassignedAward(0, 2);
    const secondAward = unassignedAward(0, 2, firstAward);
    const afterFirst = releasedThroughDay(WEEKLY_CAP_COINS, 0) - firstAward;
    expect(remainings).toEqual([afterFirst, afterFirst - secondAward]);
    expect(remainings[1]).toBeLessThan(remainings[0]);
  });

  it('reports dailyReleased as 0 on Sunday, the rest day (PDR-013)', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    await complete(user, household.id, taskId, 'op-sunday', {
      occurredAt: SUNDAY,
      timeZone: ZONE,
    });

    const [budget] = payloadsFor(emitToUser, 'economy:budget_updated') as {
      dailyReleased: number;
      remaining: number;
    }[];
    // Sunday adds no allocation of its own...
    expect(budget.dailyReleased).toBe(0);
    // ...but the week's unspent remainder is still claimable (PDR-013), which
    // is why `remaining` is not 0 too.
    expect(budget.remaining).toBe(WEEKLY_CAP_COINS - SUNDAY_AWARD);
  });

  it('emits household:xp_updated to the household, not to one member', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    await complete(user, household.id, taskId, 'op-hh-xp');

    const xpEvents = emitToHousehold.mock.calls.filter((c) => c[1] === 'household:xp_updated');
    expect(xpEvents).toHaveLength(1);
    expect(xpEvents[0][0]).toBe(household.id);
    expect(xpEvents[0][2]).toEqual({ householdXp: TASK_HOUSEHOLD_XP, level: 1 });

    // Shared XP is shared by definition (PDR-017) — it must not be routed to
    // the personal channel, where only one member's devices would see it.
    expect(payloadsFor(emitToUser, 'household:xp_updated')).toEqual([]);
  });

  it('reports the household XP that was actually committed', async () => {
    enableP1();
    const { user, household, taskId } = await setup();
    const second = await addTask(user, household.id, 'Otra');

    await complete(user, household.id, taskId, 'op-x1');
    await complete(user, household.id, second, 'op-x2');

    const totals = payloadsFor(emitToHousehold, 'household:xp_updated').map(
      (p) => (p as { householdXp: number }).householdXp,
    );
    expect(totals).toEqual([TASK_HOUSEHOLD_XP, TASK_HOUSEHOLD_XP * 2]);

    const stored = await HouseholdProgressModel.findOne({ householdId: household.id });
    expect(stored?.xp).toBe(TASK_HOUSEHOLD_XP * 2);
  });

  it('still emits task:completed, so the existing client keeps working', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    await complete(user, household.id, taskId, 'op-task-evt');

    const taskEvents = emitToHousehold.mock.calls.filter((c) => c[1] === 'task:completed');
    expect(taskEvents).toHaveLength(1);
    expect(taskEvents[0][0]).toBe(household.id);
  });
});

describe('events are emitted after the commit, never before', () => {
  it('emits nothing economic when the transaction rolls back', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    // Fails at the last projection — after the claim and every ledger write.
    // A socket event cannot be un-emitted, so an implementation that emitted
    // inside the transaction would have already told the client its wallet
    // grew, with no way to take it back.
    const spy = jest
      .spyOn(HouseholdProgressModel, 'findOneAndUpdate')
      .mockRejectedValueOnce(new Error('projection write failed'));

    const res = await complete(user, household.id, taskId, 'op-rollback');
    expect(res.status).toBe(500);

    expect(payloadsFor(emitToUser, 'economy:reward')).toEqual([]);
    expect(payloadsFor(emitToUser, 'economy:budget_updated')).toEqual([]);
    expect(payloadsFor(emitToHousehold, 'household:xp_updated')).toEqual([]);
    // Not even the task event: the completion itself never happened.
    expect(payloadsFor(emitToHousehold, 'task:completed')).toEqual([]);

    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(0);
    spy.mockRestore();
  });

  it('emits nothing when occurredAt is refused', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const tooOld = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000).toISOString();
    const res = await complete(user, household.id, taskId, 'op-too-old', {
      occurredAt: tooOld,
      timeZone: ZONE,
    });

    expect(res.status).toBe(400);
    expect(emitToUser).not.toHaveBeenCalled();
    expect(payloadsFor(emitToHousehold, 'household:xp_updated')).toEqual([]);
  });

  it('emits nothing new when a retry replays an existing receipt', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    await complete(user, household.id, taskId, 'op-first');
    emitToUser.mockClear();
    emitToHousehold.mockClear();

    // A second, DIFFERENT operation on an already-claimed task. It must not
    // re-announce a reward that was paid once — the client would double-count
    // it against the receipt it already has.
    const replay = await complete(user, household.id, taskId, 'op-second');
    expect(replay.status).toBe(200);
    expect(replay.body.data.reward).toBeNull();

    expect(payloadsFor(emitToUser, 'economy:reward')).toEqual([]);
    expect(payloadsFor(emitToUser, 'economy:budget_updated')).toEqual([]);
    expect(payloadsFor(emitToHousehold, 'household:xp_updated')).toEqual([]);
  });
});

describe('flag OFF — no P1 event exists at all', () => {
  it('emits only task:completed, exactly as before TD-066', async () => {
    // No enableP1(): the shipped state of every household.
    const { user, household, taskId } = await setup();
    // setup() creates the task, which emits task:created. Cleared so the
    // assertion below is about what the COMPLETION emits, nothing else.
    emitToHousehold.mockClear();

    const res = await complete(user, household.id, taskId, 'op-flag-off');
    expect(res.status).toBe(200);

    expect(emitToUser).not.toHaveBeenCalled();
    const events = emitToHousehold.mock.calls.map((c) => c[1]);
    expect(events).toEqual(['task:completed']);

    await expect(WeeklyPersonalBudgetModel.countDocuments({})).resolves.toBe(0);
  });

  it('emits only task:updated for the generic PATCH, as before', async () => {
    const { user, household, taskId } = await setup();
    emitToHousehold.mockClear();

    await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}`)
      .set(authHeader(user.accessToken))
      .send({ status: 'completed' });

    expect(emitToUser).not.toHaveBeenCalled();
    const events = emitToHousehold.mock.calls.map((c) => c[1]);
    expect(events).toEqual(['task:updated']);
  });
});

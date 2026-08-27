import { Server } from 'http';
import request from 'supertest';

import { EconomyLedgerModel } from '../models/EconomyLedger';
import { HouseholdProgressModel } from '../models/HouseholdProgress';
import { HouseholdXpLedgerModel } from '../models/HouseholdXpLedger';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { PersonalXpLedgerModel } from '../models/PersonalXpLedger';
import { RewardGrantModel } from '../models/RewardGrant';
import { TaskModel } from '../models/Task';
import { UserProgressModel } from '../models/UserProgress';
import { WeeklyPersonalBudgetModel } from '../models/WeeklyPersonalBudget';
import { InMemoryIdempotencyStore } from '../services/idempotency.store';
import { resetP1EnabledResolver, setP1EnabledResolver } from '../services/feature-flag.service';
import {
  DEFAULT_TASK_COINS,
  TASK_HOUSEHOLD_XP,
  TASK_PERSONAL_XP,
  WEEKLY_CAP_COINS,
} from '../config/economy-p1';
import { TASK_COINS } from '../config/economy';
import { releasedThroughDay, weekKey } from '../utils/economy-period';
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
 * The P1 reward transaction (TD-066 B3).
 *
 * The endpoint ships with the flag OFF for every household, so most of what
 * these tests assert is not reachable in production yet. That is deliberate:
 * the guarantees below — one payout per task, a retry that replays instead of
 * paying, a rollback that leaves nothing behind — are cheapest to pin now,
 * while no data depends on them, and impossible to retrofit once it does.
 */
let app: Server;

// A fixed Monday: 2026-08-24 is a Monday, so day index 0 releases the first
// of the six allocations. Pinning the instant keeps the coin assertions from
// depending on the day the suite happens to run.
const MONDAY = '2026-08-24T10:00:00.000Z';
const SUNDAY = '2026-08-23T10:00:00.000Z';
const ZONE = 'UTC';

beforeAll(async () => {
  app = await buildTestApp({ idempotencyStore: new InMemoryIdempotencyStore() });
});

afterEach(() => {
  resetP1EnabledResolver();
});

/** Turn P1 on for every household in the test that calls it. */
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

function completionsUrl(householdId: string, taskId: string): string {
  return `/api/households/${householdId}/tasks/${taskId}/completions`;
}

describe('POST .../tasks/:taskId/completions — flag ON', () => {
  it('grants coins and both XP tracks on the first completion', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-first')
      .send({ occurredAt: MONDAY, timeZone: ZONE });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.data.reward).toEqual({
      coins: DEFAULT_TASK_COINS,
      personalXp: TASK_PERSONAL_XP,
      householdXp: TASK_HOUSEHOLD_XP,
    });
    expect(res.body.data.receiptId).toEqual(expect.any(String));
    expect(res.body.data.task.status).toBe('completed');

    // The receipt, and every ledger it claims to have written.
    const grant = await RewardGrantModel.findOne({ householdId: household.id, taskId });
    expect(grant?.completionOperationId).toBe('op-first');
    expect(grant?.userId.toString()).toBe(user.id);
    expect(grant?.coinAwarded).toBe(DEFAULT_TASK_COINS);

    await expect(PersonalCoinLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);
    await expect(
      HouseholdXpLedgerModel.countDocuments({ householdId: household.id }),
    ).resolves.toBe(1);

    // Projections moved with them, and the level was derived, not accumulated.
    const progress = await UserProgressModel.findOne({ userId: user.id });
    expect(progress?.xp).toBe(TASK_PERSONAL_XP);
    expect(progress?.level).toBe(1);
    const householdProgress = await HouseholdProgressModel.findOne({
      householdId: household.id,
    });
    expect(householdProgress?.xp).toBe(TASK_HOUSEHOLD_XP);

    // And the budget recorded the spend against the right week.
    const budget = await WeeklyPersonalBudgetModel.findOne({ userId: user.id });
    expect(budget?.weekKey).toBe(weekKey(new Date(MONDAY), ZONE));
    expect(budget?.weeklyCap).toBe(WEEKLY_CAP_COINS);
    expect(budget?.grantedCoins).toBe(DEFAULT_TASK_COINS);
    expect(budget?.periodTimeZone).toBe(ZONE);
  });

  it('snapshots the timezone so a mid-week zone change cannot re-slice the week', async () => {
    enableP1();
    const { user, household } = await setup();

    const first = await request(app)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Uno' });
    await request(app)
      .post(completionsUrl(household.id, first.body.data.id))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-zone-1')
      .send({ occurredAt: MONDAY, timeZone: 'Europe/Madrid' });

    const second = await request(app)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Dos' });
    await request(app)
      .post(completionsUrl(household.id, second.body.data.id))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-zone-2')
      .send({ occurredAt: MONDAY, timeZone: 'America/New_York' });

    // Both landed in the same ISO week, so the budget opened under Madrid is
    // the one that governs — the second request's zone does not overwrite it.
    const budgets = await WeeklyPersonalBudgetModel.find({ userId: user.id });
    expect(budgets).toHaveLength(1);
    expect(budgets[0].periodTimeZone).toBe('Europe/Madrid');
    expect(budgets[0].grantedCoins).toBe(DEFAULT_TASK_COINS * 2);
  });

  it('replays the original amounts for a retry with the same Idempotency-Key', async () => {
    enableP1();
    const { user, household, taskId } = await setup();
    const url = completionsUrl(household.id, taskId);

    const first = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-retry')
      .send({ occurredAt: MONDAY, timeZone: ZONE });

    const second = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-retry')
      .send({ occurredAt: MONDAY, timeZone: ZONE });

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(second.body).toEqual(first.body);

    // Exactly one payout, whatever the client did.
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(1);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);
    const budget = await WeeklyPersonalBudgetModel.findOne({ userId: user.id });
    expect(budget?.grantedCoins).toBe(DEFAULT_TASK_COINS);
  });

  it('pays once when two requests race with the SAME Idempotency-Key', async () => {
    enableP1();
    const { user, household, taskId } = await setup();
    const url = completionsUrl(household.id, taskId);

    const send = (): request.Test =>
      request(app)
        .post(url)
        .set(authHeader(user.accessToken))
        .set('Idempotency-Key', 'op-race-same')
        .send({ occurredAt: MONDAY, timeZone: ZONE });

    const [a, b] = await Promise.all([send(), send()]);

    // One of them may answer 409 ("still in progress") rather than waiting
    // out the original — either is correct per ADR-007. What must hold is
    // that the ledgers saw one completion.
    expect([200, 409]).toContain(a.status);
    expect([200, 409]).toContain(b.status);
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(1);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);
  });

  it('pays once when two requests race with DIFFERENT Idempotency-Keys', async () => {
    enableP1();
    const { user, household, taskId } = await setup();
    const url = completionsUrl(household.id, taskId);

    // Two devices, two keys: the idempotency middleware cannot help here —
    // it sees two distinct operations. The RewardGrant unique index is the
    // only thing standing between this and a double payout.
    const [a, b] = await Promise.all([
      request(app)
        .post(url)
        .set(authHeader(user.accessToken))
        .set('Idempotency-Key', 'op-race-a')
        .send({ occurredAt: MONDAY, timeZone: ZONE }),
      request(app)
        .post(url)
        .set(authHeader(user.accessToken))
        .set('Idempotency-Key', 'op-race-b')
        .send({ occurredAt: MONDAY, timeZone: ZONE }),
    ]);

    expect(a.status).toBe(200);
    expect(b.status).toBe(200);

    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(1);
    await expect(PersonalCoinLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);

    const rewards = [a.body.data.reward, b.body.data.reward];
    // Exactly one request earned it; the loser is told it earned nothing
    // rather than being shown the winner's payout.
    expect(rewards.filter((r) => r !== null)).toHaveLength(1);

    const budget = await WeeklyPersonalBudgetModel.findOne({ userId: user.id });
    expect(budget?.grantedCoins).toBe(DEFAULT_TASK_COINS);
  });

  it('reports no reward to a second member completing an already-claimed task', async () => {
    enableP1();
    const { user, household, taskId } = await setup();
    const other = await createTestUser(app);
    await joinTestHousehold(app, other, household.inviteCode);

    await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-owner')
      .send({ occurredAt: MONDAY, timeZone: ZONE });

    const second = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(other.accessToken))
      .set('Idempotency-Key', 'op-other')
      .send({ occurredAt: MONDAY, timeZone: ZONE });

    expect(second.status).toBe(200);
    expect(second.body.data.reward).toBeNull();
    expect(second.body.data.task.status).toBe('completed');
    await expect(PersonalXpLedgerModel.countDocuments({ userId: other.id })).resolves.toBe(0);
  });
});

describe('weekly budget limits (PDR-011, PDR-013)', () => {
  it('pays 0 coins but full XP once the budget is exhausted', async () => {
    enableP1();
    const { user, household } = await setup();

    // Open the week and drain it: mark everything released so far as granted.
    const first = await request(app)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Abre la semana' });
    await request(app)
      .post(completionsUrl(household.id, first.body.data.id))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-open')
      .send({ occurredAt: MONDAY, timeZone: ZONE });

    const released = releasedThroughDay(WEEKLY_CAP_COINS, 0);
    await WeeklyPersonalBudgetModel.updateOne(
      { userId: user.id },
      { $set: { grantedCoins: released } },
    );

    const second = await request(app)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Ya sin presupuesto' });
    const res = await request(app)
      .post(completionsUrl(household.id, second.body.data.id))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-drained')
      .send({ occurredAt: MONDAY, timeZone: ZONE });

    // The coins stop; the progress does not (TD-066-DESIGN §3).
    expect(res.body.data.reward).toEqual({
      coins: 0,
      personalXp: TASK_PERSONAL_XP,
      householdXp: TASK_HOUSEHOLD_XP,
    });

    // A zero payout writes no coin row — a 0-amount entry would be noise in a
    // wallet history people read — but the receipt still records the zero.
    await expect(PersonalCoinLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);
    const grant = await RewardGrantModel.findOne({ taskId: second.body.data.id });
    expect(grant?.coinAwarded).toBe(0);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(2);
  });

  it('releases nothing new on Sunday, while still granting XP', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-sunday')
      .send({ occurredAt: SUNDAY, timeZone: ZONE });

    expect(res.status).toBe(200);
    expect(res.body.data.reward.personalXp).toBe(TASK_PERSONAL_XP);
    expect(res.body.data.reward.householdXp).toBe(TASK_HOUSEHOLD_XP);

    // Sunday adds no allocation of its own; what it offers is the week's
    // UNSPENT remainder, which PDR-013 keeps available until the week turns.
    // On a fresh Sunday that remainder is the whole cap, so a completion
    // still pays. See the report's open question: UX-P1-SPEC's «las monedas
    // descansan» reads as a flat zero and disagrees with this.
    const budget = await WeeklyPersonalBudgetModel.findOne({ userId: user.id });
    expect(budget?.releasedCoins).toBe(WEEKLY_CAP_COINS);
    expect(budget?.releasedCoins).toBe(releasedThroughDay(WEEKLY_CAP_COINS, 5));
  });

  it('pays 0 coins on Sunday when the week was already spent', async () => {
    enableP1();
    const { user, household } = await setup();

    const first = await request(app)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Abre la semana' });
    await request(app)
      .post(completionsUrl(household.id, first.body.data.id))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-sun-open')
      .send({ occurredAt: SUNDAY, timeZone: ZONE });

    await WeeklyPersonalBudgetModel.updateOne(
      { userId: user.id },
      { $set: { grantedCoins: WEEKLY_CAP_COINS } },
    );

    const second = await request(app)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Domingo sin saldo' });
    const res = await request(app)
      .post(completionsUrl(household.id, second.body.data.id))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-sun-drained')
      .send({ occurredAt: SUNDAY, timeZone: ZONE });

    expect(res.body.data.reward).toEqual({
      coins: 0,
      personalXp: TASK_PERSONAL_XP,
      householdXp: TASK_HOUSEHOLD_XP,
    });
  });
});

describe('occurredAt window (TD-066-DESIGN §9)', () => {
  it('rejects a timestamp older than the window without granting anything', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const tooOld = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000).toISOString();
    const res = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-too-old')
      .send({ occurredAt: tooOld, timeZone: ZONE });

    expect(res.status).toBe(400);
    expect(res.body.success).toBe(false);
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(0);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(0);
    // And the task was not completed as a side effect of a refused reward.
    const task = await TaskModel.findById(taskId);
    expect(task?.status).toBe('pending');
  });

  it('rejects a timestamp beyond the future tolerance', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const future = new Date(Date.now() + 60 * 60 * 1000).toISOString();
    const res = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-future')
      .send({ occurredAt: future, timeZone: ZONE });

    expect(res.status).toBe(400);
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(0);
  });

  it('rejects an unknown IANA zone rather than silently falling back to UTC', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-bad-zone')
      .send({ occurredAt: MONDAY, timeZone: 'Mars/Olympus' });

    expect(res.status).toBe(400);
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(0);
  });

  it('defaults to now when the body is empty', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-empty')
      .send({});

    expect(res.status).toBe(200);
    expect(res.body.data.reward.personalXp).toBe(TASK_PERSONAL_XP);
  });
});

describe('transaction rollback', () => {
  it('leaves no receipt, no ledger and no completed task when a later write fails', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    // Fail at the last projection, after the claim and every ledger write —
    // the worst case, where a non-atomic implementation would have already
    // paid out and only then discovered it could not finish.
    const spy = jest
      .spyOn(HouseholdProgressModel, 'findOneAndUpdate')
      .mockRejectedValueOnce(new Error('projection write failed'));

    const res = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-rollback')
      .send({ occurredAt: MONDAY, timeZone: ZONE });

    expect(res.status).toBe(500);

    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(0);
    await expect(PersonalCoinLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(0);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(0);
    await expect(
      HouseholdXpLedgerModel.countDocuments({ householdId: household.id }),
    ).resolves.toBe(0);
    await expect(UserProgressModel.countDocuments({ userId: user.id })).resolves.toBe(0);
    await expect(WeeklyPersonalBudgetModel.countDocuments({ userId: user.id })).resolves.toBe(0);

    const task = await TaskModel.findById(taskId);
    expect(task?.status).toBe('pending');
    expect(task?.completedAt).toBeUndefined();

    spy.mockRestore();
  });

  it('lets the client retry successfully after a rolled-back attempt', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const spy = jest
      .spyOn(HouseholdProgressModel, 'findOneAndUpdate')
      .mockRejectedValueOnce(new Error('transient'));

    await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-retry-after-fail')
      .send({ occurredAt: MONDAY, timeZone: ZONE });
    spy.mockRestore();

    // A failed attempt must not lock its key for 24h (idempotency.middleware
    // releases it on a non-2xx), so the same key is usable again.
    const retry = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-retry-after-fail')
      .send({ occurredAt: MONDAY, timeZone: ZONE });

    expect(retry.status).toBe(200);
    expect(retry.body.data.reward.coins).toBe(DEFAULT_TASK_COINS);
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(1);
  });
});

describe('flag OFF — the shipped behaviour of every household today', () => {
  it('completes the task, reports no reward and writes nothing P1', async () => {
    // No enableP1(): the default resolver answers false.
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-flag-off')
      .send({ occurredAt: MONDAY, timeZone: ZONE });

    expect(res.status).toBe(200);
    expect(res.body.data.reward).toBeNull();
    expect(res.body.data.receiptId).toBeNull();
    expect(res.body.data.task.status).toBe('completed');

    await expect(RewardGrantModel.countDocuments({})).resolves.toBe(0);
    await expect(PersonalCoinLedgerModel.countDocuments({})).resolves.toBe(0);
    await expect(PersonalXpLedgerModel.countDocuments({})).resolves.toBe(0);
    await expect(HouseholdXpLedgerModel.countDocuments({})).resolves.toBe(0);
    await expect(WeeklyPersonalBudgetModel.countDocuments({})).resolves.toBe(0);
    await expect(UserProgressModel.countDocuments({})).resolves.toBe(0);
  });

  it('still grants the Fase A household coins, exactly as PATCH does', async () => {
    const { user, household, taskId } = await setup();

    await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-flag-off-coins')
      .send({});

    const entry = await EconomyLedgerModel.findOne({
      householdId: household.id,
      reason: 'task_complete',
    });
    expect(entry?.amount).toBe(TASK_COINS);
  });

  it('ignores occurredAt entirely, since no receipt records it', async () => {
    const { user, household, taskId } = await setup();

    // Out of the P1 window, but the window is only enforced where it means
    // something. With the flag off there is no budget week to protect.
    const tooOld = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
    const res = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-flag-off-old')
      .send({ occurredAt: tooOld, timeZone: ZONE });

    expect(res.status).toBe(200);
    expect(res.body.data.reward).toBeNull();
  });
});

describe('coexistence with the Fase A economy (owner decision P2b)', () => {
  it('grants BOTH the personal wallet and the household ledger while P1 is on', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-parallel')
      .send({ occurredAt: MONDAY, timeZone: ZONE });

    // Without the parallel grant the household ledger would stop growing the
    // moment P1 switches on, and the pet shop — which still spends that
    // balance — would become unaffordable mid-migration.
    const personal = await PersonalCoinLedgerModel.findOne({ userId: user.id });
    expect(personal?.amount).toBe(DEFAULT_TASK_COINS);

    const legacy = await EconomyLedgerModel.findOne({
      householdId: household.id,
      reason: 'task_complete',
    });
    expect(legacy?.amount).toBe(TASK_COINS);
  });
});

describe('authorization and validation', () => {
  it('rejects a non-member with 403 via requireMembership', async () => {
    enableP1();
    const { household, taskId } = await setup();
    const stranger = await createTestUser(app);

    const res = await request(app)
      .post(completionsUrl(household.id, taskId))
      .set(authHeader(stranger.accessToken))
      .send({});

    expect(res.status).toBe(403);
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(0);
  });

  it('rejects an unauthenticated request', async () => {
    const { household, taskId } = await setup();
    const res = await request(app).post(completionsUrl(household.id, taskId)).send({});
    expect(res.status).toBe(401);
  });

  it('answers 404 for a task that does not belong to the household', async () => {
    enableP1();
    const { user, household } = await setup();
    const other = await createTestHousehold(app, user, 'Otra casa');
    const foreign = await request(app)
      .post(`/api/households/${other.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Ajena' });

    const res = await request(app)
      .post(completionsUrl(household.id, foreign.body.data.id))
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-foreign')
      .send({});

    expect(res.status).toBe(404);
  });

  it('rejects a malformed body without burning the Idempotency-Key', async () => {
    enableP1();
    const { user, household, taskId } = await setup();
    const url = completionsUrl(household.id, taskId);

    const bad = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-reusable')
      .send({ occurredAt: 'not-a-date' });
    expect(bad.status).toBe(400);

    // validate() runs BEFORE idempotency, so the key was never claimed and
    // the client can reuse it for the corrected request.
    const good = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-reusable')
      .send({ occurredAt: MONDAY, timeZone: ZONE });
    expect(good.status).toBe(200);
    expect(good.body.data.reward.coins).toBe(DEFAULT_TASK_COINS);
  });
});

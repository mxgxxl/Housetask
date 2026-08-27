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
import { DEFAULT_TASK_COINS, TASK_PERSONAL_XP } from '../config/economy-p1';
import { TASK_COINS } from '../config/economy';
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
 * The three completion paths, unified (TD-066 B4).
 *
 * This is the highest-risk change of the round: `PATCH .../complete` and the
 * generic `PATCH` are what the published iOS build actually calls, and they
 * now route through the P1 service. The flag is off for every household, so
 * production behaviour must be indistinguishable from before — which is what
 * the "flag OFF" block below exists to prove, field by field rather than by
 * asserting a status code and hoping.
 *
 * The reason for unifying them at all is TD-066-DESIGN §5: two paths that
 * grant different rewards for the same task is the double-reward risk in its
 * most plausible form, since a client is free to complete a task either way.
 */
let app: Server;

beforeAll(async () => {
  app = await buildTestApp({ idempotencyStore: new InMemoryIdempotencyStore() });
});

afterEach(() => {
  resetP1EnabledResolver();
});

function enableP1(): void {
  setP1EnabledResolver(async () => true);
}

async function setup(
  title = 'Fregar los platos',
): Promise<{ user: TestUser; household: TestHousehold; taskId: string }> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  const res = await request(app)
    .post(`/api/households/${household.id}/tasks`)
    .set(authHeader(user.accessToken))
    .send({ title });
  return { user, household, taskId: res.body.data.id };
}

async function addTask(user: TestUser, householdId: string, title: string): Promise<string> {
  const res = await request(app)
    .post(`/api/households/${householdId}/tasks`)
    .set(authHeader(user.accessToken))
    .send({ title });
  return res.body.data.id;
}

describe('flag OFF — contract parity with the published client', () => {
  it('PATCH .../complete answers the bare task, with no P1 fields bolted on', async () => {
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);

    // `data` IS the task — not `{ task, reward, receiptId }`. Adding a wrapper
    // here would break every already-installed build.
    expect(res.body.data.id).toBe(taskId);
    expect(res.body.data.status).toBe('completed');
    expect(res.body.data.completedAt).toEqual(expect.any(String));
    expect(res.body.data.completedBy.id).toBe(user.id);
    expect(res.body.data).not.toHaveProperty('reward');
    expect(res.body.data).not.toHaveProperty('receiptId');
    expect(res.body.data).not.toHaveProperty('task');

    // completedBy comes back populated, as it always has.
    expect(res.body.data.completedBy.name).toBe(user.name);
    expect(res.body.data.createdBy.id).toBe(user.id);
  });

  it('PATCH .../complete still grants the Fase A household coins', async () => {
    const { user, household, taskId } = await setup();

    await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));

    const entry = await EconomyLedgerModel.findOne({
      householdId: household.id,
      reason: 'task_complete',
    });
    expect(entry?.amount).toBe(TASK_COINS);
    expect(entry?.refId).toBe(taskId);
  });

  it('PATCH .../complete writes no P1 document at all', async () => {
    const { user, household, taskId } = await setup();

    await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));

    await expect(RewardGrantModel.countDocuments({})).resolves.toBe(0);
    await expect(PersonalCoinLedgerModel.countDocuments({})).resolves.toBe(0);
    await expect(PersonalXpLedgerModel.countDocuments({})).resolves.toBe(0);
    await expect(HouseholdXpLedgerModel.countDocuments({})).resolves.toBe(0);
    await expect(WeeklyPersonalBudgetModel.countDocuments({})).resolves.toBe(0);
    await expect(UserProgressModel.countDocuments({})).resolves.toBe(0);
    await expect(HouseholdProgressModel.countDocuments({})).resolves.toBe(0);
  });

  it('the generic PATCH with status=completed behaves exactly as before', async () => {
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}`)
      .set(authHeader(user.accessToken))
      .send({ status: 'completed' });

    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('completed');
    expect(res.body.data.completedBy.id).toBe(user.id);
    expect(res.body.data).not.toHaveProperty('reward');

    // Its own Fase A hook is untouched.
    const entry = await EconomyLedgerModel.findOne({ householdId: household.id });
    expect(entry?.amount).toBe(TASK_COINS);
    await expect(RewardGrantModel.countDocuments({})).resolves.toBe(0);
  });

  it('the generic PATCH still applies other fields alongside the status', async () => {
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}`)
      .set(authHeader(user.accessToken))
      .send({ status: 'completed', title: 'Fregar y secar', priority: 'high' });

    expect(res.status).toBe(200);
    expect(res.body.data.title).toBe('Fregar y secar');
    expect(res.body.data.priority).toBe('high');
    expect(res.body.data.status).toBe('completed');
  });

  it('re-completing an already-completed task stays a safe no-op', async () => {
    const { user, household, taskId } = await setup();
    const url = `/api/households/${household.id}/tasks/${taskId}/complete`;

    const first = await request(app).patch(url).set(authHeader(user.accessToken));
    const second = await request(app).patch(url).set(authHeader(user.accessToken));

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    // One ledger entry, whatever the client did — the Fase A unique index.
    await expect(
      EconomyLedgerModel.countDocuments({ householdId: household.id, reason: 'task_complete' }),
    ).resolves.toBe(1);
  });

  it('answers 404 for a task in another household, as before', async () => {
    const { user, household } = await setup();
    const other = await createTestHousehold(app, user, 'Otra casa');
    const foreignId = await addTask(user, other.id, 'Ajena');

    const res = await request(app)
      .patch(`/api/households/${household.id}/tasks/${foreignId}/complete`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(404);
  });

  it('lets any member complete, but only creator/admin edit (Hard Rule 17)', async () => {
    // The task's creator is irrelevant here: what is under test is what a
    // DIFFERENT member may do to it.
    const { household, taskId } = await setup();
    const member = await createTestUser(app);
    await joinTestHousehold(app, member, household.inviteCode);

    // A non-creator member may complete...
    const completed = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(member.accessToken));
    expect(completed.status).toBe(200);

    // ...but may not edit someone else's task through the generic PATCH.
    const edited = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}`)
      .set(authHeader(member.accessToken))
      .send({ title: 'No debería poder' });
    expect(edited.status).toBe(403);
  });
});

describe('flag ON — one reward, whichever path is used', () => {
  it('PATCH .../complete produces a P1 receipt while keeping its old response', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    // The contract does not change just because the economy did.
    expect(res.body.data.id).toBe(taskId);
    expect(res.body.data.status).toBe('completed');
    expect(res.body.data).not.toHaveProperty('reward');

    const grant = await RewardGrantModel.findOne({ taskId });
    expect(grant?.coinAwarded).toBe(DEFAULT_TASK_COINS);
    expect(grant?.userId.toString()).toBe(user.id);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);
  });

  it('the generic PATCH with status=completed also produces a receipt', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}`)
      .set(authHeader(user.accessToken))
      .send({ status: 'completed' });

    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('completed');

    const grant = await RewardGrantModel.findOne({ taskId });
    expect(grant?.kind).toBe('task_first_completion');
    expect(grant?.coinAwarded).toBe(DEFAULT_TASK_COINS);
  });

  it('the generic PATCH applies other fields AND completes atomically', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}`)
      .set(authHeader(user.accessToken))
      .send({ status: 'completed', title: 'Fregar y secar', priority: 'high' });

    expect(res.status).toBe(200);
    expect(res.body.data.title).toBe('Fregar y secar');
    expect(res.body.data.priority).toBe('high');
    expect(res.body.data.status).toBe('completed');
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(1);
  });

  it('preserves creator-or-admin on a status-only generic PATCH', async () => {
    // The check that would have been LOST by handing the transition to a
    // service which, correctly, lets any member complete a task: the generic
    // PATCH has always required creator-or-admin, and B4 must not loosen it.
    enableP1();
    const { household, taskId } = await setup();
    const member = await createTestUser(app);
    await joinTestHousehold(app, member, household.inviteCode);

    const res = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}`)
      .set(authHeader(member.accessToken))
      .send({ status: 'completed' });

    expect(res.status).toBe(403);
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(0);

    // ...while the dedicated complete endpoint still works for them.
    const viaComplete = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(member.accessToken));
    expect(viaComplete.status).toBe(200);
  });

  it('PATCH then POST pays only once', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));

    const post = await request(app)
      .post(`/api/households/${household.id}/tasks/${taskId}/completions`)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-after-patch')
      .send({});

    expect(post.status).toBe(200);
    // The claim was already taken by the PATCH, under a different operation
    // id, so this request earned nothing.
    expect(post.body.data.reward).toBeNull();

    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(1);
    await expect(PersonalCoinLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);
    const progress = await UserProgressModel.findOne({ userId: user.id });
    expect(progress?.xp).toBe(TASK_PERSONAL_XP);
  });

  it('POST then PATCH pays only once', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const post = await request(app)
      .post(`/api/households/${household.id}/tasks/${taskId}/completions`)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-before-patch')
      .send({});
    expect(post.body.data.reward.coins).toBe(DEFAULT_TASK_COINS);

    const patch = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));

    expect(patch.status).toBe(200);
    expect(patch.body.data.status).toBe('completed');

    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(1);
    await expect(PersonalCoinLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);
    const budget = await WeeklyPersonalBudgetModel.findOne({ userId: user.id });
    expect(budget?.grantedCoins).toBe(DEFAULT_TASK_COINS);
  });

  it('generic PATCH then PATCH .../complete pays only once', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}`)
      .set(authHeader(user.accessToken))
      .send({ status: 'completed' });

    await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));

    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(1);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(1);
  });

  it('grants the Fase A coins exactly once across two different paths', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));
    await request(app)
      .post(`/api/households/${household.id}/tasks/${taskId}/completions`)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-legacy-parallel')
      .send({});

    // Owner decision P2(b) keeps the Fase A grant running in parallel during
    // the migration; its own unique index keeps it to one entry.
    await expect(
      EconomyLedgerModel.countDocuments({ householdId: household.id, reason: 'task_complete' }),
    ).resolves.toBe(1);
  });
});

describe('flag ON — an economic failure must not complete the task', () => {
  it('rolls the PATCH back entirely when the reward transaction fails', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const spy = jest
      .spyOn(HouseholdProgressModel, 'findOneAndUpdate')
      .mockRejectedValueOnce(new Error('projection write failed'));

    const res = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));

    // The deliberate behaviour change of B4: this used to complete the task
    // and merely lose the coins. It now fails as a unit — a task must not be
    // declared complete without its receipt (TD-066-DESIGN §4).
    expect(res.status).toBe(500);

    const task = await TaskModel.findById(taskId);
    expect(task?.status).toBe('pending');
    expect(task?.completedAt).toBeUndefined();
    expect(task?.completedBy).toBeUndefined();

    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(0);
    await expect(PersonalCoinLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(0);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(0);
    // The Fase A grant runs only after the commit, so it never happened.
    await expect(EconomyLedgerModel.countDocuments({ householdId: household.id })).resolves.toBe(
      0,
    );

    spy.mockRestore();
  });

  it('rolls back the generic PATCH completion, leaving the task pending', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const spy = jest
      .spyOn(HouseholdProgressModel, 'findOneAndUpdate')
      .mockRejectedValueOnce(new Error('projection write failed'));

    const res = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}`)
      .set(authHeader(user.accessToken))
      .send({ status: 'completed', title: 'Nuevo título' });

    expect(res.status).toBe(500);

    const task = await TaskModel.findById(taskId);
    expect(task?.status).toBe('pending');
    // The non-status fields were applied before the completion was attempted.
    // Failing in this direction is the safe one: the money stays consistent
    // and the client can retry. Documented rather than silently accepted.
    expect(task?.title).toBe('Nuevo título');
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(0);

    spy.mockRestore();
  });

  it('lets the client retry the PATCH successfully after a rollback', async () => {
    enableP1();
    const { user, household, taskId } = await setup();

    const spy = jest
      .spyOn(HouseholdProgressModel, 'findOneAndUpdate')
      .mockRejectedValueOnce(new Error('transient'));
    await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));
    spy.mockRestore();

    const retry = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));

    expect(retry.status).toBe(200);
    expect(retry.body.data.status).toBe('completed');
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(1);
  });
});

describe('Idempotency-Key on the legacy PATCH (optional, non-breaking)', () => {
  it('is ignored when absent, exactly as the published client behaves', async () => {
    const { user, household, taskId } = await setup();

    const res = await request(app)
      .patch(`/api/households/${household.id}/tasks/${taskId}/complete`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('completed');
  });

  it('replays the stored response when the same key is sent twice', async () => {
    enableP1();
    const { user, household, taskId } = await setup();
    const url = `/api/households/${household.id}/tasks/${taskId}/complete`;

    const first = await request(app)
      .patch(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'patch-key-1');
    const second = await request(app)
      .patch(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'patch-key-1');

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(second.body).toEqual(first.body);
    await expect(RewardGrantModel.countDocuments({ taskId })).resolves.toBe(1);
  });
});

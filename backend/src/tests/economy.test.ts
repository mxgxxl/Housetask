import { Server } from 'http';
import request from 'supertest';

import { buildTestApp } from './setup';
import {
  TestHousehold,
  TestUser,
  authHeader,
  createTestHousehold,
  createTestUser,
} from './helpers';
import { grantCoins, getBalance, getDailyEarned } from '../services/economy.service';
import { EconomyLedgerModel } from '../models/EconomyLedger';
import { DAILY_CAP, TASK_COINS, PURCHASE_COINS } from '../config/economy';

let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
  // Mongoose builds indexes in the background after connect(); without an
  // explicit wait here, this suite's very first grantCoins() duplicate-key
  // assertions can race the unique-index build and see a second insert
  // silently succeed. Same fix as tests/hardening.test.ts's
  // `builtKeyPatterns` helper — see its doc comment for why this class of
  // race is a real (if narrow, pre-existing) gap and not just a test flake.
  await EconomyLedgerModel.createIndexes();
});

async function setupHousehold(): Promise<{ user: TestUser; household: TestHousehold }> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  return { user, household };
}

describe('economy.service.grantCoins — idempotency', () => {
  it('should grant coins once per (householdId, refId, reason) and return 0 on a repeat', async () => {
    const { household } = await setupHousehold();
    const taskId = '507f1f77bcf86cd799439011';

    const first = await grantCoins(household.id, TASK_COINS, 'task_complete', taskId);
    const second = await grantCoins(household.id, TASK_COINS, 'task_complete', taskId);

    expect(first).toBe(TASK_COINS);
    expect(second).toBe(0);
    expect(await getBalance(household.id)).toBe(TASK_COINS);
  });

  it('should treat different reasons for the same refId as independent grants', async () => {
    const { household } = await setupHousehold();
    const refId = '507f1f77bcf86cd799439012';

    const taskGrant = await grantCoins(household.id, TASK_COINS, 'task_complete', refId);
    const purchaseGrant = await grantCoins(household.id, PURCHASE_COINS, 'purchase_complete', refId);

    expect(taskGrant).toBe(TASK_COINS);
    expect(purchaseGrant).toBe(PURCHASE_COINS);
    expect(await getBalance(household.id)).toBe(TASK_COINS + PURCHASE_COINS);
  });
});

describe('economy.service.grantCoins — daily cap', () => {
  it('should stop granting once the household has earned DAILY_CAP today', async () => {
    const { household } = await setupHousehold();

    let granted = 0;
    let refSeq = 0;
    // TASK_COINS=5, DAILY_CAP=50: exactly 10 grants reach the cap.
    while (granted < DAILY_CAP) {
      refSeq += 1;
      const refId = `507f1f77bcf86cd7994390${String(refSeq).padStart(2, '0')}`;
      granted += await grantCoins(household.id, TASK_COINS, 'task_complete', refId);
    }
    expect(granted).toBe(DAILY_CAP);
    expect(await getDailyEarned(household.id)).toBe(DAILY_CAP);

    // One more grant, brand new refId so idempotency isn't what blocks it.
    const overCapResult = await grantCoins(
      household.id,
      TASK_COINS,
      'task_complete',
      '507f1f77bcf86cd799439099',
    );

    expect(overCapResult).toBe(0);
    expect(await getBalance(household.id)).toBe(DAILY_CAP);
  });

  it('should not let the cap in one household affect another', async () => {
    const { household: householdA } = await setupHousehold();
    const { household: householdB } = await setupHousehold();

    let refSeq = 0;
    while ((await getDailyEarned(householdA.id)) < DAILY_CAP) {
      refSeq += 1;
      await grantCoins(
        householdA.id,
        TASK_COINS,
        'task_complete',
        `507f1f77bcf86cd7994391${String(refSeq).padStart(2, '0')}`,
      );
    }

    const resultForB = await grantCoins(
      householdB.id,
      TASK_COINS,
      'task_complete',
      '507f1f77bcf86cd799439200',
    );

    expect(resultForB).toBe(TASK_COINS);
  });
});

describe('completeTask — coin granting hook', () => {
  async function tasksUrl(household: TestHousehold): Promise<string> {
    return `/api/households/${household.id}/tasks`;
  }

  it('should grant TASK_COINS on first completion but not on recompletion', async () => {
    const { user, household } = await setupHousehold();
    const created = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(user.accessToken))
      .send({ title: 'Barrer' });

    const completeUrl = `${await tasksUrl(household)}/${created.body.data.id}/complete`;

    await request(app).patch(completeUrl).set(authHeader(user.accessToken));
    expect(await getBalance(household.id)).toBe(TASK_COINS);

    // Recompletion: the endpoint allows re-PATCHing an already-completed task
    // (task.service.ts sets status/completedAt/completedBy unconditionally);
    // the economy hook must not pay out a second time for it.
    await request(app).patch(completeUrl).set(authHeader(user.accessToken));
    expect(await getBalance(household.id)).toBe(TASK_COINS);
  });
});

describe('purchaseItem — coin granting hook', () => {
  async function shoppingUrl(household: TestHousehold): Promise<string> {
    return `/api/households/${household.id}/shopping`;
  }

  it('should grant PURCHASE_COINS on first purchase but not on a repeat purchase call', async () => {
    const { user, household } = await setupHousehold();
    const created = await request(app)
      .post(await shoppingUrl(household))
      .set(authHeader(user.accessToken))
      .send({ name: 'Leche' });

    const purchaseUrl = `${await shoppingUrl(household)}/${created.body.data.id}/purchase`;

    await request(app).patch(purchaseUrl).set(authHeader(user.accessToken));
    expect(await getBalance(household.id)).toBe(PURCHASE_COINS);

    await request(app).patch(purchaseUrl).set(authHeader(user.accessToken));
    expect(await getBalance(household.id)).toBe(PURCHASE_COINS);
  });
});

describe('GET /api/households/:householdId/economy', () => {
  it('should return balance, dailyEarned and recentTransactions for a member', async () => {
    const { user, household } = await setupHousehold();
    await grantCoins(household.id, TASK_COINS, 'task_complete', '507f1f77bcf86cd799439077');

    const res = await request(app)
      .get(`/api/households/${household.id}/economy`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.balance).toBe(TASK_COINS);
    expect(res.body.data.dailyEarned).toBe(TASK_COINS);
    expect(res.body.data.recentTransactions).toHaveLength(1);
    expect(res.body.data.recentTransactions[0].reason).toBe('task_complete');
    expect(res.body.data.recentTransactions[0].amount).toBe(TASK_COINS);
  });

  it('should return zeroes for a household with no ledger entries', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .get(`/api/households/${household.id}/economy`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.balance).toBe(0);
    expect(res.body.data.dailyEarned).toBe(0);
    expect(res.body.data.recentTransactions).toEqual([]);
  });

  it('should return 403 when the caller is not a member of the household', async () => {
    const { household } = await setupHousehold();
    const outsider = await createTestUser(app);

    const res = await request(app)
      .get(`/api/households/${household.id}/economy`)
      .set(authHeader(outsider.accessToken));

    expect(res.status).toBe(403);
  });

  it('should return 401 without a token', async () => {
    const { household } = await setupHousehold();

    const res = await request(app).get(`/api/households/${household.id}/economy`);

    expect(res.status).toBe(401);
  });
});

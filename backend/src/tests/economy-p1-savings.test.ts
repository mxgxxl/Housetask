import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import * as socketModule from '../config/socket';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { JointSavingsGoalModel } from '../models/JointSavingsGoal';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { SavingsContributionModel } from '../models/SavingsContribution';
import { InMemoryIdempotencyStore } from '../services/idempotency.store';
import { resetP1EnabledResolver, setP1EnabledResolver } from '../services/feature-flag.service';
import { COSMETICS } from '../config/economy';
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
 * The joint savings goal (TD-066 B10, PDR-018).
 *
 * Two things carry the most risk here and get the most attention.
 *
 * FIRST, money moves between a personal wallet and a shared total, so the two
 * must never disagree: a wallet debited without a contribution to show for it,
 * or a total claiming coins nobody paid, are both silent corruption. Every
 * path is asserted from BOTH sides — the ledger sum and the goal's counter.
 *
 * SECOND, the refund rides inside `removeMember`'s transaction, which is the
 * one that protects Hard Rule 9. `households.test.ts` is left untouched on
 * purpose: it passing unchanged is the evidence that the guard still holds.
 */
let app: Server;

const GLASSES = COSMETICS.find((c) => c.id === 'glasses')!; // 40 coins
const HAT = COSMETICS.find((c) => c.id === 'hat')!; // 20 coins

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

/** Put coins in a member's wallet without going through a completion. */
async function fund(userId: string, householdId: string, amount: number): Promise<void> {
  await PersonalCoinLedgerModel.create({
    userId: new Types.ObjectId(userId),
    householdId: new Types.ObjectId(householdId),
    amount,
    reason: 'legacy_balance',
    refType: 'legacy_migration',
    refId: `seed-${userId}-${amount}-${Date.now()}`,
    effectiveAt: new Date(),
  });
}

async function balanceOf(userId: string): Promise<number> {
  const [row] = await PersonalCoinLedgerModel.aggregate<{ total: number }>([
    { $match: { userId: new Types.ObjectId(userId) } },
    { $group: { _id: null, total: { $sum: '$amount' } } },
  ]);
  return row?.total ?? 0;
}

function createGoal(
  user: TestUser,
  householdId: string,
  key: string,
  itemId = GLASSES.id,
): request.Test {
  return request(app)
    .post(`/api/households/${householdId}/economy/p1/savings-goals`)
    .set(authHeader(user.accessToken))
    .set('Idempotency-Key', key)
    .send({ itemType: 'cosmetic', itemId });
}

function contribute(
  user: TestUser,
  householdId: string,
  goalId: string,
  amount: number,
  key: string,
): request.Test {
  return request(app)
    .post(`/api/households/${householdId}/economy/p1/savings-goals/${goalId}/contributions`)
    .set(authHeader(user.accessToken))
    .set('Idempotency-Key', key)
    .send({ amount });
}

function cancelGoal(user: TestUser, householdId: string, goalId: string): request.Test {
  return request(app)
    .post(`/api/households/${householdId}/economy/p1/savings-goals/${goalId}/cancel`)
    .set(authHeader(user.accessToken));
}

describe('creating a goal', () => {
  it('takes the price from the catalog, not from the request', async () => {
    // The security property: a client that could name its own target would
    // unlock a 40-coin cosmetic by declaring the target to be 1.
    enableP1();
    const { user, household } = await setup();

    const res = await request(app)
      .post(`/api/households/${household.id}/economy/p1/savings-goals`)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-goal-price')
      .send({ itemType: 'cosmetic', itemId: GLASSES.id, targetCoins: 1, targetAmount: 1 });

    expect(res.status).toBe(201);
    expect(res.body.data.goal.targetCoins).toBe(GLASSES.price);
    expect(res.body.data.goal.status).toBe('active');
    expect(res.body.data.goal.contributedCoins).toBe(0);
  });

  it('rejects an item that is not in the catalog', async () => {
    enableP1();
    const { user, household } = await setup();

    const res = await createGoal(user, household.id, 'op-goal-unknown', 'skin-dragon');
    expect(res.status).toBe(400);
    await expect(JointSavingsGoalModel.countDocuments({})).resolves.toBe(0);
  });

  it('allows only one active goal per household', async () => {
    enableP1();
    const { user, household } = await setup();

    const first = await createGoal(user, household.id, 'op-goal-1');
    const second = await createGoal(user, household.id, 'op-goal-2', HAT.id);

    expect(first.status).toBe(201);
    expect(second.status).toBe(409);
    await expect(JointSavingsGoalModel.countDocuments({ status: 'active' })).resolves.toBe(1);
  });

  it('emits household:savings_goal_created to the whole household', async () => {
    enableP1();
    const emitToHousehold = jest
      .spyOn(socketModule, 'emitToHousehold')
      .mockImplementation(() => undefined);
    const { user, household } = await setup();

    await createGoal(user, household.id, 'op-goal-evt');

    const events = emitToHousehold.mock.calls.filter(
      (c) => c[1] === 'household:savings_goal_created',
    );
    expect(events).toHaveLength(1);
    expect(events[0][0]).toBe(household.id);
  });
});

describe('contributing', () => {
  it('debits the wallet and raises the total atomically', async () => {
    enableP1();
    const { user, household } = await setup();
    await fund(user.id, household.id, 100);
    const goal = (await createGoal(user, household.id, 'op-c-goal')).body.data.goal;

    const res = await contribute(user, household.id, goal.id, 25, 'op-c-1');

    expect(res.status).toBe(200);
    expect(res.body.data.goal.contributedCoins).toBe(25);
    expect(res.body.data.wallet.balance).toBe(75);

    // Asserted from both sides: the ledger and the counter must agree.
    await expect(balanceOf(user.id)).resolves.toBe(75);
    const stored = await JointSavingsGoalModel.findById(goal.id);
    expect(stored?.contributedCoins).toBe(25);
    const contribution = await SavingsContributionModel.findOne({ goalId: goal.id });
    expect(contribution?.amount).toBe(25);
    expect(contribution?.status).toBe('active');
  });

  it('refuses an insufficient wallet with 403 and writes nothing', async () => {
    enableP1();
    const { user, household } = await setup();
    await fund(user.id, household.id, 10);
    const goal = (await createGoal(user, household.id, 'op-poor-goal')).body.data.goal;

    const res = await contribute(user, household.id, goal.id, 25, 'op-poor-1');

    expect(res.status).toBe(403);
    await expect(balanceOf(user.id)).resolves.toBe(10);
    await expect(SavingsContributionModel.countDocuments({})).resolves.toBe(0);
    const stored = await JointSavingsGoalModel.findById(goal.id);
    expect(stored?.contributedCoins).toBe(0);
  });

  it('unlocks the goal when the price is reached', async () => {
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);
    await fund(user.id, household.id, 100);
    await fund(mate.id, household.id, 100);

    const goal = (await createGoal(user, household.id, 'op-unlock-goal')).body.data.goal;
    await contribute(user, household.id, goal.id, GLASSES.price - 10, 'op-u-1');
    const last = await contribute(mate, household.id, goal.id, 10, 'op-u-2');

    expect(last.body.data.goal.status).toBe('unlocked');
    const stored = await JointSavingsGoalModel.findById(goal.id);
    expect(stored?.status).toBe('unlocked');
    expect(stored?.unlockedAt).toBeDefined();

    // Every contribution BOUGHT something, so none is refundable any more.
    const contributions = await SavingsContributionModel.find({ goalId: goal.id });
    expect(contributions.map((c) => c.status)).toEqual(['applied', 'applied']);
  });

  it('refuses a contribution to an unlocked goal', async () => {
    enableP1();
    const { user, household } = await setup();
    await fund(user.id, household.id, 200);
    const goal = (await createGoal(user, household.id, 'op-done-goal')).body.data.goal;
    await contribute(user, household.id, goal.id, GLASSES.price, 'op-d-1');

    const late = await contribute(user, household.id, goal.id, 5, 'op-d-2');
    expect(late.status).toBe(409);
  });

  it('does not contribute twice on a retried tap', async () => {
    enableP1();
    const { user, household } = await setup();
    await fund(user.id, household.id, 100);
    const goal = (await createGoal(user, household.id, 'op-retry-goal')).body.data.goal;

    const first = await contribute(user, household.id, goal.id, 15, 'op-retry-c');
    const second = await contribute(user, household.id, goal.id, 15, 'op-retry-c');

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(second.body).toEqual(first.body);
    await expect(balanceOf(user.id)).resolves.toBe(85);
    await expect(SavingsContributionModel.countDocuments({})).resolves.toBe(1);
  });

  it('emits the contribution to the household, since the breakdown is public', async () => {
    // UX-P1-SPEC §6 renders "Tú: 40 · Ana: 28" — unlike a wallet, who put in
    // what is meant to be visible.
    enableP1();
    const emitToHousehold = jest
      .spyOn(socketModule, 'emitToHousehold')
      .mockImplementation(() => undefined);
    const { user, household } = await setup();
    await fund(user.id, household.id, 100);
    const goal = (await createGoal(user, household.id, 'op-evt-goal')).body.data.goal;

    await contribute(user, household.id, goal.id, 12, 'op-evt-c');

    const events = emitToHousehold.mock.calls.filter(
      (c) => c[1] === 'household:savings_contribution',
    );
    expect(events).toHaveLength(1);
    expect(events[0][2]).toMatchObject({ userId: user.id, amount: 12, contributedCoins: 12 });
  });
});

describe('cancelling', () => {
  it('refunds every contributor and lowers the total to zero', async () => {
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);
    await fund(user.id, household.id, 100);
    await fund(mate.id, household.id, 100);

    const goal = (await createGoal(user, household.id, 'op-cancel-goal')).body.data.goal;
    await contribute(user, household.id, goal.id, 25, 'op-x-1');
    await contribute(mate, household.id, goal.id, 10, 'op-x-2');

    const res = await cancelGoal(user, household.id, goal.id);

    expect(res.status).toBe(200);
    expect(res.body.data.goal.status).toBe('cancelled');
    await expect(balanceOf(user.id)).resolves.toBe(100);
    await expect(balanceOf(mate.id)).resolves.toBe(100);

    const stored = await JointSavingsGoalModel.findById(goal.id);
    expect(stored?.contributedCoins).toBe(0);
    const contributions = await SavingsContributionModel.find({ goalId: goal.id });
    expect(contributions.every((c) => c.status === 'refunded')).toBe(true);
    expect(contributions.every((c) => c.refundedAt)).toBe(true);
  });

  it('lets a household admin cancel a goal they did not create', async () => {
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);
    const goal = (await createGoal(mate, household.id, 'op-admin-cancel')).body.data.goal;

    const res = await cancelGoal(user, household.id, goal.id);
    expect(res.status).toBe(200);
  });

  it('refuses a member who is neither the creator nor an admin', async () => {
    // The money belongs to everyone who put it in, so one contributor should
    // not be able to dissolve what the rest are still saving for.
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);
    const goal = (await createGoal(user, household.id, 'op-nope-cancel')).body.data.goal;

    const res = await cancelGoal(mate, household.id, goal.id);
    expect(res.status).toBe(403);
    const stored = await JointSavingsGoalModel.findById(goal.id);
    expect(stored?.status).toBe('active');
  });

  it('refuses to cancel an already-unlocked goal', async () => {
    // The item is already owned; refunding would be giving back money for
    // something delivered.
    enableP1();
    const { user, household } = await setup();
    await fund(user.id, household.id, 100);
    const goal = (await createGoal(user, household.id, 'op-unl-cancel')).body.data.goal;
    await contribute(user, household.id, goal.id, GLASSES.price, 'op-unl-c');

    const res = await cancelGoal(user, household.id, goal.id);
    expect(res.status).toBe(409);
    await expect(balanceOf(user.id)).resolves.toBe(100 - GLASSES.price);
  });

  it('frees the household to open a new goal afterwards', async () => {
    enableP1();
    const { user, household } = await setup();
    const goal = (await createGoal(user, household.id, 'op-reopen-1')).body.data.goal;
    await cancelGoal(user, household.id, goal.id);

    const again = await createGoal(user, household.id, 'op-reopen-2', HAT.id);
    expect(again.status).toBe(201);
  });
});

describe('a member leaving takes only their own coins back', () => {
  it('refunds the departing member and nobody else', async () => {
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);
    await fund(user.id, household.id, 100);
    await fund(mate.id, household.id, 100);

    const goal = (await createGoal(user, household.id, 'op-leave-goal')).body.data.goal;
    await contribute(user, household.id, goal.id, 25, 'op-l-1');
    await contribute(mate, household.id, goal.id, 10, 'op-l-2');

    const removed = await request(app)
      .delete(`/api/households/${household.id}/members/${mate.id}`)
      .set(authHeader(user.accessToken));

    expect(removed.status).toBe(200);

    // The departing member got their 10 back...
    await expect(balanceOf(mate.id)).resolves.toBe(100);
    // ...and the member who stayed did NOT get theirs.
    await expect(balanceOf(user.id)).resolves.toBe(75);

    const stored = await JointSavingsGoalModel.findById(goal.id);
    expect(stored?.contributedCoins).toBe(25);
    expect(stored?.status).toBe('active');

    const mine = await SavingsContributionModel.findOne({ userId: new Types.ObjectId(user.id) });
    expect(mine?.status).toBe('active');
    const theirs = await SavingsContributionModel.findOne({ userId: new Types.ObjectId(mate.id) });
    expect(theirs?.status).toBe('refunded');
  });

  it('removes the membership and the refund as one unit', async () => {
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);
    await fund(mate.id, household.id, 100);
    const goal = (await createGoal(user, household.id, 'op-atomic-goal')).body.data.goal;
    await contribute(mate, household.id, goal.id, 30, 'op-a-1');

    await request(app)
      .delete(`/api/households/${household.id}/members/${mate.id}`)
      .set(authHeader(user.accessToken));

    // Both halves landed: no membership, and the coins are back.
    await expect(
      HouseholdMemberModel.countDocuments({
        householdId: new Types.ObjectId(household.id),
        userId: new Types.ObjectId(mate.id),
      }),
    ).resolves.toBe(0);
    await expect(balanceOf(mate.id)).resolves.toBe(100);
  });

  it('rolls the whole removal back when the refund cannot be written', async () => {
    // The refund is NOT best-effort, unlike the task-unassign cleanup that
    // follows it. A removal that cannot return someone's coins must fail as a
    // unit rather than complete and lose them.
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);
    await fund(mate.id, household.id, 100);
    const goal = (await createGoal(user, household.id, 'op-rollback-goal')).body.data.goal;
    await contribute(mate, household.id, goal.id, 30, 'op-r-1');

    const spy = jest
      .spyOn(PersonalCoinLedgerModel, 'create')
      .mockRejectedValueOnce(new Error('ledger write failed'));

    const res = await request(app)
      .delete(`/api/households/${household.id}/members/${mate.id}`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(500);
    // Still a member, and the coins are still in the goal — nothing halfway.
    await expect(
      HouseholdMemberModel.countDocuments({
        householdId: new Types.ObjectId(household.id),
        userId: new Types.ObjectId(mate.id),
      }),
    ).resolves.toBe(1);
    await expect(balanceOf(mate.id)).resolves.toBe(70);
    const stored = await JointSavingsGoalModel.findById(goal.id);
    expect(stored?.contributedCoins).toBe(30);

    spy.mockRestore();
  });

  it('still removes a member who contributed nothing', async () => {
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);
    await createGoal(user, household.id, 'op-nocontrib-goal');

    const res = await request(app)
      .delete(`/api/households/${household.id}/members/${mate.id}`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
  });

  it('still protects the last admin (Hard Rule 9)', async () => {
    // The refund now runs inside the very transaction that enforces this, so
    // the guard is re-asserted here as well as in households.test.ts.
    enableP1();
    const { user, household } = await setup();
    await fund(user.id, household.id, 100);
    const goal = (await createGoal(user, household.id, 'op-hr9-goal')).body.data.goal;
    await contribute(user, household.id, goal.id, 20, 'op-hr9-c');

    const res = await request(app)
      .delete(`/api/households/${household.id}/members/${user.id}`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(400);
    // Refused before anything moved: the coins are still in the goal.
    await expect(balanceOf(user.id)).resolves.toBe(80);
    const stored = await JointSavingsGoalModel.findById(goal.id);
    expect(stored?.contributedCoins).toBe(20);
  });

  it('leaves a member with no P1 data removable while the flag is off', async () => {
    // The refund path runs unconditionally, not behind the flag: a household
    // that was migrated and then rolled back still owes its members their
    // coins. With no contributions there is simply nothing to refund.
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    const res = await request(app)
      .delete(`/api/households/${household.id}/members/${mate.id}`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
  });
});

describe('flag OFF and authorization', () => {
  it('refuses every savings write with 409 while P1 is disabled', async () => {
    const { user, household } = await setup();

    const created = await createGoal(user, household.id, 'op-off-goal');
    expect(created.status).toBe(409);
    await expect(JointSavingsGoalModel.countDocuments({})).resolves.toBe(0);
  });

  it('answers 403 to a non-member', async () => {
    enableP1();
    const { household } = await setup();
    const stranger = await createTestUser(app);

    const res = await createGoal(stranger, household.id, 'op-stranger-goal');
    expect(res.status).toBe(403);
  });

  it('rejects a malformed contribution', async () => {
    enableP1();
    const { user, household } = await setup();
    const goal = (await createGoal(user, household.id, 'op-bad-goal')).body.data.goal;

    await expect(
      contribute(user, household.id, goal.id, 0, 'op-bad-1').then((r) => r.status),
    ).resolves.toBe(400);
    await expect(
      contribute(user, household.id, goal.id, -5, 'op-bad-2').then((r) => r.status),
    ).resolves.toBe(400);
  });

  it('answers 404 for a goal in another household', async () => {
    enableP1();
    const { user, household } = await setup();
    const other = await createTestHousehold(app, user, 'Otra casa');
    const foreign = (await createGoal(user, other.id, 'op-foreign-goal')).body.data.goal;
    await fund(user.id, household.id, 100);

    const res = await contribute(user, household.id, foreign.id, 5, 'op-foreign-c');
    expect(res.status).toBe(404);
  });
});

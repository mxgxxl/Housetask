import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { EconomyLedgerModel } from '../models/EconomyLedger';
import { HouseholdModel } from '../models/Household';
import { HouseholdDestructionModel } from '../models/HouseholdDestruction';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { JointSavingsGoalModel } from '../models/JointSavingsGoal';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { SavingsContributionModel } from '../models/SavingsContribution';
import { ShoppingItemModel } from '../models/ShoppingItem';
import { TaskModel } from '../models/Task';
import { UserProgressModel } from '../models/UserProgress';
import { InMemoryIdempotencyStore } from '../services/idempotency.store';
import { resetP1EnabledResolver, setP1EnabledResolver } from '../services/feature-flag.service';
import {
  DESTRUCTION_GRACE_PERIOD_MS,
  destroyExpiredHouseholds,
} from '../services/household-destruction.service';
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
 * Household destruction with a grace period (TD-067, PDR-022 D4).
 *
 * Three properties carry the risk, and each has its own block below.
 *
 * FIRST, only the creator can reach any of it, and the deadline is not
 * negotiable from the client side. Destruction is the one operation in PDR-022
 * with no manual undo, so the grace period is the undo — and a confirm that
 * ignored `scheduledAt` would quietly delete it.
 *
 * SECOND, the cascade takes everything the household owns and nothing that
 * belongs to a person. PDR-017 makes personal XP, level and wallet portable on
 * purpose; a household ending must not be able to take them, and the joint
 * savings goal — household-owned but holding personal money — must be refunded
 * before the memberships that identify its contributors are deleted
 * (Hard Rule 16b).
 *
 * THIRD, a destroyed household is unreachable AND its invite code is not
 * recycled. The soft delete exists for the second half: a hard delete would
 * return an eight-character code to the pool, and a code still sitting in
 * someone's chat would one day resolve to a stranger's household.
 */
let app: Server;

const GLASSES = COSMETICS.find((c) => c.id === 'glasses')!; // 40 coins

beforeAll(async () => {
  app = await buildTestApp({ idempotencyStore: new InMemoryIdempotencyStore() });
});

afterEach(() => {
  resetP1EnabledResolver();
});

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

async function household(memberCount = 0): Promise<{
  creator: TestUser;
  members: TestUser[];
  hh: TestHousehold;
}> {
  const creator = await createTestUser(app);
  const hh = await createTestHousehold(app, creator);
  const members: TestUser[] = [];
  for (let i = 0; i < memberCount; i++) {
    const user = await createTestUser(app);
    await joinTestHousehold(app, user, hh.inviteCode);
    members.push(user);
  }
  return { creator, members, hh };
}

let keySeq = 0;
function schedule(actor: TestUser, hh: TestHousehold): request.Test {
  keySeq += 1;
  return request(app)
    .post(`/api/households/${hh.id}/schedule-destruction`)
    .set(authHeader(actor.accessToken))
    .set('Idempotency-Key', `destroy-${Date.now()}-${keySeq}`)
    .send({});
}

function cancel(actor: TestUser, hh: TestHousehold): request.Test {
  return request(app)
    .post(`/api/households/${hh.id}/cancel-destruction`)
    .set(authHeader(actor.accessToken))
    .send({});
}

function confirm(actor: TestUser, hh: TestHousehold): request.Test {
  return request(app)
    .post(`/api/households/${hh.id}/confirm-destruction`)
    .set(authHeader(actor.accessToken))
    .send({});
}

function status(actor: TestUser, hh: TestHousehold): request.Test {
  return request(app)
    .get(`/api/households/${hh.id}/destruction-status`)
    .set(authHeader(actor.accessToken));
}

/**
 * Move a pending destruction's deadline into the past.
 *
 * Faking the clock instead would mean faking it for Mongo's own writes too;
 * moving the one date the check reads is smaller, and it is exactly what the
 * passage of 24 hours would have done.
 */
async function expireGracePeriod(householdId: string): Promise<void> {
  await HouseholdDestructionModel.updateOne(
    { householdId: new Types.ObjectId(householdId) },
    { $set: { scheduledAt: new Date(Date.now() - 1000) } },
  );
}

// ---------------------------------------------------------------------------
// Authorization and the deadline
// ---------------------------------------------------------------------------

describe('scheduling and cancelling — PDR-022 D4', () => {
  it('lets the creator schedule a destruction 24 hours out', async () => {
    const { creator, hh } = await household();
    const before = Date.now();

    const res = await schedule(creator, hh);

    expect(res.status).toBe(200);
    const scheduledAt = new Date(res.body.data.scheduledAt).getTime();
    expect(scheduledAt).toBeGreaterThanOrEqual(before + DESTRUCTION_GRACE_PERIOD_MS - 5000);
    expect(scheduledAt).toBeLessThanOrEqual(Date.now() + DESTRUCTION_GRACE_PERIOD_MS + 5000);
    // Nothing has been destroyed yet — that is the whole point of the period.
    const hhDoc = await HouseholdModel.findById(hh.id);
    expect(hhDoc!.isDeleted).toBe(false);
  });

  it('returns 403 when an admin who is not the creator schedules', async () => {
    const { creator, members, hh } = await household(1);
    await request(app)
      .patch(`/api/households/${hh.id}/members/${members[0].id}/promote`)
      .set(authHeader(creator.accessToken));

    const res = await schedule(members[0], hh);

    expect(res.status).toBe(403);
    expect(res.body.error).toBe('Only the household creator can delete this household');
    await expect(
      HouseholdDestructionModel.countDocuments({ householdId: new Types.ObjectId(hh.id) }),
    ).resolves.toBe(0);
  });

  it('returns 403 when a plain member schedules, cancels or confirms', async () => {
    const { creator, members, hh } = await household(1);
    await schedule(creator, hh);
    await expireGracePeriod(hh.id);

    await expect(schedule(members[0], hh)).resolves.toMatchObject({ status: 403 });
    await expect(cancel(members[0], hh)).resolves.toMatchObject({ status: 403 });
    await expect(confirm(members[0], hh)).resolves.toMatchObject({ status: 403 });
    // And it is still scheduled, not cancelled by the attempt.
    await expect(
      HouseholdDestructionModel.countDocuments({ householdId: new Types.ObjectId(hh.id) }),
    ).resolves.toBe(1);
  });

  it('returns 403 when a non-member tries anything', async () => {
    const { hh } = await household();
    const outsider = await createTestUser(app);

    // requireMembership answers before the creator check is reached, so an
    // outsider cannot even learn that the household exists.
    await expect(schedule(outsider, hh)).resolves.toMatchObject({ status: 403 });
    await expect(status(outsider, hh)).resolves.toMatchObject({ status: 403 });
  });

  it('is idempotent: a second schedule returns the FIRST deadline', async () => {
    // The one person allowed to do this may well tap it on two devices. A
    // second deadline would be a second row that a later cancel only half
    // removes.
    const { creator, hh } = await household();

    const first = await schedule(creator, hh);
    const second = await schedule(creator, hh);

    expect(second.status).toBe(200);
    expect(second.body.data.scheduledAt).toBe(first.body.data.scheduledAt);
    await expect(
      HouseholdDestructionModel.countDocuments({ householdId: new Types.ObjectId(hh.id) }),
    ).resolves.toBe(1);
  });

  it('lets the creator cancel, which leaves nothing behind to undo', async () => {
    const { creator, hh } = await household();
    await schedule(creator, hh);

    const res = await cancel(creator, hh);

    expect(res.status).toBe(200);
    await expect(
      HouseholdDestructionModel.countDocuments({ householdId: new Types.ObjectId(hh.id) }),
    ).resolves.toBe(0);
    const hhDoc = await HouseholdModel.findById(hh.id);
    expect(hhDoc!.isDeleted).toBe(false);
  });

  it('returns 404 when cancelling a household that was never scheduled', async () => {
    const { creator, hh } = await household();

    const res = await cancel(creator, hh);

    expect(res.status).toBe(404);
  });

  it('exposes the pending deletion to every member, not only the creator', async () => {
    // Only the creator can schedule one, but everyone living in the household
    // is entitled to know their home is about to disappear.
    const { creator, members, hh } = await household(1);

    const before = await status(members[0], hh);
    expect(before.status).toBe(200);
    expect(before.body.data.scheduled).toBe(false);
    expect(before.body.data.scheduledAt).toBeNull();

    await schedule(creator, hh);

    const after = await status(members[0], hh);
    expect(after.body.data.scheduled).toBe(true);
    expect(after.body.data.scheduledBy).toBe(creator.id);
    expect(new Date(after.body.data.scheduledAt).getTime()).toBeGreaterThan(Date.now());
  });
});

describe('the deadline is not negotiable — PDR-022 D4', () => {
  it('returns 400 when confirming before the grace period expires', async () => {
    const { creator, hh } = await household();
    await schedule(creator, hh);

    const res = await confirm(creator, hh);

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('grace period has not expired');
    const hhDoc = await HouseholdModel.findById(hh.id);
    expect(hhDoc!.isDeleted).toBe(false);
    await expect(
      HouseholdMemberModel.countDocuments({ householdId: new Types.ObjectId(hh.id) }),
    ).resolves.toBe(1);
  });

  it('returns 400 when confirming a household that was never scheduled', async () => {
    // Confirming without scheduling would BE the un-undoable action the grace
    // period exists to prevent.
    const { creator, hh } = await household();

    const res = await confirm(creator, hh);

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('This household is not scheduled for deletion');
  });

  it('a cancel before the deadline annuls the destruction for good', async () => {
    const { creator, hh } = await household();
    await schedule(creator, hh);
    await cancel(creator, hh);
    // Even once the original deadline would have passed, there is no row left
    // for either the endpoint or the job to act on.
    await expect(confirm(creator, hh)).resolves.toMatchObject({ status: 400 });
    await expect(destroyExpiredHouseholds()).resolves.toBe(0);

    const hhDoc = await HouseholdModel.findById(hh.id);
    expect(hhDoc!.isDeleted).toBe(false);
    await expect(
      HouseholdMemberModel.countDocuments({ householdId: new Types.ObjectId(hh.id) }),
    ).resolves.toBe(1);
  });
});

// ---------------------------------------------------------------------------
// The cascade
// ---------------------------------------------------------------------------

describe('the cascade — what dies with the household and what does not', () => {
  /** A household with one task, one shopping item and a Fase A ledger entry. */
  async function populated(): Promise<{
    creator: TestUser;
    members: TestUser[];
    hh: TestHousehold;
    taskId: string;
  }> {
    const { creator, members, hh } = await household(1);

    const task = await request(app)
      .post(`/api/households/${hh.id}/tasks`)
      .set(authHeader(creator.accessToken))
      .set('Idempotency-Key', `destroy-task-${Date.now()}-${Math.random()}`)
      .send({ title: 'Fregar' });
    expect(task.status).toBe(201);

    const item = await request(app)
      .post(`/api/households/${hh.id}/shopping`)
      .set(authHeader(creator.accessToken))
      .set('Idempotency-Key', `destroy-item-${Date.now()}-${Math.random()}`)
      .send({ name: 'Leche' });
    expect(item.status).toBe(201);

    await EconomyLedgerModel.create({
      householdId: new Types.ObjectId(hh.id),
      amount: 10,
      reason: 'task_complete',
      refId: `seed-${Date.now()}`,
    });

    return { creator, members, hh, taskId: task.body.data.id };
  }

  it('removes every household-owned resource and cuts all access', async () => {
    const { creator, members, hh, taskId } = await populated();
    await schedule(creator, hh);
    await expireGracePeriod(hh.id);

    const res = await confirm(creator, hh);
    expect(res.status).toBe(200);

    const householdObjectId = new Types.ObjectId(hh.id);
    // The household survives as a row, marked gone...
    const hhDoc = await HouseholdModel.findById(hh.id);
    expect(hhDoc!.isDeleted).toBe(true);
    expect(hhDoc!.deletedAt).toBeInstanceOf(Date);
    // ...its memberships do not, which is what actually cuts access...
    await expect(
      HouseholdMemberModel.countDocuments({ householdId: householdObjectId }),
    ).resolves.toBe(0);
    // ...shopping and the shared ledger are gone...
    await expect(
      ShoppingItemModel.countDocuments({ householdId: householdObjectId }),
    ).resolves.toBe(0);
    await expect(
      EconomyLedgerModel.countDocuments({ householdId: householdObjectId }),
    ).resolves.toBe(0);
    // ...and tasks are soft-deleted, staying consistent with PDR-006 so the
    // existing retention job reclaims them on its own schedule.
    const task = await TaskModel.findById(taskId);
    expect(task!.isDeleted).toBe(true);
    // The pending destruction row is consumed by the destruction it caused.
    await expect(
      HouseholdDestructionModel.countDocuments({ householdId: householdObjectId }),
    ).resolves.toBe(0);

    // Every member, creator included, is locked out.
    for (const user of [creator, ...members]) {
      const get = await request(app)
        .get(`/api/households/${hh.id}`)
        .set(authHeader(user.accessToken));
      expect(get.status).toBe(404);
    }
  });

  it('does not recycle the invite code', async () => {
    // The specific reason destruction is a soft delete: a hard delete frees a
    // unique code, and a code still sitting in someone's chat would one day
    // resolve to a stranger's household.
    const { creator, hh } = await populated();
    await schedule(creator, hh);
    await expireGracePeriod(hh.id);
    await confirm(creator, hh);

    const newcomer = await createTestUser(app);
    const res = await request(app)
      .post('/api/households/join')
      .set(authHeader(newcomer.accessToken))
      .set('Idempotency-Key', `destroy-join-${Date.now()}`)
      .send({ inviteCode: hh.inviteCode });

    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Invalid invite code');
    // And the row still holds the code, so it can never be minted again.
    const hhDoc = await HouseholdModel.findById(hh.id);
    expect(hhDoc!.inviteCode).toBe(hh.inviteCode);
  });

  it('refunds the joint savings goal before the memberships go (Hard Rule 16b)', async () => {
    setP1EnabledResolver(async () => true);
    const { creator, members, hh } = await household(1);

    for (const user of [creator, members[0]]) {
      await PersonalCoinLedgerModel.create({
        userId: new Types.ObjectId(user.id),
        householdId: new Types.ObjectId(hh.id),
        amount: 30,
        reason: 'legacy_balance',
        refType: 'legacy_migration',
        refId: `destroy-seed-${user.id}-${Date.now()}`,
        effectiveAt: new Date(),
      });
    }

    const goal = await request(app)
      .post(`/api/households/${hh.id}/economy/p1/savings-goals`)
      .set(authHeader(creator.accessToken))
      .set('Idempotency-Key', `destroy-goal-${Date.now()}`)
      .send({ itemType: 'cosmetic', itemId: GLASSES.id });
    const goalId = goal.body.data.goal.id;

    for (const user of [creator, members[0]]) {
      const contribution = await request(app)
        .post(`/api/households/${hh.id}/economy/p1/savings-goals/${goalId}/contributions`)
        .set(authHeader(user.accessToken))
        .set('Idempotency-Key', `destroy-contrib-${user.id}-${Date.now()}`)
        .send({ amount: 12 });
      expect(contribution.status).toBe(200);
    }

    await schedule(creator, hh);
    await expireGracePeriod(hh.id);
    const res = await confirm(creator, hh);
    expect(res.status).toBe(200);

    // Both contributors got every coin back...
    for (const user of [creator, members[0]]) {
      const [row] = await PersonalCoinLedgerModel.aggregate<{ total: number }>([
        { $match: { userId: new Types.ObjectId(user.id) } },
        { $group: { _id: null, total: { $sum: '$amount' } } },
      ]);
      expect(row.total).toBe(30);
    }
    // ...the contributions are marked refunded rather than silently dropped...
    const contributions = await SavingsContributionModel.find({ goalId });
    expect(contributions).toHaveLength(2);
    expect(contributions.every((c) => c.status === 'refunded')).toBe(true);
    // ...and the goal itself is cancelled, not left active on a dead household.
    const stored = await JointSavingsGoalModel.findById(goalId);
    expect(stored!.status).toBe('cancelled');
  });

  it('leaves personal, portable progress untouched (PDR-017)', async () => {
    // The other half of the line the cascade draws: household-owned dies,
    // user-owned travels with the person to whatever household comes next.
    setP1EnabledResolver(async () => true);
    const { creator, hh } = await household();

    await UserProgressModel.create({
      userId: new Types.ObjectId(creator.id),
      xp: 250,
      level: 3,
      tasksCompleted: 7,
    });
    await PersonalCoinLedgerModel.create({
      userId: new Types.ObjectId(creator.id),
      householdId: new Types.ObjectId(hh.id),
      amount: 55,
      reason: 'legacy_balance',
      refType: 'legacy_migration',
      refId: `destroy-portable-${Date.now()}`,
      effectiveAt: new Date(),
    });

    await schedule(creator, hh);
    await expireGracePeriod(hh.id);
    await confirm(creator, hh);

    const progress = await UserProgressModel.findOne({
      userId: new Types.ObjectId(creator.id),
    });
    expect(progress!.xp).toBe(250);
    expect(progress!.level).toBe(3);
    expect(progress!.tasksCompleted).toBe(7);

    const [wallet] = await PersonalCoinLedgerModel.aggregate<{ total: number }>([
      { $match: { userId: new Types.ObjectId(creator.id) } },
      { $group: { _id: null, total: { $sum: '$amount' } } },
    ]);
    expect(wallet.total).toBe(55);
  });

  it('does not touch a different household', async () => {
    // The cascade is scoped by householdId in every collection it reaches; a
    // deleteMany with a forgotten filter is exactly the failure worth pinning.
    const { creator: victimCreator, hh: victim } = await populated();
    const { creator: survivorCreator, hh: survivor, taskId: survivorTask } = await populated();

    await schedule(victimCreator, victim);
    await expireGracePeriod(victim.id);
    await confirm(victimCreator, victim);

    const survivorDoc = await HouseholdModel.findById(survivor.id);
    expect(survivorDoc!.isDeleted).toBe(false);
    await expect(
      HouseholdMemberModel.countDocuments({ householdId: new Types.ObjectId(survivor.id) }),
    ).resolves.toBe(2);
    await expect(
      ShoppingItemModel.countDocuments({ householdId: new Types.ObjectId(survivor.id) }),
    ).resolves.toBe(1);
    const task = await TaskModel.findById(survivorTask);
    expect(task!.isDeleted).toBe(false);
    const get = await request(app)
      .get(`/api/households/${survivor.id}`)
      .set(authHeader(survivorCreator.accessToken));
    expect(get.status).toBe(200);
  });

  it('answers 404 to every household-scoped route afterwards, not 403', async () => {
    // A destroyed household does not exist as far as the API is concerned.
    // "You are not a member" would be true but misleading, and would leave the
    // client unable to tell "removed" from "gone".
    const { creator, hh } = await populated();
    await schedule(creator, hh);
    await expireGracePeriod(hh.id);
    await confirm(creator, hh);

    const auth = authHeader(creator.accessToken);
    for (const path of [
      `/api/households/${hh.id}`,
      `/api/households/${hh.id}/members`,
      `/api/households/${hh.id}/stats`,
      `/api/households/${hh.id}/tasks`,
      `/api/households/${hh.id}/destruction-status`,
    ]) {
      const res = await request(app).get(path).set(auth);
      expect(res.status).toBe(404);
    }
  });

  it('cannot be destroyed twice', async () => {
    const { creator, hh } = await populated();
    await schedule(creator, hh);
    await expireGracePeriod(hh.id);
    await confirm(creator, hh);

    const second = await confirm(creator, hh);

    // Not a member of anything any more, and the household is gone.
    expect(second.status).toBe(404);
  });

  it('cannot be scheduled or governed once destroyed', async () => {
    const { creator, members, hh } = await populated();
    await schedule(creator, hh);
    await expireGracePeriod(hh.id);
    await confirm(creator, hh);

    await expect(schedule(creator, hh)).resolves.toMatchObject({ status: 404 });
    await expect(
      request(app)
        .post(`/api/households/${hh.id}/leave`)
        .set(authHeader(members[0].accessToken)),
    ).resolves.toMatchObject({ status: 404 });
    await expect(
      request(app)
        .patch(`/api/households/${hh.id}/members/${members[0].id}/promote`)
        .set(authHeader(creator.accessToken)),
    ).resolves.toMatchObject({ status: 404 });
  });
});

// ---------------------------------------------------------------------------
// The scheduled job
// ---------------------------------------------------------------------------

describe('the scheduled job — destroyExpiredHouseholds', () => {
  it('destroys only households whose grace period has expired', async () => {
    const { creator: dueCreator, hh: due } = await household();
    const { creator: waitingCreator, hh: waiting } = await household();

    await schedule(dueCreator, due);
    await schedule(waitingCreator, waiting);
    await expireGracePeriod(due.id);

    const destroyed = await destroyExpiredHouseholds();

    expect(destroyed).toBe(1);
    expect((await HouseholdModel.findById(due.id))!.isDeleted).toBe(true);
    expect((await HouseholdModel.findById(waiting.id))!.isDeleted).toBe(false);
    // The waiting one keeps its deadline; the job did not consume it.
    await expect(
      HouseholdDestructionModel.countDocuments({ householdId: new Types.ObjectId(waiting.id) }),
    ).resolves.toBe(1);
  });

  it('cascades exactly like the endpoint does', async () => {
    // The two share `destroyInTransaction` precisely so they cannot diverge;
    // this is what would fail if someone re-implemented one of them.
    const { creator, hh } = await household(1);
    await request(app)
      .post(`/api/households/${hh.id}/shopping`)
      .set(authHeader(creator.accessToken))
      .set('Idempotency-Key', `job-item-${Date.now()}`)
      .send({ name: 'Pan' });

    await schedule(creator, hh);
    await expireGracePeriod(hh.id);
    await destroyExpiredHouseholds();

    const householdObjectId = new Types.ObjectId(hh.id);
    expect((await HouseholdModel.findById(hh.id))!.isDeleted).toBe(true);
    await expect(
      HouseholdMemberModel.countDocuments({ householdId: householdObjectId }),
    ).resolves.toBe(0);
    await expect(
      ShoppingItemModel.countDocuments({ householdId: householdObjectId }),
    ).resolves.toBe(0);
  });

  it('is safe to run when nothing is due', async () => {
    await expect(destroyExpiredHouseholds()).resolves.toBe(0);
  });

  it('is idempotent across runs', async () => {
    const { creator, hh } = await household();
    await schedule(creator, hh);
    await expireGracePeriod(hh.id);

    await expect(destroyExpiredHouseholds()).resolves.toBe(1);
    // The row was consumed, so a second run finds nothing left to do rather
    // than trying to destroy an already-destroyed household.
    await expect(destroyExpiredHouseholds()).resolves.toBe(0);
  });
});

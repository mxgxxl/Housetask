import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { HouseholdModel } from '../models/Household';
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
 * Household governance: roles, ownership transfer and voluntary exit
 * (TD-067, PDR-022 D1–D3).
 *
 * Two invariants are what this suite really exists to defend, and they are
 * asserted after every path that could break them rather than only in the
 * tests named after them:
 *
 *   Hard Rule 9  — a household that still has members always has an admin.
 *                  D3 changed HOW that is upheld on exit (promote the most
 *                  senior member instead of refusing to let anyone leave), so
 *                  the rule now has to survive a code path that deliberately
 *                  removes an admin.
 *   Hard Rule 16b — no exit path may strand a member's savings contributions.
 *                  `removeMember` already had this; `leaveHousehold` is a
 *                  SECOND door out of a household, and a rule that only one
 *                  door honours is not a rule.
 *
 * PDR-022 also turned `createdBy` from a historical field into a live
 * permission, which is the other thing under test: who may change it, who may
 * not be demoted or removed, and who inherits it when its holder walks out.
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

/**
 * A household whose members joined in a KNOWN order, which matters because
 * every succession in PDR-022 is decided by seniority. `joinTestHousehold` is
 * awaited one at a time on purpose: joining in parallel would leave the
 * `joinedAt` order up to the scheduler, and a test asserting "the oldest
 * member inherits" would then pass or fail at random.
 */
async function household(memberCount: number): Promise<{
  creator: TestUser;
  members: TestUser[];
  household: TestHousehold;
}> {
  const creator = await createTestUser(app);
  const hh = await createTestHousehold(app, creator);
  const members: TestUser[] = [];
  for (let i = 0; i < memberCount; i++) {
    const user = await createTestUser(app);
    await joinTestHousehold(app, user, hh.inviteCode);
    members.push(user);
  }
  return { creator, members, household: hh };
}

function promote(actor: TestUser, hh: TestHousehold, targetId: string): request.Test {
  return request(app)
    .patch(`/api/households/${hh.id}/members/${targetId}/promote`)
    .set(authHeader(actor.accessToken));
}

function demote(actor: TestUser, hh: TestHousehold, targetId: string): request.Test {
  return request(app)
    .patch(`/api/households/${hh.id}/members/${targetId}/demote`)
    .set(authHeader(actor.accessToken));
}

function transfer(actor: TestUser, hh: TestHousehold, targetId: string): request.Test {
  return request(app)
    .post(`/api/households/${hh.id}/transfer-ownership`)
    .set(authHeader(actor.accessToken))
    .send({ userId: targetId });
}

function leave(actor: TestUser, hh: TestHousehold): request.Test {
  return request(app)
    .post(`/api/households/${hh.id}/leave`)
    .set(authHeader(actor.accessToken));
}

async function roleOf(householdId: string, userId: string): Promise<string | null> {
  const row = await HouseholdMemberModel.findOne({
    householdId: new Types.ObjectId(householdId),
    userId: new Types.ObjectId(userId),
  });
  return row?.role ?? null;
}

async function ownerOf(householdId: string): Promise<string> {
  const hh = await HouseholdModel.findById(householdId);
  return hh!.createdBy.toString();
}

/**
 * Hard Rule 9, asserted straight from the database rather than from a
 * response body: the rule is about stored state, and an endpoint that answered
 * 200 while leaving zero admins behind is exactly the failure worth catching.
 */
async function expectStillHasAdmin(householdId: string): Promise<void> {
  const admins = await HouseholdMemberModel.countDocuments({
    householdId: new Types.ObjectId(householdId),
    role: 'admin',
  });
  expect(admins).toBeGreaterThanOrEqual(1);
}

// ---------------------------------------------------------------------------
// D1 — only the creator manages roles
// ---------------------------------------------------------------------------

describe('PATCH /:id/members/:userId/promote — PDR-022 D1', () => {
  it('lets the creator promote a member to admin', async () => {
    const { creator, members, household: hh } = await household(1);

    const res = await promote(creator, hh, members[0].id);

    expect(res.status).toBe(200);
    await expect(roleOf(hh.id, members[0].id)).resolves.toBe('admin');
    const promoted = res.body.data.members.find(
      (m: { user: { id: string } }) => m.user.id === members[0].id,
    );
    expect(promoted.role).toBe('admin');
  });

  it('returns 403 when a non-creator ADMIN tries to promote', async () => {
    // The whole point of D1: admin is not the same authority as owner. This is
    // the case a symmetric-admins model would have allowed.
    const { creator, members, household: hh } = await household(2);
    await promote(creator, hh, members[0].id); // members[0] is now an admin

    const res = await promote(members[0], hh, members[1].id);

    expect(res.status).toBe(403);
    expect(res.body.error).toBe('Only the household creator can perform this action');
    await expect(roleOf(hh.id, members[1].id)).resolves.toBe('member');
  });

  it('returns 403 when a plain member tries to promote themselves', async () => {
    const { members, household: hh } = await household(1);

    const res = await promote(members[0], hh, members[0].id);

    expect(res.status).toBe(403);
    await expect(roleOf(hh.id, members[0].id)).resolves.toBe('member');
  });

  it('returns 403 when the caller is not a member at all', async () => {
    const { members, household: hh } = await household(1);
    const outsider = await createTestUser(app);

    const res = await promote(outsider, hh, members[0].id);

    // requireMembership answers first, before the creator check is reached.
    expect(res.status).toBe(403);
    expect(res.body.error).toBe('You are not a member of this household');
  });

  it('returns 404 for a user who is not a member of this household', async () => {
    const { creator, household: hh } = await household(1);
    const stranger = await createTestUser(app);

    const res = await promote(creator, hh, stranger.id);

    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Target user is not a member of this household');
  });

  it('returns 404 rather than 500 for a malformed user id', async () => {
    // `new Types.ObjectId('not-an-id')` throws a BSONError, which without the
    // guard surfaces as a 500 — a server fault reported for a client mistake.
    const { creator, household: hh } = await household(1);

    const res = await promote(creator, hh, 'not-an-object-id');

    expect(res.status).toBe(404);
  });

  it('is idempotent: promoting an existing admin succeeds and changes nothing', async () => {
    const { creator, members, household: hh } = await household(1);
    await promote(creator, hh, members[0].id);

    const res = await promote(creator, hh, members[0].id);

    expect(res.status).toBe(200);
    await expect(roleOf(hh.id, members[0].id)).resolves.toBe('admin');
  });
});

describe('PATCH /:id/members/:userId/demote — PDR-022 D1', () => {
  it('lets the creator demote an admin back to member', async () => {
    const { creator, members, household: hh } = await household(1);
    await promote(creator, hh, members[0].id);

    const res = await demote(creator, hh, members[0].id);

    expect(res.status).toBe(200);
    await expect(roleOf(hh.id, members[0].id)).resolves.toBe('member');
    await expectStillHasAdmin(hh.id);
  });

  it('returns 403 when the creator tries to demote THEMSELVES', async () => {
    // D1 is explicit that the creator is indegradable. Without this, a creator
    // could strip the household of the only authority able to manage roles —
    // and, unlike every other role change, nobody could undo it.
    const { creator, members, household: hh } = await household(1);
    await promote(creator, hh, members[0].id); // another admin exists, so
    // Hard Rule 9 is NOT what is doing the rejecting here.

    const res = await demote(creator, hh, creator.id);

    expect(res.status).toBe(403);
    expect(res.body.error).toBe('The household creator cannot be demoted');
    await expect(roleOf(hh.id, creator.id)).resolves.toBe('admin');
  });

  it('returns 403 when another admin tries to demote the creator', async () => {
    const { creator, members, household: hh } = await household(1);
    await promote(creator, hh, members[0].id);

    const res = await demote(members[0], hh, creator.id);

    // Rejected as "not the creator" before the target is even considered.
    expect(res.status).toBe(403);
    await expect(roleOf(hh.id, creator.id)).resolves.toBe('admin');
    await expect(ownerOf(hh.id)).resolves.toBe(creator.id);
  });

  it('returns 403 when a non-creator admin tries to demote another admin', async () => {
    const { creator, members, household: hh } = await household(2);
    await promote(creator, hh, members[0].id);
    await promote(creator, hh, members[1].id);

    const res = await demote(members[0], hh, members[1].id);

    expect(res.status).toBe(403);
    await expect(roleOf(hh.id, members[1].id)).resolves.toBe('admin');
  });

  it('is idempotent: demoting an existing member succeeds and changes nothing', async () => {
    const { creator, members, household: hh } = await household(1);

    const res = await demote(creator, hh, members[0].id);

    expect(res.status).toBe(200);
    await expect(roleOf(hh.id, members[0].id)).resolves.toBe('member');
  });
});

// ---------------------------------------------------------------------------
// D2 — ownership transfer
// ---------------------------------------------------------------------------

describe('POST /:id/transfer-ownership — PDR-022 D2', () => {
  it('moves createdBy and keeps the outgoing creator in the household as admin', async () => {
    // Transfer moves responsibility, not membership. The outgoing creator
    // staying `admin` (not `member`) is the specific claim.
    const { creator, members, household: hh } = await household(1);
    await promote(creator, hh, members[0].id);

    const res = await transfer(creator, hh, members[0].id);

    expect(res.status).toBe(200);
    expect(res.body.data.createdBy).toBe(members[0].id);
    await expect(ownerOf(hh.id)).resolves.toBe(members[0].id);
    await expect(roleOf(hh.id, creator.id)).resolves.toBe('admin');
    await expect(roleOf(hh.id, members[0].id)).resolves.toBe('admin');
  });

  it('hands the new owner D1 authority, and takes it from the old one', async () => {
    // The transfer is only meaningful if the permission actually travels.
    const { creator, members, household: hh } = await household(2);
    await promote(creator, hh, members[0].id);
    await transfer(creator, hh, members[0].id);

    await expect(promote(creator, hh, members[1].id)).resolves.toMatchObject({ status: 403 });
    await expect(promote(members[0], hh, members[1].id)).resolves.toMatchObject({ status: 200 });
  });

  it('returns 400 when the receiver is a plain member, not an admin', async () => {
    // Ownership carries the power to promote, so it may not be handed to
    // someone the creator never decided could administer anything.
    const { creator, members, household: hh } = await household(1);

    const res = await transfer(creator, hh, members[0].id);

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Ownership can only be transferred to an admin');
    await expect(ownerOf(hh.id)).resolves.toBe(creator.id);
  });

  it('returns 403 when a non-creator admin tries to transfer', async () => {
    const { creator, members, household: hh } = await household(2);
    await promote(creator, hh, members[0].id);
    await promote(creator, hh, members[1].id);

    const res = await transfer(members[0], hh, members[1].id);

    expect(res.status).toBe(403);
    await expect(ownerOf(hh.id)).resolves.toBe(creator.id);
  });

  it('returns 400 when the creator transfers to themselves', async () => {
    const { creator, household: hh } = await household(1);

    const res = await transfer(creator, hh, creator.id);

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('You already own this household');
  });

  it('returns 404 for a receiver outside the household', async () => {
    const { creator, household: hh } = await household(1);
    const stranger = await createTestUser(app);

    const res = await transfer(creator, hh, stranger.id);

    expect(res.status).toBe(404);
    await expect(ownerOf(hh.id)).resolves.toBe(creator.id);
  });

  it('returns 400 when the body has no userId', async () => {
    const { creator, household: hh } = await household(1);

    const res = await request(app)
      .post(`/api/households/${hh.id}/transfer-ownership`)
      .set(authHeader(creator.accessToken))
      .send({});

    expect(res.status).toBe(400);
  });
});

// ---------------------------------------------------------------------------
// D3 — voluntary exit
// ---------------------------------------------------------------------------

describe('POST /:id/leave — PDR-022 D3', () => {
  it('lets a plain member leave without disturbing anyone else', async () => {
    const { creator, members, household: hh } = await household(2);

    const res = await leave(members[0], hh);

    expect(res.status).toBe(200);
    expect(res.body.data.left).toBe(true);
    expect(res.body.data.promotedUserId).toBeNull();
    expect(res.body.data.newOwnerId).toBeNull();
    await expect(roleOf(hh.id, members[0].id)).resolves.toBeNull();
    await expect(roleOf(hh.id, members[1].id)).resolves.toBe('member');
    await expect(ownerOf(hh.id)).resolves.toBe(creator.id);
    await expectStillHasAdmin(hh.id);
  });

  it('cuts the leaver off from the household immediately', async () => {
    const { members, household: hh } = await household(2);
    await leave(members[0], hh);

    const res = await request(app)
      .get(`/api/households/${hh.id}`)
      .set(authHeader(members[0].accessToken));

    expect(res.status).toBe(403);
  });

  it('does not hand the former member the roster or the invite code back', async () => {
    // The leave response deliberately is NOT a serialized household: the
    // caller stopped being entitled to its member list the moment they left.
    const { members, household: hh } = await household(2);

    const res = await leave(members[0], hh);

    expect(res.body.data.inviteCode).toBeUndefined();
    expect(res.body.data.members).toBeUndefined();
  });

  it('auto-transfers ownership to the most senior remaining ADMIN when the creator leaves', async () => {
    // D2's automatic half. members[0] joined first, members[1] second; both
    // are admins, so seniority is what decides, not promotion order.
    const { creator, members, household: hh } = await household(2);
    await promote(creator, hh, members[1].id);
    await promote(creator, hh, members[0].id);

    const res = await leave(creator, hh);

    expect(res.status).toBe(200);
    expect(res.body.data.newOwnerId).toBe(members[0].id);
    expect(res.body.data.promotedUserId).toBeNull();
    await expect(ownerOf(hh.id)).resolves.toBe(members[0].id);
    await expectStillHasAdmin(hh.id);
  });

  it('promotes AND crowns the most senior member when the creator is the only admin', async () => {
    // Both successions land on the same person: there is no remaining admin to
    // inherit ownership, so whoever is promoted takes both.
    const { creator, members, household: hh } = await household(2);

    const res = await leave(creator, hh);

    expect(res.status).toBe(200);
    expect(res.body.data.promotedUserId).toBe(members[0].id);
    expect(res.body.data.newOwnerId).toBe(members[0].id);
    await expect(roleOf(hh.id, members[0].id)).resolves.toBe('admin');
    await expect(roleOf(hh.id, members[1].id)).resolves.toBe('member');
    await expect(ownerOf(hh.id)).resolves.toBe(members[0].id);
    await expectStillHasAdmin(hh.id);
  });

  it('promotes the most senior member when the last admin is not the creator', async () => {
    // Reachable only through a transfer: the creator hands ownership over and
    // is then demoted by the new owner, leaving an admin who does not own the
    // household. That admin leaving is the case Hard Rule 9 has to survive.
    const { creator, members, household: hh } = await household(2);
    await promote(creator, hh, members[0].id);
    await transfer(creator, hh, members[0].id);
    await demote(members[0], hh, creator.id);
    // members[0] now owns the household and is its only admin; creator and
    // members[1] are plain members, creator being the more senior of the two.

    const res = await leave(members[0], hh);

    expect(res.status).toBe(200);
    expect(res.body.data.promotedUserId).toBe(creator.id);
    expect(res.body.data.newOwnerId).toBe(creator.id);
    await expect(roleOf(hh.id, creator.id)).resolves.toBe('admin');
    await expectStillHasAdmin(hh.id);
  });

  it('refuses to let the last member leave, pointing them at deletion instead', async () => {
    // Leaving would strand the household with zero members: unreadable
    // (requireMembership answers 403), undeletable, holding its invite code
    // forever. PDR-022 D4 is that person's actual exit.
    const { creator, household: hh } = await household(0);

    const res = await leave(creator, hh);

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('Delete the household instead');
    await expect(roleOf(hh.id, creator.id)).resolves.toBe('admin');
  });

  it('returns 403 on a second leave, because the caller is no longer a member', async () => {
    const { members, household: hh } = await household(2);
    await leave(members[0], hh);

    const res = await leave(members[0], hh);

    expect(res.status).toBe(403);
  });

  it('unassigns the leaver from pending tasks but keeps the ones they created (Hard Rule 16)', async () => {
    const { creator, members, household: hh } = await household(2);
    const leaver = members[0];

    const created = await request(app)
      .post(`/api/households/${hh.id}/tasks`)
      .set(authHeader(leaver.accessToken))
      .set('Idempotency-Key', `gov-task-${Date.now()}`)
      .send({ title: 'Sacar la basura', assignedTo: [leaver.id, members[1].id] });
    expect(created.status).toBe(201);

    await leave(leaver, hh);

    const list = await request(app)
      .get(`/api/households/${hh.id}/tasks`)
      .set(authHeader(creator.accessToken));
    const task = list.body.data.items.find(
      (t: { id: string }) => t.id === created.body.data.id,
    );
    // Authorship is never erased; only the dead assignment is pruned.
    expect(task).toBeDefined();
    expect(task.createdBy.id).toBe(leaver.id);
    expect(task.assignedTo.map((u: { id: string }) => u.id)).toEqual([members[1].id]);
  });
});

// ---------------------------------------------------------------------------
// Hard Rule 16b — every exit door refunds
// ---------------------------------------------------------------------------

describe('Hard Rule 16b: savings refunds on every exit path', () => {
  /**
   * Fund a wallet directly. Going through completions would make the test
   * about the reward pipeline instead of about the refund.
   */
  async function fund(userId: string, householdId: string, amount: number): Promise<void> {
    await PersonalCoinLedgerModel.create({
      userId: new Types.ObjectId(userId),
      householdId: new Types.ObjectId(householdId),
      amount,
      reason: 'legacy_balance',
      refType: 'legacy_migration',
      refId: `gov-seed-${userId}-${Date.now()}-${Math.random()}`,
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

  /** A household with an active goal both non-creator members have paid into. */
  async function withGoal(): Promise<{
    creator: TestUser;
    members: TestUser[];
    hh: TestHousehold;
    goalId: string;
  }> {
    setP1EnabledResolver(async () => true);
    const { creator, members, household: hh } = await household(2);
    await fund(members[0].id, hh.id, 30);
    await fund(members[1].id, hh.id, 30);

    const goal = await request(app)
      .post(`/api/households/${hh.id}/economy/p1/savings-goals`)
      .set(authHeader(creator.accessToken))
      .set('Idempotency-Key', `gov-goal-${Date.now()}-${Math.random()}`)
      .send({ itemType: 'cosmetic', itemId: GLASSES.id });
    expect(goal.status).toBe(201);
    const goalId = goal.body.data.goal.id;

    for (const [i, m] of members.entries()) {
      const res = await request(app)
        .post(`/api/households/${hh.id}/economy/p1/savings-goals/${goalId}/contributions`)
        .set(authHeader(m.accessToken))
        .set('Idempotency-Key', `gov-contrib-${i}-${Date.now()}-${Math.random()}`)
        .send({ amount: 10 });
      expect(res.status).toBe(200);
    }

    return { creator, members, hh, goalId };
  }

  it('refunds the leaver and nobody else when they leave voluntarily', async () => {
    const { members, hh, goalId } = await withGoal();

    await expect(balanceOf(members[0].id)).resolves.toBe(20);
    const res = await leave(members[0], hh);
    expect(res.status).toBe(200);

    // The coins came back...
    await expect(balanceOf(members[0].id)).resolves.toBe(30);
    // ...the other contributor's did not...
    await expect(balanceOf(members[1].id)).resolves.toBe(20);
    // ...and the goal's total dropped by exactly the refunded amount.
    const goal = await JointSavingsGoalModel.findById(goalId);
    expect(goal!.contributedCoins).toBe(10);

    const contributions = await SavingsContributionModel.find({ goalId });
    const leaverRow = contributions.find((c) => c.userId.toString() === members[0].id);
    const stayerRow = contributions.find((c) => c.userId.toString() === members[1].id);
    expect(leaverRow!.status).toBe('refunded');
    expect(stayerRow!.status).toBe('active');
  });

  it('refunds the departing member when they are expelled instead', async () => {
    // The pre-existing door. Asserted here alongside the new one so the two
    // paths can never diverge unnoticed.
    const { creator, members, hh, goalId } = await withGoal();

    const res = await request(app)
      .delete(`/api/households/${hh.id}/members/${members[0].id}`)
      .set(authHeader(creator.accessToken));

    expect(res.status).toBe(200);
    await expect(balanceOf(members[0].id)).resolves.toBe(30);
    const goal = await JointSavingsGoalModel.findById(goalId);
    expect(goal!.contributedCoins).toBe(10);
  });

  it('refunds the creator too when they leave and hand the household over', async () => {
    // The exit that also runs a succession: the refund must not be skipped
    // because the transaction had other work to do.
    setP1EnabledResolver(async () => true);
    const { creator, members, household: hh } = await household(1);
    await fund(creator.id, hh.id, 30);

    const goal = await request(app)
      .post(`/api/households/${hh.id}/economy/p1/savings-goals`)
      .set(authHeader(creator.accessToken))
      .set('Idempotency-Key', `gov-goal-owner-${Date.now()}`)
      .send({ itemType: 'cosmetic', itemId: GLASSES.id });
    await request(app)
      .post(`/api/households/${hh.id}/economy/p1/savings-goals/${goal.body.data.goal.id}/contributions`)
      .set(authHeader(creator.accessToken))
      .set('Idempotency-Key', `gov-contrib-owner-${Date.now()}`)
      .send({ amount: 25 });
    await expect(balanceOf(creator.id)).resolves.toBe(5);

    const res = await leave(creator, hh);

    expect(res.status).toBe(200);
    expect(res.body.data.newOwnerId).toBe(members[0].id);
    await expect(balanceOf(creator.id)).resolves.toBe(30);
    await expect(ownerOf(hh.id)).resolves.toBe(members[0].id);
    await expectStillHasAdmin(hh.id);
  });
});

// ---------------------------------------------------------------------------
// The creator is not removable either (D1, applied to expulsion)
// ---------------------------------------------------------------------------

describe('DELETE /:id/members/:userId — the creator is off limits (PDR-022 D1)', () => {
  it('returns 403 when an admin tries to expel the creator', async () => {
    // Expulsion is strictly stronger than demotion. Allowing it would leave
    // `createdBy` pointing at a non-member: a household nobody can manage
    // roles in, transfer, or delete.
    const { creator, members, household: hh } = await household(1);
    await promote(creator, hh, members[0].id);

    const res = await request(app)
      .delete(`/api/households/${hh.id}/members/${creator.id}`)
      .set(authHeader(members[0].accessToken));

    expect(res.status).toBe(403);
    expect(res.body.error).toBe('The household creator cannot be removed');
    await expect(roleOf(hh.id, creator.id)).resolves.toBe('admin');
    await expect(ownerOf(hh.id)).resolves.toBe(creator.id);
  });

  it('returns 403 when the creator tries to remove themselves', async () => {
    // Self-removal used to be the creator's only exit and it left the invariant
    // to luck. `leave` is the supported path now, and it runs the succession.
    const { creator, members, household: hh } = await household(1);
    await promote(creator, hh, members[0].id);

    const res = await request(app)
      .delete(`/api/households/${hh.id}/members/${creator.id}`)
      .set(authHeader(creator.accessToken));

    expect(res.status).toBe(403);
    await expect(roleOf(hh.id, creator.id)).resolves.toBe('admin');
  });

  it('still lets an admin expel an ordinary member', async () => {
    // The new guard must not have broken the endpoint it was added to.
    const { creator, members, household: hh } = await household(1);

    const res = await request(app)
      .delete(`/api/households/${hh.id}/members/${members[0].id}`)
      .set(authHeader(creator.accessToken));

    expect(res.status).toBe(200);
    await expect(roleOf(hh.id, members[0].id)).resolves.toBeNull();
  });
});

// ---------------------------------------------------------------------------
// Hard Rule 9 under concurrency
// ---------------------------------------------------------------------------

describe('Hard Rule 9 under concurrency', () => {
  it('never leaves a household without an admin when two admins leave at once', async () => {
    // The scenario the transaction and the household-document serialization
    // point exist for: both requests read a household with two admins, both
    // conclude an admin will remain, and without serialization both delete.
    const { creator, members, household: hh } = await household(2);
    await promote(creator, hh, members[0].id);
    await promote(creator, hh, members[1].id);
    // Three admins; creator cannot leave without succession, so the two
    // promoted ones race.

    await Promise.all([leave(members[0], hh), leave(members[1], hh)]);

    await expectStillHasAdmin(hh.id);
    await expect(roleOf(hh.id, creator.id)).resolves.toBe('admin');
  });

  it('never leaves a household without an admin when the last admin leaves twice at once', async () => {
    // Same request fired twice: exactly one may win, and the succession must
    // run exactly once — a household with two "most senior" promotions is not
    // wrong, but a household with none is.
    const { creator, members, household: hh } = await household(2);

    const results = await Promise.all([leave(creator, hh), leave(creator, hh)]);

    const codes = results.map((r) => r.status).sort();
    expect(codes[0]).toBe(200);
    // The loser is rejected, not silently duplicated.
    expect(codes[1]).toBeGreaterThanOrEqual(400);
    await expectStillHasAdmin(hh.id);
    await expect(roleOf(hh.id, members[0].id)).resolves.toBe('admin');
    await expect(ownerOf(hh.id)).resolves.toBe(members[0].id);
  });

  it('never demotes the last admin, even with the creator check satisfied', async () => {
    // Belt and braces: D1 makes this unreachable (the creator is the last
    // admin and cannot be demoted), so the assertion is that the older
    // invariant is still enforced independently of the newer one.
    const { creator, members, household: hh } = await household(1);
    await promote(creator, hh, members[0].id);
    await demote(creator, hh, members[0].id);

    // The creator is now the only admin, and is also the only one who could
    // ask for their own demotion.
    const res = await demote(creator, hh, creator.id);

    expect(res.status).toBe(403);
    await expectStillHasAdmin(hh.id);
  });
});

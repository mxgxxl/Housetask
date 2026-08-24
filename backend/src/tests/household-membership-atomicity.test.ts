import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { HouseholdModel } from '../models/Household';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { buildTestApp } from './setup';
import {
  authHeader,
  createHouseholdWithMember,
  createTestHousehold,
  createTestUser,
} from './helpers';

/**
 * Atomicity of the membership writes (TD-001, after the phase-4 cutover).
 *
 * Once `Household.members` stopped being written, the HouseholdMember row
 * became the ONLY record that a membership exists. That turned two previously
 * survivable partial failures into permanent broken states:
 *
 *   - createHousehold: the household document lands, the membership row does
 *     not. The household exists with no members — unreadable (requireMembership
 *     answers 403), undeletable, and holding its unique invite code forever.
 *   - joinHousehold: the membership row is what makes the join real, so a
 *     failure there must leave nothing at all — not a household the user
 *     believes they joined and every read answers 403 for.
 *
 * Both paths run inside a transaction. These tests force the membership write
 * to fail and assert nothing survives. (Commit 7 later removed the second
 * write these transactions originally coordinated — `User.households` — but the
 * transaction stays: it makes the rollback guaranteed rather than incidental,
 * and the next write added to either path inherits that instead of having to
 * rediscover it.)
 *
 * The failure is injected at `HouseholdMemberModel.updateOne`, which is what
 * `addMembership` calls and nothing else on these paths does — so the mock hits
 * exactly the write under test. A plain Error is deliberately not a transient
 * transaction error, so `withTransaction` aborts instead of retrying it.
 */
let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

afterEach(() => {
  jest.restoreAllMocks();
});

/** The `households` list as the client sees it — derived, not stored (commit 7). */
async function publicHouseholds(accessToken: string): Promise<string[]> {
  const res = await request(app).get('/api/users/me').set(authHeader(accessToken));
  return (res.body.data?.households ?? []) as string[];
}

function failTheMembershipWrite(): jest.SpyInstance {
  return jest.spyOn(HouseholdMemberModel, 'updateOne').mockImplementation(() => {
    throw new Error('simulated failure writing the membership row');
  });
}

describe('createHousehold atomicity', () => {
  it('should not leave the household behind when the membership write fails', async () => {
    const user = await createTestUser(app);
    const name = `Hogar huérfano ${new Types.ObjectId().toString()}`;
    const spy = failTheMembershipWrite();

    const res = await request(app)
      .post('/api/households')
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', new Types.ObjectId().toString())
      .send({ name });

    expect(res.status).toBe(500);
    expect(spy).toHaveBeenCalled();

    // The household document must have been rolled back with it. Before the
    // transaction this assertion failed: the document was already committed by
    // the time addMembership threw.
    expect(await HouseholdModel.findOne({ name })).toBeNull();
  });

  it('should leave the creator belonging to no household at all', async () => {
    const user = await createTestUser(app);
    failTheMembershipWrite();

    await request(app)
      .post('/api/households')
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', new Types.ObjectId().toString())
      .send({ name: `Hogar huérfano ${new Types.ObjectId().toString()}` });

    expect(await publicHouseholds(user.accessToken)).toHaveLength(0);
  });

  it('should still create a household normally when nothing fails', async () => {
    // The transaction must not change the happy path, only its failure mode.
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);

    expect(
      await HouseholdMemberModel.countDocuments({
        householdId: new Types.ObjectId(household.id),
        role: 'admin',
      }),
    ).toBe(1);
    expect(await publicHouseholds(user.accessToken)).toEqual([household.id]);
  });
});

describe('joinHousehold atomicity', () => {
  it('should not register the user when the membership write fails', async () => {
    const admin = await createTestUser(app);
    const household = await createTestHousehold(app, admin);
    const joiner = await createTestUser(app);
    failTheMembershipWrite();

    const res = await request(app)
      .post('/api/households/join')
      .set(authHeader(joiner.accessToken))
      .set('Idempotency-Key', new Types.ObjectId().toString())
      .send({ inviteCode: household.inviteCode });

    expect(res.status).toBe(500);

    expect(
      await HouseholdMemberModel.findOne({
        householdId: new Types.ObjectId(household.id),
        userId: new Types.ObjectId(joiner.id),
      }),
    ).toBeNull();
    // And the client-visible list, derived from the same collection, agrees.
    expect(await publicHouseholds(joiner.accessToken)).not.toContain(household.id);
  });

  it('should leave the joiner unable to read the household after the rollback', async () => {
    // The observable consequence, not just the stored state.
    const admin = await createTestUser(app);
    const household = await createTestHousehold(app, admin);
    const joiner = await createTestUser(app);
    const spy = failTheMembershipWrite();

    await request(app)
      .post('/api/households/join')
      .set(authHeader(joiner.accessToken))
      .set('Idempotency-Key', new Types.ObjectId().toString())
      .send({ inviteCode: household.inviteCode });

    spy.mockRestore();

    const res = await request(app)
      .get(`/api/households/${household.id}`)
      .set(authHeader(joiner.accessToken));
    expect(res.status).toBe(403);
  });
});

describe('Hard Rule 9 with all three operations under a transaction', () => {
  it('should still refuse to remove the last admin', async () => {
    const { admin, household } = await createHouseholdWithMember(app);

    const res = await request(app)
      .delete(`/api/households/${household.id}/members/${admin.id}`)
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Cannot remove the last admin of the household');
    expect(
      await HouseholdMemberModel.countDocuments({
        householdId: new Types.ObjectId(household.id),
        role: 'admin',
      }),
    ).toBe(1);
  });

  it('should survive a full create -> join -> remove -> re-join cycle', async () => {
    // Exercises all three transactional paths in sequence against the same
    // household, which is what the production validation script does and what
    // no single-operation test covers.
    const admin = await createTestUser(app);
    const household = await createTestHousehold(app, admin);
    const member = await createTestUser(app);

    const join = async () =>
      request(app)
        .post('/api/households/join')
        .set(authHeader(member.accessToken))
        .set('Idempotency-Key', new Types.ObjectId().toString())
        .send({ inviteCode: household.inviteCode });

    expect((await join()).status).toBe(200);

    const removed = await request(app)
      .delete(`/api/households/${household.id}/members/${member.id}`)
      .set(authHeader(admin.accessToken));
    expect(removed.status).toBe(200);

    expect((await join()).status).toBe(200);

    expect(
      await HouseholdMemberModel.countDocuments({
        householdId: new Types.ObjectId(household.id),
      }),
    ).toBe(2);
    // And the admin is still the only admin, so Hard Rule 9 still bites.
    const lastAdmin = await request(app)
      .delete(`/api/households/${household.id}/members/${admin.id}`)
      .set(authHeader(admin.accessToken));
    expect(lastAdmin.status).toBe(400);
  });

  it('should keep touching the household on removal after the refactor', async () => {
    // The serialization point that replaced the embedded write. The two new
    // transactions must not have disturbed it.
    const { admin, member, household } = await createHouseholdWithMember(app);

    const before = await HouseholdModel.findById(household.id).select('updatedAt').lean();
    await new Promise((resolve) => setTimeout(resolve, 10));

    await request(app)
      .delete(`/api/households/${household.id}/members/${member.id}`)
      .set(authHeader(admin.accessToken));

    const after = await HouseholdModel.findById(household.id).select('updatedAt').lean();
    expect(new Date(after!.updatedAt).getTime()).toBeGreaterThan(
      new Date(before!.updatedAt).getTime(),
    );
  });
});

import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { HouseholdMemberModel } from '../models/HouseholdMember';
import { buildTestApp } from './setup';
import {
  authHeader,
  createHouseholdWithMember,
  createTestHousehold,
  createTestUser,
  joinTestHousehold,
} from './helpers';

/**
 * Phase 0 of TD-001: every membership write lands in both the embedded array
 * (still the authority) and the new HouseholdMember collection.
 *
 * Nothing reads the collection yet, so these tests are the only thing standing
 * between a silent mirroring bug and a backfill that quietly papers over it
 * three phases later.
 */
let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

const mirrored = (householdId: string, userId: string) =>
  HouseholdMemberModel.findOne({
    householdId: new Types.ObjectId(householdId),
    userId: new Types.ObjectId(userId),
  });

describe('TD-001 dual write', () => {
  it('should mirror the creator as admin when a household is created', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);

    const row = await mirrored(household.id, user.id);

    expect(row).not.toBeNull();
    expect(row!.role).toBe('admin');
    expect(row!.joinedAt).toBeInstanceOf(Date);
  });

  it('should mirror a member who joins by invite code', async () => {
    const admin = await createTestUser(app);
    const household = await createTestHousehold(app, admin);
    const joiner = await createTestUser(app);

    await joinTestHousehold(app, joiner, household.inviteCode);

    const row = await mirrored(household.id, joiner.id);
    expect(row).not.toBeNull();
    expect(row!.role).toBe('member');
  });

  it('should stay idempotent when the same user joins twice', async () => {
    // joinHousehold is documented as idempotent for existing members; the
    // mirror must not throw on the unique index when that path runs again.
    const admin = await createTestUser(app);
    const household = await createTestHousehold(app, admin);
    const joiner = await createTestUser(app);

    await joinTestHousehold(app, joiner, household.inviteCode);
    await joinTestHousehold(app, joiner, household.inviteCode);

    const rows = await HouseholdMemberModel.find({
      householdId: new Types.ObjectId(household.id),
      userId: new Types.ObjectId(joiner.id),
    });
    expect(rows).toHaveLength(1);
  });

  it('should not downgrade an existing role when a join replays', async () => {
    // The mirror upserts with $setOnInsert precisely so a replay cannot
    // rewrite an admin as a plain member.
    const admin = await createTestUser(app);
    const household = await createTestHousehold(app, admin);

    await joinTestHousehold(app, admin, household.inviteCode);

    const row = await mirrored(household.id, admin.id);
    expect(row!.role).toBe('admin');
  });

  it('should remove the mirrored row when a member is removed', async () => {
    const { admin, member, household } = await createHouseholdWithMember(app);

    const res = await request(app)
      .delete(`/api/households/${household.id}/members/${member.id}`)
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    expect(await mirrored(household.id, member.id)).toBeNull();
    expect(await mirrored(household.id, admin.id)).not.toBeNull();
  });
});

describe('TD-001 Hard Rule 9 under a transaction', () => {
  it('should still refuse to remove the last admin', async () => {
    const admin = await createTestUser(app);
    const household = await createTestHousehold(app, admin);

    const res = await request(app)
      .delete(`/api/households/${household.id}/members/${admin.id}`)
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(400);
    // The transaction aborted, so neither side may have lost the admin.
    expect(await mirrored(household.id, admin.id)).not.toBeNull();
  });

  it('should never leave a household without an admin under concurrent removals',
    async () => {
      // Invariant guard, NOT a demonstration of the race.
      //
      // Verified honestly: this test also passes with the transaction removed
      // (3/3 runs). Two supertest requests in a `--runInBand` Jest process do
      // not actually interleave inside the window between the admin count and
      // the write — Node is single-threaded and neither request yields there.
      // So this asserts the invariant holds, and would catch a gross
      // regression, but it does NOT prove the transaction is what protects it.
      //
      // Demonstrating the race for real would need a seam to widen the window
      // (e.g. an injectable delay between the count and the save) so the two
      // removals genuinely overlap. Filed as a follow-up rather than built
      // here, because adding a production seam purely to prove a test is a
      // trade worth deciding deliberately.
      const adminA = await createTestUser(app);
      const household = await createTestHousehold(app, adminA);
      const adminB = await createTestUser(app);
      await joinTestHousehold(app, adminB, household.inviteCode);

      // Promote B so the household has exactly two admins.
      await HouseholdMemberModel.updateOne(
        {
          householdId: new Types.ObjectId(household.id),
          userId: new Types.ObjectId(adminB.id),
        },
        { $set: { role: 'admin' } },
      );
      const { HouseholdModel } = await import('../models/Household');
      await HouseholdModel.updateOne(
        { _id: household.id, 'members.user': new Types.ObjectId(adminB.id) },
        { $set: { 'members.$.role': 'admin' } },
      );

      const [resA, resB] = await Promise.all([
        request(app)
          .delete(`/api/households/${household.id}/members/${adminB.id}`)
          .set(authHeader(adminA.accessToken)),
        request(app)
          .delete(`/api/households/${household.id}/members/${adminA.id}`)
          .set(authHeader(adminB.accessToken)),
      ]);

      // Whatever the interleaving, at least one removal must not have
      // succeeded — the household cannot end up with zero admins.
      const remaining = await HouseholdMemberModel.countDocuments({
        householdId: new Types.ObjectId(household.id),
        role: 'admin',
      });
      expect(remaining).toBeGreaterThanOrEqual(1);
      expect([resA.status, resB.status].filter((s) => s === 200).length)
          .toBeLessThanOrEqual(1);
    });
});

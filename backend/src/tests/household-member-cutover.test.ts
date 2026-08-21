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
  joinTestHousehold,
} from './helpers';

/**
 * Phase 3 of TD-001: the HouseholdMember collection becomes the authority for
 * every read, while the embedded `Household.members` array keeps being written
 * as the rollback net.
 *
 * The tests that matter here are the ones with the polarity DELIBERATELY
 * flipped against the phase-2 suite they replace: there, a disagreement had to
 * be reported without changing the answer; here, a disagreement has to change
 * the answer, because the collection is now what counts. A revert of any read
 * back to the embedded array fails these and only these — the rest of the
 * suite cannot see the difference, which is the whole point of the migration.
 *
 * The other half of the contract is covered by NOT being here: households.test.ts
 * exercises the same endpoints through the public API and passes unmodified.
 * If it had needed edits, the response shape would have changed, which is what
 * this phase promises never to do.
 */
let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

/** Drop a member's row from the authority, leaving the embedded array intact. */
async function unmirror(householdId: string, userId: string): Promise<void> {
  await HouseholdMemberModel.deleteOne({
    householdId: new Types.ObjectId(householdId),
    userId: new Types.ObjectId(userId),
  });
}

/** The embedded array's view, which nothing should be reading any more. */
async function embeddedMemberIds(householdId: string): Promise<string[]> {
  const household = await HouseholdModel.findById(householdId).select('members').lean();
  return (household?.members ?? []).map((m) => m.user.toString());
}

describe('TD-001 cutover: the collection is the authority', () => {
  describe('requireMembership', () => {
    it('should refuse a caller the collection does not know, even if the embedded array does',
      async () => {
        const user = await createTestUser(app);
        const household = await createTestHousehold(app, user);

        await unmirror(household.id, user.id);

        const res = await request(app)
          .get(`/api/households/${household.id}`)
          .set(authHeader(user.accessToken));

        // Before the cutover this was 200 with a divergence reported.
        expect(res.status).toBe(403);
        // The embedded array still says otherwise — proving which side answered.
        expect(await embeddedMemberIds(household.id)).toContain(user.id);
      });

    it('should still return 403 to a non-member and 404 for a household that does not exist',
      async () => {
        const { household } = await createHouseholdWithMember(app);
        const outsider = await createTestUser(app);

        const forbidden = await request(app)
          .get(`/api/households/${household.id}`)
          .set(authHeader(outsider.accessToken));
        expect(forbidden.status).toBe(403);

        const missing = await request(app)
          .get(`/api/households/${new Types.ObjectId().toString()}`)
          .set(authHeader(outsider.accessToken));
        expect(missing.status).toBe(404);
      });

    it('should feed req.member.memberIds from the collection for assignee validation',
      async () => {
        // task.service's assertAssigneesAreMembers trusts memberIds wholesale,
        // so if that list stopped reflecting the authority a removed member
        // would stay assignable.
        const { admin, member, household } = await createHouseholdWithMember(app);

        const accepted = await request(app)
          .post(`/api/households/${household.id}/tasks`)
          .set(authHeader(admin.accessToken))
          .set('Idempotency-Key', new Types.ObjectId().toString())
          .send({ title: 'Assigned to a real member', assignedTo: [member.id] });
        expect(accepted.status).toBe(201);

        await unmirror(household.id, member.id);

        const rejected = await request(app)
          .post(`/api/households/${household.id}/tasks`)
          .set(authHeader(admin.accessToken))
          .set('Idempotency-Key', new Types.ObjectId().toString())
          .send({ title: 'Assigned to a ghost', assignedTo: [member.id] });
        expect(rejected.status).toBe(400);
        expect(rejected.body.error).toBe('Invalid assigned member');
      });
  });

  describe('serializeHousehold', () => {
    it('should keep the response shape byte-for-byte compatible', async () => {
      // The Flutter client is a no-op through this migration only if this
      // holds; an app already in the stores cannot be rolled back.
      const { admin, household } = await createHouseholdWithMember(app);

      const res = await request(app)
        .get(`/api/households/${household.id}`)
        .set(authHeader(admin.accessToken));

      expect(res.status).toBe(200);
      expect(Object.keys(res.body.data).sort()).toEqual(
        ['createdAt', 'createdBy', 'id', 'inviteCode', 'members', 'name'].sort(),
      );
      expect(Object.keys(res.body.data.members[0]).sort()).toEqual(['joinedAt', 'role', 'user']);
      // `avatarUrl` is absent rather than null when the user has none — JSON
      // drops undefined — which was true before the cutover too. Assert the
      // keys that always ship, and that nothing NEW appeared alongside them.
      expect(Object.keys(res.body.data.members[0].user).sort()).toEqual(['email', 'id', 'name']);
      expect(res.body.data.members[0].user.id).toBe(admin.id);
      expect(res.body.data.members[0].user.email).toBe(admin.email);
      expect(res.body.data.members[0].role).toBe('admin');
    });

    it('should list members from the collection, not from the embedded array', async () => {
      const { admin, member, household } = await createHouseholdWithMember(app);

      await unmirror(household.id, member.id);

      const res = await request(app)
        .get(`/api/households/${household.id}/members`)
        .set(authHeader(admin.accessToken));

      expect(res.status).toBe(200);
      expect(res.body.data.map((m: { user: { id: string } }) => m.user.id)).toEqual([admin.id]);
      // The embedded array disagrees, and is ignored.
      expect(await embeddedMemberIds(household.id)).toContain(member.id);
    });

    it('should order members by joinedAt so the list does not reshuffle', async () => {
      // The embedded array gave creator-first ordering for free; an unsorted
      // index scan would change every member list in the app without changing
      // a single field.
      const admin = await createTestUser(app);
      const household = await createTestHousehold(app, admin);
      const second = await createTestUser(app);
      const third = await createTestUser(app);
      await joinTestHousehold(app, second, household.inviteCode);
      await joinTestHousehold(app, third, household.inviteCode);

      const res = await request(app)
        .get(`/api/households/${household.id}/members`)
        .set(authHeader(admin.accessToken));

      expect(res.body.data.map((m: { user: { id: string } }) => m.user.id)).toEqual([
        admin.id,
        second.id,
        third.id,
      ]);
    });
  });

  describe('stats', () => {
    it('should build memberStats from the collection', async () => {
      const { admin, member, household } = await createHouseholdWithMember(app);

      await unmirror(household.id, member.id);

      const res = await request(app)
        .get(`/api/households/${household.id}/stats`)
        .set(authHeader(admin.accessToken));

      expect(res.status).toBe(200);
      expect(res.body.data.memberStats.map((m: { userId: string }) => m.userId)).toEqual([
        admin.id,
      ]);
    });
  });

  describe('Hard Rule 9, now counted against the collection', () => {
    it('should refuse to remove the last admin', async () => {
      const { admin, household } = await createHouseholdWithMember(app);

      const res = await request(app)
        .delete(`/api/households/${household.id}/members/${admin.id}`)
        .set(authHeader(admin.accessToken));

      expect(res.status).toBe(400);
      expect(res.body.error).toBe('Cannot remove the last admin of the household');
    });

    it('should count admins from the collection, not from a stale embedded array',
      async () => {
        // The dangerous direction: the embedded array claims a second admin
        // the collection does not have. Counting the array would let the real
        // last admin be removed and leave the household leaderless.
        const { admin, member, household } = await createHouseholdWithMember(app);

        await HouseholdModel.updateOne(
          { _id: household.id, 'members.user': new Types.ObjectId(member.id) },
          { $set: { 'members.$.role': 'admin' } },
        );

        const res = await request(app)
          .delete(`/api/households/${household.id}/members/${admin.id}`)
          .set(authHeader(admin.accessToken));

        expect(res.status).toBe(400);
        expect(
          await HouseholdMemberModel.countDocuments({
            householdId: new Types.ObjectId(household.id),
            role: 'admin',
          }),
        ).toBe(1);
      });

    it('should reject a target the collection does not have as a member', async () => {
      const { admin, member, household } = await createHouseholdWithMember(app);

      await unmirror(household.id, member.id);

      const res = await request(app)
        .delete(`/api/households/${household.id}/members/${member.id}`)
        .set(authHeader(admin.accessToken));

      expect(res.status).toBe(404);
    });

    it('should still remove a member from both sides', async () => {
      // The dual write is untouched by the cutover: the embedded array stays
      // in step as the rollback net.
      const { admin, member, household } = await createHouseholdWithMember(app);

      const res = await request(app)
        .delete(`/api/households/${household.id}/members/${member.id}`)
        .set(authHeader(admin.accessToken));

      expect(res.status).toBe(200);
      expect(res.body.data.members.map((m: { user: { id: string } }) => m.user.id)).toEqual([
        admin.id,
      ]);
      expect(await embeddedMemberIds(household.id)).toEqual([admin.id]);
      expect(
        await HouseholdMemberModel.findOne({
          householdId: new Types.ObjectId(household.id),
          userId: new Types.ObjectId(member.id),
        }),
      ).toBeNull();
    });
  });

  describe('join', () => {
    it('should decide idempotency from the collection and keep both sides in step',
      async () => {
        const admin = await createTestUser(app);
        const household = await createTestHousehold(app, admin);
        const joiner = await createTestUser(app);

        await joinTestHousehold(app, joiner, household.inviteCode);
        await joinTestHousehold(app, joiner, household.inviteCode);

        expect(
          await HouseholdMemberModel.countDocuments({
            householdId: new Types.ObjectId(household.id),
            userId: new Types.ObjectId(joiner.id),
          }),
        ).toBe(1);
        expect((await embeddedMemberIds(household.id)).filter((id) => id === joiner.id)).toHaveLength(
          1,
        );
      });
  });
});

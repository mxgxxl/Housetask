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
 * TD-001 phases 3 and 4: the HouseholdMember collection is the authority for
 * every read (phase 3, commit 5) and now also the ONLY thing written — the
 * embedded `Household.members` array is no longer maintained (phase 4,
 * commit 6).
 *
 * The reads here have the polarity DELIBERATELY flipped against the phase-2
 * suite they replaced: there, a disagreement had to be reported without
 * changing the answer; here, a disagreement changes the answer, because the
 * collection is what counts. A revert of any read back to the embedded array
 * fails these and only these — the rest of the suite cannot see the
 * difference, which is the whole point of the migration.
 *
 * The write side is pinned by the `phase 4` block at the bottom: the embedded
 * array must stay EMPTY. Those are the tests that fail if the dual write is
 * ever reintroduced by a bad merge.
 *
 * The other half of the contract is covered by NOT being here: households.test.ts
 * exercises the same endpoints through the public API and passes unmodified
 * through both commits. If it had needed edits, the response shape would have
 * changed, which is what this migration promises never to do.
 */
let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

/** Drop a member's row from the authority, simulating a membership that is gone. */
async function unmirror(householdId: string, userId: string): Promise<void> {
  await HouseholdMemberModel.deleteOne({
    householdId: new Types.ObjectId(householdId),
    userId: new Types.ObjectId(userId),
  });
}

/**
 * The `households` list as the CLIENT sees it, via GET /api/users/me.
 *
 * Since commit 7 there is no `User.households` field to read: the value is
 * derived from HouseholdMember. Asserting through the endpoint rather than the
 * database is deliberate — this list is what `HouseholdCubit.init` picks the
 * active household from, so the contract is the thing that must not move.
 */
async function publicHouseholds(accessToken: string): Promise<string[]> {
  const res = await request(app).get('/api/users/me').set(authHeader(accessToken));
  return (res.body.data?.households ?? []) as string[];
}

/** The vestigial array: nothing reads it, and since commit 6 nothing writes it. */
async function embeddedMemberIds(householdId: string): Promise<string[]> {
  // Raw: commit 7 removed `members` from the schema, so a typed query cannot
  // see it — and a typed assertion would then pass even if the field were
  // still being written, which is exactly what these tests exist to catch.
  const household = await HouseholdModel.collection.findOne({
    _id: new Types.ObjectId(householdId),
  });
  const members = (household?.members ?? []) as { user: Types.ObjectId }[];
  return members.map((m) => m.user.toString());
}

describe('TD-001 cutover: the collection is the authority', () => {
  describe('requireMembership', () => {
    it('should refuse a caller whose membership row is gone', async () => {
      const user = await createTestUser(app);
      const household = await createTestHousehold(app, user);

      await unmirror(household.id, user.id);

      const res = await request(app)
        .get(`/api/households/${household.id}`)
        .set(authHeader(user.accessToken));

      // Before the cutover this was 200 with a divergence reported: the
      // embedded array answered and the collection was only compared.
      expect(res.status).toBe(403);
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

    it('should list members from the collection', async () => {
      const { admin, member, household } = await createHouseholdWithMember(app);

      await unmirror(household.id, member.id);

      const res = await request(app)
        .get(`/api/households/${household.id}/members`)
        .set(authHeader(admin.accessToken));

      expect(res.status).toBe(200);
      expect(res.body.data.map((m: { user: { id: string } }) => m.user.id)).toEqual([admin.id]);
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

    it('should remove the membership row and the User.households entry', async () => {
      const { admin, member, household } = await createHouseholdWithMember(app);

      const res = await request(app)
        .delete(`/api/households/${household.id}/members/${member.id}`)
        .set(authHeader(admin.accessToken));

      expect(res.status).toBe(200);
      expect(res.body.data.members.map((m: { user: { id: string } }) => m.user.id)).toEqual([
        admin.id,
      ]);
      expect(
        await HouseholdMemberModel.findOne({
          householdId: new Types.ObjectId(household.id),
          userId: new Types.ObjectId(member.id),
        }),
      ).toBeNull();
      expect(await publicHouseholds(member.accessToken)).not.toContain(household.id);
    });
  });

  describe('phase 4: the embedded array is no longer written', () => {
    it('should create a household with an empty members array', async () => {
      const user = await createTestUser(app);
      const household = await createTestHousehold(app, user);

      expect(await embeddedMemberIds(household.id)).toEqual([]);
      // ...while the membership itself exists, in the only place that holds it.
      expect(
        await HouseholdMemberModel.countDocuments({
          householdId: new Types.ObjectId(household.id),
          role: 'admin',
        }),
      ).toBe(1);
    });

    it('should not push to the embedded array when a member joins', async () => {
      const { household, member } = await createHouseholdWithMember(app);

      expect(await embeddedMemberIds(household.id)).toEqual([]);
      expect(
        await HouseholdMemberModel.countDocuments({
          householdId: new Types.ObjectId(household.id),
        }),
      ).toBe(2);
      expect(await publicHouseholds(member.accessToken)).toContain(household.id);
    });

    it('should touch the household on removal, keeping the serialization point',
      async () => {
        // Not a proof of the race — see household-member-dual-write.test.ts for
        // why that cannot be demonstrated in-process. This guards the MECHANISM:
        // concurrent removals used to serialize because both transactions wrote
        // the household document for the embedded array. Commit 6 removed that
        // write, so removeMemberInTransaction now touches the household on
        // purpose. If someone deletes that write as dead code, this fails.
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

  describe('join', () => {
    it('should decide idempotency from the collection', async () => {
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
    });
  });
});

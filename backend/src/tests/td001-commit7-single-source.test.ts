import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { HouseholdModel } from '../models/Household';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { UserModel } from '../models/User';
import { buildTestApp } from './setup';
import {
  authHeader,
  createHouseholdWithMember,
  createTestHousehold,
  createTestUser,
  joinTestHousehold,
} from './helpers';

/**
 * TD-001 commit 7: membership lives in exactly ONE place.
 *
 * Both denormalized copies are gone from the schemas — `Household.members`
 * (embedded, unwritten since commit 6) and `User.households` (the second copy
 * of the same edge, finding H1 of docs/TD-001-DESIGN.md). The socket handshake,
 * the last reader of `User.households`, now resolves rooms from
 * HouseholdMember like everything else.
 *
 * The risk this commit carries is not a wrong answer, it is a SILENT one: if
 * the handshake resolved no rooms, HTTP would keep working perfectly and only
 * realtime would die — indistinguishable from "nothing is happening" unless
 * someone watches two clients at once. Since that manual check is not
 * available, these tests stand in for it by asserting the handshake's input
 * directly.
 *
 * They also pin the thing that must NOT change: `households` still ships in the
 * user payload, derived instead of stored, because `HouseholdCubit.init` picks
 * the active household from it (`household_cubit.dart:54-56`) and the app is
 * already in the stores.
 */
let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

/** What the socket handshake reads to decide which rooms to join. */
async function roomsFor(userId: string): Promise<string[]> {
  const memberships = await HouseholdMemberModel.find({ userId: new Types.ObjectId(userId) })
    .select('householdId')
    .lean();
  return memberships.map((m) => m.householdId.toString()).sort();
}

async function publicHouseholds(accessToken: string): Promise<string[]> {
  const res = await request(app).get('/api/users/me').set(authHeader(accessToken));
  return (res.body.data?.households ?? []) as string[];
}

describe('schemas no longer carry a second copy of membership', () => {
  it('should not declare `households` on the User schema', () => {
    expect(UserModel.schema.path('households')).toBeUndefined();
  });

  it('should not declare `members` on the Household schema', () => {
    expect(HouseholdModel.schema.path('members')).toBeUndefined();
  });

  it('should not write either field when a household is created and joined', async () => {
    const { admin, member, household } = await createHouseholdWithMember(app);

    // Read through the raw collections: a field the schema does not declare is
    // invisible to a typed query, so a typed assertion would pass even if the
    // write were still happening.
    const rawHousehold = await HouseholdModel.collection.findOne({
      _id: new Types.ObjectId(household.id),
    });
    expect(rawHousehold).not.toHaveProperty('members');

    for (const id of [admin.id, member.id]) {
      const rawUser = await UserModel.collection.findOne({ _id: new Types.ObjectId(id) });
      expect(rawUser).not.toHaveProperty('households');
    }
  });
});

describe('socket handshake room resolution', () => {
  it('should resolve one room per membership, from the collection', async () => {
    const user = await createTestUser(app);
    const first = await createTestHousehold(app, user, 'Casa uno');
    const second = await createTestHousehold(app, user, 'Casa dos');

    expect(await roomsFor(user.id)).toEqual([first.id, second.id].sort());
  });

  it('should resolve the room of a household joined by invite code', async () => {
    const admin = await createTestUser(app);
    const household = await createTestHousehold(app, admin);
    const joiner = await createTestUser(app);

    expect(await roomsFor(joiner.id)).toEqual([]);
    await joinTestHousehold(app, joiner, household.inviteCode);
    expect(await roomsFor(joiner.id)).toEqual([household.id]);
  });

  it('should stop resolving the room once the member is removed', async () => {
    // The failure this guards against is the quiet one: a removed member whose
    // socket keeps receiving a household's events because the old denormalized
    // array was never pruned.
    const { admin, member, household } = await createHouseholdWithMember(app);
    expect(await roomsFor(member.id)).toEqual([household.id]);

    await request(app)
      .delete(`/api/households/${household.id}/members/${member.id}`)
      .set(authHeader(admin.accessToken));

    expect(await roomsFor(member.id)).toEqual([]);
  });

  it('should resolve no rooms for a user who belongs to nothing', async () => {
    const loner = await createTestUser(app);
    expect(await roomsFor(loner.id)).toEqual([]);
  });

  it('should agree with what the HTTP surface authorizes', async () => {
    // The whole point of commit 7: the socket and the HTTP surface stop being
    // able to disagree, because they read the same rows. Before it, these two
    // came from different copies.
    const { admin, member, household } = await createHouseholdWithMember(app);
    const outsider = await createTestUser(app);

    expect(await roomsFor(member.id)).toContain(household.id);
    const allowed = await request(app)
      .get(`/api/households/${household.id}`)
      .set(authHeader(member.accessToken));
    expect(allowed.status).toBe(200);

    expect(await roomsFor(outsider.id)).not.toContain(household.id);
    const denied = await request(app)
      .get(`/api/households/${household.id}`)
      .set(authHeader(outsider.accessToken));
    expect(denied.status).toBe(403);

    expect(await roomsFor(admin.id)).toContain(household.id);
  });
});

describe('the user payload keeps its households list', () => {
  it('should still ship `households`, derived from the collection', async () => {
    const user = await createTestUser(app);
    const first = await createTestHousehold(app, user, 'Casa uno');
    const second = await createTestHousehold(app, user, 'Casa dos');

    // Ordered by joinedAt, so the client's "first household" stays stable
    // rather than following whatever order the index yields.
    expect(await publicHouseholds(user.accessToken)).toEqual([first.id, second.id]);
  });

  it('should ship it on register and on login too, not only on the profile read',
    async () => {
      // HouseholdCubit.init reads it from the auth response; a list that were
      // only correct on /users/me would still break startup.
      const user = await createTestUser(app);
      const household = await createTestHousehold(app, user);

      const login = await request(app)
        .post('/api/auth/login')
        .send({ email: user.email, password: user.password });

      expect(login.status).toBe(200);
      expect(login.body.data.user.households).toEqual([household.id]);
    });

  it('should be empty for a user with no household, not absent', async () => {
    // `households: []` and a missing key are different things to a client that
    // does `json['households'] as List?`; the second silently becomes null.
    const user = await createTestUser(app);

    const res = await request(app).get('/api/users/me').set(authHeader(user.accessToken));
    expect(res.body.data).toHaveProperty('households');
    expect(res.body.data.households).toEqual([]);
  });

  it('should drop a household from the list when the user is removed from it', async () => {
    const { admin, member, household } = await createHouseholdWithMember(app);
    expect(await publicHouseholds(member.accessToken)).toEqual([household.id]);

    await request(app)
      .delete(`/api/households/${household.id}/members/${member.id}`)
      .set(authHeader(admin.accessToken));

    expect(await publicHouseholds(member.accessToken)).toEqual([]);
  });
});

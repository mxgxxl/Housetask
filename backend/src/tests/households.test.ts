import { Server } from 'http';
import request from 'supertest';

import { buildTestApp } from './setup';
import {
  authHeader,
  createHouseholdWithMember,
  createTestHousehold,
  createTestUser,
} from './helpers';

let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

describe('POST /api/households', () => {
  it('should make the creator both a member and an admin of the new household', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/households')
      .set(authHeader(user.accessToken))
      .send({ name: 'Casa Nueva' });

    expect(res.status).toBe(201);
    expect(res.body.data.name).toBe('Casa Nueva');
    expect(res.body.data.inviteCode).toHaveLength(8);
    expect(res.body.data.members).toHaveLength(1);
    expect(res.body.data.members[0].user.id).toBe(user.id);
    expect(res.body.data.members[0].role).toBe('admin');
  });

  it('should return 400 when the name is missing', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/households')
      .set(authHeader(user.accessToken))
      .send({});

    expect(res.status).toBe(400);
  });
});

describe('POST /api/households/join', () => {
  it('should add the caller as a plain member when the invite code is valid', async () => {
    const { member, household } = await createHouseholdWithMember(app);

    const res = await request(app)
      .get(`/api/households/${household.id}`)
      .set(authHeader(member.accessToken));

    expect(res.status).toBe(200);
    const joined = res.body.data.members.find(
      (m: { user: { id: string }; role: string }) => m.user.id === member.id
    );
    expect(joined.role).toBe('member');
  });

  it('should return 404 for an unknown invite code', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/households/join')
      .set(authHeader(user.accessToken))
      .send({ inviteCode: 'BADCODE1' });

    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Invalid invite code');
  });
});

describe('DELETE /api/households/:id/members/:userId', () => {
  it('should refuse to remove the only admin, leaving the household with a leader', async () => {
    const admin = await createTestUser(app);
    const household = await createTestHousehold(app, admin);

    const res = await request(app)
      .delete(`/api/households/${household.id}/members/${admin.id}`)
      .set(authHeader(admin.accessToken));

    // Hard Rule 9: the last admin can never be removed.
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(res.status).toBeLessThan(500);
    expect(res.body.error).toBe('Cannot remove the last admin of the household');

    // The admin must still be a member afterwards.
    const after = await request(app)
      .get(`/api/households/${household.id}`)
      .set(authHeader(admin.accessToken));
    expect(after.body.data.members).toHaveLength(1);
  });

  it('should let an admin remove a regular member', async () => {
    const { admin, member, household } = await createHouseholdWithMember(app);

    const res = await request(app)
      .delete(`/api/households/${household.id}/members/${member.id}`)
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.members).toHaveLength(1);
  });

  it('should return 403 when a non-admin member tries to remove someone', async () => {
    const { admin, member, household } = await createHouseholdWithMember(app);

    const res = await request(app)
      .delete(`/api/households/${household.id}/members/${admin.id}`)
      .set(authHeader(member.accessToken));

    expect(res.status).toBe(403);
  });
});

describe('GET /api/households/:id', () => {
  it('should return 403 when the caller is not a member of the household', async () => {
    const owner = await createTestUser(app);
    const outsider = await createTestUser(app);
    const household = await createTestHousehold(app, owner);

    const res = await request(app)
      .get(`/api/households/${household.id}`)
      .set(authHeader(outsider.accessToken));

    expect(res.status).toBe(403);
    expect(res.body.error).toBe('You are not a member of this household');
  });

  it('should return 401 when no access token is provided', async () => {
    const owner = await createTestUser(app);
    const household = await createTestHousehold(app, owner);

    const res = await request(app).get(`/api/households/${household.id}`);

    expect(res.status).toBe(401);
  });
});

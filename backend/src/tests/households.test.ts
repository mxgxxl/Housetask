import { Server } from 'http';
import request from 'supertest';

import { buildTestApp } from './setup';
import {
  TestHousehold,
  authHeader,
  createHouseholdWithMember,
  createTestHousehold,
  createTestUser,
  joinTestHousehold,
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

describe('Zod edge validation on household endpoints (TD-028)', () => {
  it('should return 400 with a clear message when the name is empty (regression)', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/households')
      .set(authHeader(user.accessToken))
      .send({ name: '   ' });

    expect(res.status).toBe(400);
    expect(res.body.success).toBe(false);
    expect(res.body.error).toBe('Household name is required');
  });

  it('should return 400 (not a 500) when the name is not a string', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/households')
      .set(authHeader(user.accessToken))
      .send({ name: 12345 });

    expect(res.status).toBe(400);
    expect(res.body.success).toBe(false);
  });

  it('should return 400 when the name exceeds 100 characters', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/households')
      .set(authHeader(user.accessToken))
      .send({ name: 'x'.repeat(101) });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Household name must be at most 100 characters');
  });

  it('should return 400 with a clear message when the invite code is missing', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/households/join')
      .set(authHeader(user.accessToken))
      .send({});

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Invite code is required');
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
      (m: { user: { id: string }; role: string }) => m.user.id === member.id,
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

describe('Member-leave lifecycle (TD-018): removeMember unassigns the departed member', () => {
  async function tasksUrl(household: TestHousehold): Promise<string> {
    return `/api/households/${household.id}/tasks`;
  }

  it('should unassign the removed member from their pending tasks without deleting them', async () => {
    const { admin, member, household } = await createHouseholdWithMember(app);

    const task = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(admin.accessToken))
      .send({ title: 'Sacar la basura', assignedTo: [member.id] });
    expect(task.status).toBe(201);
    expect(task.body.data.assignedTo).toHaveLength(1);

    const removed = await request(app)
      .delete(`/api/households/${household.id}/members/${member.id}`)
      .set(authHeader(admin.accessToken));
    expect(removed.status).toBe(200);

    const list = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(admin.accessToken));
    expect(list.status).toBe(200);
    const survivor = list.body.data.items.find(
      (t: { id: string }) => t.id === task.body.data.id,
    );
    // Task must still exist (not deleted) but no longer assigned to anyone.
    expect(survivor).toBeDefined();
    expect(survivor.assignedTo).toEqual([]);
  });

  it('should keep a remaining co-assignee when only one of several assignees leaves', async () => {
    const admin = await createTestUser(app);
    const leaver = await createTestUser(app);
    const stays = await createTestUser(app);
    const household = await createTestHousehold(app, admin);
    await joinTestHousehold(app, leaver, household.inviteCode);
    await joinTestHousehold(app, stays, household.inviteCode);

    const task = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(admin.accessToken))
      .send({ title: 'Comprar leche', assignedTo: [leaver.id, stays.id] });
    expect(task.status).toBe(201);

    await request(app)
      .delete(`/api/households/${household.id}/members/${leaver.id}`)
      .set(authHeader(admin.accessToken));

    const list = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(admin.accessToken));
    const survivor = list.body.data.items.find(
      (t: { id: string }) => t.id === task.body.data.id,
    );
    expect(survivor.assignedTo).toHaveLength(1);
    expect(survivor.assignedTo[0].id).toBe(stays.id);
  });

  it('should preserve tasks created by the departing member instead of deleting them', async () => {
    const { admin, member, household } = await createHouseholdWithMember(app);

    const task = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(member.accessToken))
      .send({ title: 'Tarea creada por el que se va' });
    expect(task.status).toBe(201);

    await request(app)
      .delete(`/api/households/${household.id}/members/${member.id}`)
      .set(authHeader(admin.accessToken));

    const list = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(admin.accessToken));
    const survivor = list.body.data.items.find(
      (t: { id: string }) => t.id === task.body.data.id,
    );
    expect(survivor).toBeDefined();
    expect(survivor.createdBy.id).toBe(member.id);
  });

  it('should leave a completed task assigned to the departed member untouched (historical record)', async () => {
    const { admin, member, household } = await createHouseholdWithMember(app);

    const task = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(admin.accessToken))
      .send({ title: 'Ya hecha', assignedTo: [member.id] });
    await request(app)
      .patch(`${await tasksUrl(household)}/${task.body.data.id}/complete`)
      .set(authHeader(member.accessToken));

    await request(app)
      .delete(`/api/households/${household.id}/members/${member.id}`)
      .set(authHeader(admin.accessToken));

    const list = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(admin.accessToken));
    const survivor = list.body.data.items.find(
      (t: { id: string }) => t.id === task.body.data.id,
    );
    // Completed tasks are historical record — assignedTo is left as-is.
    expect(survivor.assignedTo).toHaveLength(1);
    expect(survivor.assignedTo[0].id).toBe(member.id);
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

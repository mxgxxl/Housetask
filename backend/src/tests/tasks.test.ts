import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { buildTestApp } from './setup';
import {
  TestHousehold,
  TestUser,
  authHeader,
  createTestHousehold,
  createTestUser,
  daysFromNow,
} from './helpers';

let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

/**
 * Shape of the task payload returned by the API (only the fields asserted here).
 */
interface TaskResponse {
  id: string;
  title: string;
  status: 'pending' | 'completed';
  dueDate?: string;
  completedAt?: string;
  completedBy?: { id: string };
  isRecurring: boolean;
  parentTaskId?: string | null;
}

async function tasksUrl(household: TestHousehold): Promise<string> {
  return `/api/households/${household.id}/tasks`;
}

async function setupHousehold(): Promise<{ user: TestUser; household: TestHousehold }> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  return { user, household };
}

async function createTask(
  user: TestUser,
  household: TestHousehold,
  body: Record<string, unknown>
): Promise<TaskResponse> {
  const res = await request(app)
    .post(await tasksUrl(household))
    .set(authHeader(user.accessToken))
    .send(body);
  expect(res.status).toBe(201);
  return res.body.data as TaskResponse;
}

describe('GET /api/households/:householdId/tasks', () => {
  it('should return 401 when no access token is provided', async () => {
    const { household } = await setupHousehold();

    const res = await request(app).get(await tasksUrl(household));

    expect(res.status).toBe(401);
  });

  it('should return 403 when the caller is not a member of the household', async () => {
    const { household } = await setupHousehold();
    const outsider = await createTestUser(app);

    const res = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(outsider.accessToken));

    expect(res.status).toBe(403);
  });

  it('should return 200 with an empty array when the household has no tasks', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.items).toEqual([]);
  });

  it('should return only pending tasks when filtering by status=pending', async () => {
    const { user, household } = await setupHousehold();
    await createTask(user, household, { title: 'Still pending' });
    const done = await createTask(user, household, { title: 'Already done' });
    await request(app)
      .patch(`${await tasksUrl(household)}/${done.id}/complete`)
      .set(authHeader(user.accessToken));

    const res = await request(app)
      .get(await tasksUrl(household))
      .query({ status: 'pending' })
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.items).toHaveLength(1);
    expect(res.body.data.items[0].title).toBe('Still pending');
  });

  it('should return 400 for an unsupported status filter', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .get(await tasksUrl(household))
      .query({ status: 'archived' })
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(400);
  });

  it('should sort pending tasks before completed ones, then by dueDate ascending', async () => {
    const { user, household } = await setupHousehold();
    const later = await createTask(user, household, { title: 'Later', dueDate: daysFromNow(5) });
    const sooner = await createTask(user, household, { title: 'Sooner', dueDate: daysFromNow(1) });
    const finished = await createTask(user, household, {
      title: 'Finished',
      dueDate: daysFromNow(0),
    });
    await request(app)
      .patch(`${await tasksUrl(household)}/${finished.id}/complete`)
      .set(authHeader(user.accessToken));

    const res = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    const ids = (res.body.data.items as TaskResponse[]).map((t) => t.id);
    // Completed goes last even though its dueDate is the earliest.
    expect(ids).toEqual([sooner.id, later.id, finished.id]);
  });
});

describe('GET /api/households/:householdId/tasks — pagination', () => {
  /**
   * 12 tasks with deliberately unsorted dueDates and a mix of statuses, so a
   * cursor that only carried _id would visibly skip or repeat rows.
   */
  async function seedTwelve(
    user: TestUser,
    household: TestHousehold
  ): Promise<void> {
    const offsets = [7, 2, 11, 0, 5, 9, 1, 8, 3, 10, 4, 6];
    for (let i = 0; i < offsets.length; i++) {
      const task = await createTask(user, household, {
        title: `Task ${i}`,
        dueDate: daysFromNow(offsets[i]),
      });
      // Every third task is completed, so the status key actually varies.
      if (i % 3 === 0) {
        await request(app)
          .patch(`${await tasksUrl(household)}/${task.id}/complete`)
          .set(authHeader(user.accessToken));
      }
    }
  }

  it('should walk every page with nextCursor covering all rows exactly once, in global order', async () => {
    const { user, household } = await setupHousehold();
    await seedTwelve(user, household);

    const full = await request(app)
      .get(await tasksUrl(household))
      .query({ limit: 100 })
      .set(authHeader(user.accessToken));
    const expected = (full.body.data.items as TaskResponse[]).map((t) => t.id);
    expect(expected).toHaveLength(12);

    const walked: TaskResponse[] = [];
    let cursor: string | null = null;
    let pages = 0;

    for (;;) {
      const query: Record<string, string> = { limit: '5' };
      if (cursor) query.cursor = cursor;

      const res = await request(app)
        .get(await tasksUrl(household))
        .query(query)
        .set(authHeader(user.accessToken));

      expect(res.status).toBe(200);
      expect(res.body.data.total).toBe(12);
      walked.push(...(res.body.data.items as TaskResponse[]));
      pages += 1;

      if (!res.body.data.hasMore) {
        expect(res.body.data.nextCursor).toBeNull();
        break;
      }
      cursor = res.body.data.nextCursor as string;
      expect(typeof cursor).toBe('string');
      expect(pages).toBeLessThan(10); // guard against a cursor that never advances
    }

    const walkedIds = walked.map((t) => t.id);
    expect(pages).toBe(3);
    // No omissions, no duplicates, and identical order to the unpaginated read.
    expect(walkedIds).toEqual(expected);
    expect(new Set(walkedIds).size).toBe(12);

    // Global ordering: every pending task precedes every completed one, and
    // dueDate ascends within each status block.
    const statuses = walked.map((t) => t.status);
    expect(statuses.indexOf('completed')).toBeGreaterThan(statuses.lastIndexOf('pending'));
    for (const status of ['pending', 'completed'] as const) {
      const dues = walked.filter((t) => t.status === status).map((t) => Date.parse(t.dueDate!));
      expect(dues).toEqual([...dues].sort((a, b) => a - b));
    }
  });

  it('should combine the status filter with the cursor and report a filtered total', async () => {
    const { user, household } = await setupHousehold();
    await seedTwelve(user, household);

    const first = await request(app)
      .get(await tasksUrl(household))
      .query({ status: 'pending', limit: '5' })
      .set(authHeader(user.accessToken));

    expect(first.status).toBe(200);
    // 4 of the 12 were completed (i % 3 === 0), so 8 remain pending.
    expect(first.body.data.total).toBe(8);
    expect(first.body.data.items).toHaveLength(5);
    expect(first.body.data.hasMore).toBe(true);

    const second = await request(app)
      .get(await tasksUrl(household))
      .query({ status: 'pending', limit: '5', cursor: first.body.data.nextCursor })
      .set(authHeader(user.accessToken));

    expect(second.body.data.total).toBe(8);
    expect(second.body.data.items).toHaveLength(3);
    expect(second.body.data.hasMore).toBe(false);
    expect(second.body.data.nextCursor).toBeNull();
    (second.body.data.items as TaskResponse[]).forEach((t) => expect(t.status).toBe('pending'));
  });

  it('should return an empty page with hasMore false and nextCursor null', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .get(await tasksUrl(household))
      .query({ limit: '5' })
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({ items: [], nextCursor: null, hasMore: false, total: 0 });
  });

  it('should reject limits outside 1..100 and malformed cursors with 400', async () => {
    const { user, household } = await setupHousehold();
    const url = await tasksUrl(household);
    const auth = authHeader(user.accessToken);

    const zero = await request(app).get(url).query({ limit: '0' }).set(auth);
    const tooBig = await request(app).get(url).query({ limit: '101' }).set(auth);
    const garbage = await request(app).get(url).query({ cursor: 'garbage' }).set(auth);

    expect(zero.status).toBe(400);
    expect(tooBig.status).toBe(400);
    expect(garbage.status).toBe(400);
    expect(garbage.body.error).toBe('Invalid cursor');
    expect(garbage.body.success).toBe(false);
  });
});

describe('POST /api/households/:householdId/tasks', () => {
  it('should reject a body over the 100kb limit with a 413 envelope, not a 500', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(user.accessToken))
      .send({ title: 'Enorme', description: 'x'.repeat(200 * 1024) });

    expect(res.status).toBe(413);
    expect(res.body.success).toBe(false);
    expect(res.body.error).toBe('Payload too large');
  });

  it('should create a task and return 201 with the persisted payload', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(user.accessToken))
      .send({ title: 'Sacar la basura', priority: 'high', category: 'cleaning' });

    expect(res.status).toBe(201);
    expect(res.body.data.title).toBe('Sacar la basura');
    expect(res.body.data.status).toBe('pending');
    expect(res.body.data.priority).toBe('high');
    expect(res.body.data.id).toBeDefined();
  });

  it('should return 400 when the title is empty', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(user.accessToken))
      .send({ title: '   ' });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Task title is required');
  });
});

describe('PATCH /api/households/:householdId/tasks/:taskId/complete', () => {
  it('should set completedAt and completedBy when a task is completed', async () => {
    const { user, household } = await setupHousehold();
    const task = await createTask(user, household, { title: 'Fregar' });

    const res = await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}/complete`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('completed');
    expect(res.body.data.completedAt).toBeDefined();
    expect(res.body.data.completedBy.id).toBe(user.id);
  });

  it('should generate the next pending occurrence when a recurring task is completed', async () => {
    const { user, household } = await setupHousehold();
    const dueDate = daysFromNow(0);
    const task = await createTask(user, household, {
      title: 'Regar las plantas',
      dueDate,
      isRecurring: true,
      recurrenceRule: { type: 'daily', interval: 1 },
    });

    await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}/complete`)
      .set(authHeader(user.accessToken));

    const res = await request(app)
      .get(await tasksUrl(household))
      .query({ status: 'pending' })
      .set(authHeader(user.accessToken));

    expect(res.body.data.items).toHaveLength(1);
    const next = res.body.data.items[0] as TaskResponse;
    expect(next.title).toBe('Regar las plantas');
    expect(next.id).not.toBe(task.id);
    expect(next.parentTaskId).toBe(task.id);
    // One day after the source task's due date.
    const delta = new Date(next.dueDate!).getTime() - new Date(dueDate).getTime();
    expect(Math.round(delta / (24 * 60 * 60 * 1000))).toBe(1);
  });

  it('should not create a duplicate when a pending task with the same title already exists within the ±1 day window', async () => {
    const { user, household } = await setupHousehold();
    const dueDate = daysFromNow(0);

    const recurring = await createTask(user, household, {
      title: 'Sacar reciclaje',
      dueDate,
      isRecurring: true,
      recurrenceRule: { type: 'daily', interval: 1 },
    });
    // Already-planned occurrence sitting exactly on the next due date.
    await createTask(user, household, { title: 'Sacar reciclaje', dueDate: daysFromNow(1) });

    const before = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(user.accessToken));
    const countBefore = (before.body.data.items as TaskResponse[]).filter(
      (t) => t.title === 'Sacar reciclaje'
    ).length;

    await request(app)
      .patch(`${await tasksUrl(household)}/${recurring.id}/complete`)
      .set(authHeader(user.accessToken));

    const after = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(user.accessToken));
    const countAfter = (after.body.data.items as TaskResponse[]).filter(
      (t) => t.title === 'Sacar reciclaje'
    ).length;

    expect(countBefore).toBe(2);
    expect(countAfter).toBe(countBefore);
  });
});

describe('DELETE /api/households/:householdId/tasks/:taskId', () => {
  it('should return 404 for a task id that does not exist', async () => {
    const { user, household } = await setupHousehold();
    const missingId = new Types.ObjectId().toString();

    const res = await request(app)
      .delete(`${await tasksUrl(household)}/${missingId}`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Task not found');
  });

  it('should delete an existing task', async () => {
    const { user, household } = await setupHousehold();
    const task = await createTask(user, household, { title: 'Temporal' });

    const res = await request(app)
      .delete(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);

    const list = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(user.accessToken));
    expect(list.body.data.items).toEqual([]);
  });
});

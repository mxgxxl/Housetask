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
  hoursFromNow,
  joinTestHousehold,
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
  startsAt?: string;
  endsAt?: string;
  completedAt?: string;
  completedBy?: { id: string; name?: string };
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
  body: Record<string, unknown>,
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

  it('should include completedBy populated with the completer name in the list payload', async () => {
    const { user, household } = await setupHousehold();
    const task = await createTask(user, household, { title: 'Finish me' });
    await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}/complete`)
      .set(authHeader(user.accessToken));

    const res = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    const items = res.body.data.items as TaskResponse[];
    const completed = items.find((t) => t.id === task.id);
    // The frontend TaskTile (PDR-002) needs the name inline — not just an id
    // it would have to resolve against a second endpoint.
    expect(completed?.completedBy).toMatchObject({ id: user.id, name: user.name });
  });
});

describe('GET /api/households/:householdId/tasks — pagination', () => {
  /**
   * 12 tasks with deliberately unsorted dueDates and a mix of statuses, so a
   * cursor that only carried _id would visibly skip or repeat rows.
   */
  async function seedTwelve(user: TestUser, household: TestHousehold): Promise<void> {
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
      // total only on the first page; later pages return null (ADR-008).
      expect(res.body.data.total).toBe(cursor ? null : 12);
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

    expect(second.body.data.total).toBeNull();
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

describe('GET /api/households/:householdId/tasks — date-range filtering (PDR-003)', () => {
  it('should return dated tasks within [from, to] and exclude tasks outside the window', async () => {
    const { user, household } = await setupHousehold();
    const before = await createTask(user, household, {
      title: 'Before',
      dueDate: daysFromNow(-10),
    });
    const within = await createTask(user, household, { title: 'Within', dueDate: daysFromNow(0) });
    const after = await createTask(user, household, { title: 'After', dueDate: daysFromNow(10) });

    const res = await request(app)
      .get(await tasksUrl(household))
      .query({ from: daysFromNow(-2), to: daysFromNow(2) })
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    const ids = (res.body.data.items as TaskResponse[]).map((t) => t.id);
    expect(ids).toContain(within.id);
    expect(ids).not.toContain(before.id);
    expect(ids).not.toContain(after.id);
  });

  it('should always include undated tasks in a from/to window (PDR-003 "Sin fecha" bucket)', async () => {
    const { user, household } = await setupHousehold();
    const within = await createTask(user, household, { title: 'Within', dueDate: daysFromNow(0) });
    const outside = await createTask(user, household, {
      title: 'Outside',
      dueDate: daysFromNow(10),
    });
    const undated = await createTask(user, household, { title: 'Sin fecha' });

    const res = await request(app)
      .get(await tasksUrl(household))
      .query({ from: daysFromNow(-2), to: daysFromNow(2) })
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    const ids = (res.body.data.items as TaskResponse[]).map((t) => t.id);
    // Undated tasks have no day to place on the client's timeline, so they
    // always surface ("para que nada se pierda") regardless of the window —
    // the client buckets them into "Sin fecha" instead of dropping them.
    expect(ids).toContain(within.id);
    expect(ids).toContain(undated.id);
    expect(ids).not.toContain(outside.id);
  });

  it('should combine the status filter with the from/to window', async () => {
    const { user, household } = await setupHousehold();
    const pendingWithin = await createTask(user, household, {
      title: 'Pending within',
      dueDate: daysFromNow(0),
    });
    const completedWithin = await createTask(user, household, {
      title: 'Completed within',
      dueDate: daysFromNow(1),
    });
    await request(app)
      .patch(`${await tasksUrl(household)}/${completedWithin.id}/complete`)
      .set(authHeader(user.accessToken));
    const pendingOutside = await createTask(user, household, {
      title: 'Pending outside',
      dueDate: daysFromNow(10),
    });

    const res = await request(app)
      .get(await tasksUrl(household))
      .query({ status: 'pending', from: daysFromNow(-2), to: daysFromNow(2) })
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    const ids = (res.body.data.items as TaskResponse[]).map((t) => t.id);
    expect(ids).toEqual([pendingWithin.id]);
    expect(ids).not.toContain(completedWithin.id);
    expect(ids).not.toContain(pendingOutside.id);
  });

  it('should paginate a from/to window with the cursor without overlap or gaps', async () => {
    const { user, household } = await setupHousehold();
    const offsets = [3, 1, 6, 0, 4, 2, 5];
    const created = [];
    for (const offset of offsets) {
      created.push(
        await createTask(user, household, { title: `Day ${offset}`, dueDate: daysFromNow(offset) }),
      );
    }
    // Well outside the window, must never appear in any page.
    await createTask(user, household, { title: 'Far future', dueDate: daysFromNow(100) });

    const query = { from: daysFromNow(-1), to: daysFromNow(7) };
    const full = await request(app)
      .get(await tasksUrl(household))
      .query({ ...query, limit: 100 })
      .set(authHeader(user.accessToken));
    const expected = (full.body.data.items as TaskResponse[]).map((t) => t.id);
    expect(expected).toHaveLength(offsets.length);

    const walked: string[] = [];
    let cursor: string | null = null;
    let pages = 0;
    for (;;) {
      const pageQuery: Record<string, string> = { ...query, limit: '3' };
      if (cursor) pageQuery.cursor = cursor;

      const res = await request(app)
        .get(await tasksUrl(household))
        .query(pageQuery)
        .set(authHeader(user.accessToken));

      expect(res.status).toBe(200);
      walked.push(...(res.body.data.items as TaskResponse[]).map((t) => t.id));
      pages += 1;

      if (!res.body.data.hasMore) break;
      cursor = res.body.data.nextCursor as string;
      expect(pages).toBeLessThan(10);
    }

    expect(pages).toBe(3);
    expect(walked).toEqual(expected);
    expect(new Set(walked).size).toBe(offsets.length);
  });

  it('should behave exactly as before when from/to are absent', async () => {
    const { user, household } = await setupHousehold();
    const dated = await createTask(user, household, { title: 'Dated', dueDate: daysFromNow(0) });
    const farFuture = await createTask(user, household, {
      title: 'Far future',
      dueDate: daysFromNow(365),
    });
    const undated = await createTask(user, household, { title: 'Sin fecha' });

    const res = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    const ids = (res.body.data.items as TaskResponse[]).map((t) => t.id);
    expect(ids).toEqual(expect.arrayContaining([dated.id, farFuture.id, undated.id]));
    expect(ids).toHaveLength(3);
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

describe('startsAt/endsAt — optional task duration (PDR-004)', () => {
  it('should create a task with a valid startsAt/endsAt range', async () => {
    const { user, household } = await setupHousehold();
    const startsAt = hoursFromNow(1);
    const endsAt = hoursFromNow(3);

    const res = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(user.accessToken))
      .send({ title: 'Pintar el salón', startsAt, endsAt });

    expect(res.status).toBe(201);
    expect(new Date(res.body.data.startsAt).toISOString()).toBe(new Date(startsAt).toISOString());
    expect(new Date(res.body.data.endsAt).toISOString()).toBe(new Date(endsAt).toISOString());
  });

  it('should reject endsAt <= startsAt with 400', async () => {
    const { user, household } = await setupHousehold();

    const sameInstant = hoursFromNow(2);
    const same = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(user.accessToken))
      .send({ title: 'Rango inválido (igual)', startsAt: sameInstant, endsAt: sameInstant });
    expect(same.status).toBe(400);
    expect(same.body.error).toBe('endsAt must be after startsAt');

    const before = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(user.accessToken))
      .send({
        title: 'Rango inválido (invertido)',
        startsAt: hoursFromNow(3),
        endsAt: hoursFromNow(1),
      });
    expect(before.status).toBe(400);
    expect(before.body.error).toBe('endsAt must be after startsAt');
  });

  it('should allow a start-only task (no endsAt)', async () => {
    const { user, household } = await setupHousehold();
    const startsAt = hoursFromNow(1);

    const res = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(user.accessToken))
      .send({ title: 'Solo inicio', startsAt });

    expect(res.status).toBe(201);
    expect(new Date(res.body.data.startsAt).toISOString()).toBe(new Date(startsAt).toISOString());
    expect(res.body.data.endsAt).toBeUndefined();
  });

  it('should ignore startsAt/endsAt on a recurring task', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .post(await tasksUrl(household))
      .set(authHeader(user.accessToken))
      .send({
        title: 'Serie recurrente',
        startsAt: hoursFromNow(1),
        endsAt: hoursFromNow(3),
        isRecurring: true,
        recurrenceRule: { type: 'daily', interval: 1 },
      });

    expect(res.status).toBe(201);
    expect(res.body.data.isRecurring).toBe(true);
    expect(res.body.data.startsAt).toBeUndefined();
    expect(res.body.data.endsAt).toBeUndefined();
  });

  it('GET should return startsAt/endsAt when present', async () => {
    const { user, household } = await setupHousehold();
    const startsAt = hoursFromNow(1);
    const endsAt = hoursFromNow(3);
    const created = await createTask(user, household, {
      title: 'Con duración',
      startsAt,
      endsAt,
    });

    const res = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    const found = (res.body.data.items as TaskResponse[]).find((t) => t.id === created.id);
    expect(new Date(found!.startsAt!).toISOString()).toBe(new Date(startsAt).toISOString());
    expect(new Date(found!.endsAt!).toISOString()).toBe(new Date(endsAt).toISOString());
  });

  it('should reject a PATCH that would make endsAt <= startsAt', async () => {
    const { user, household } = await setupHousehold();
    const task = await createTask(user, household, {
      title: 'Editable',
      startsAt: hoursFromNow(1),
      endsAt: hoursFromNow(3),
    });

    const res = await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(user.accessToken))
      // Only endsAt is sent — validated against the task's EXISTING startsAt.
      .send({ endsAt: hoursFromNow(0) });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('endsAt must be after startsAt');
  });

  it('should clear startsAt/endsAt when a PATCH flips a task to recurring', async () => {
    const { user, household } = await setupHousehold();
    const task = await createTask(user, household, {
      title: 'A punto de ser recurrente',
      startsAt: hoursFromNow(1),
      endsAt: hoursFromNow(3),
    });

    const res = await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(user.accessToken))
      .send({ isRecurring: true, recurrenceRule: { type: 'daily', interval: 1 } });

    expect(res.status).toBe(200);
    expect(res.body.data.isRecurring).toBe(true);
    expect(res.body.data.startsAt).toBeUndefined();
    expect(res.body.data.endsAt).toBeUndefined();
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
      (t) => t.title === 'Sacar reciclaje',
    ).length;

    await request(app)
      .patch(`${await tasksUrl(household)}/${recurring.id}/complete`)
      .set(authHeader(user.accessToken));

    const after = await request(app)
      .get(await tasksUrl(household))
      .set(authHeader(user.accessToken));
    const countAfter = (after.body.data.items as TaskResponse[]).filter(
      (t) => t.title === 'Sacar reciclaje',
    ).length;

    expect(countBefore).toBe(2);
    expect(countAfter).toBe(countBefore);
  });
});

describe('PATCH /api/households/:householdId/tasks/:taskId — status transitions', () => {
  it('should set completedAt and completedBy when status moves to completed', async () => {
    const { user, household } = await setupHousehold();
    const task = await createTask(user, household, { title: 'Planchar' });

    const res = await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(user.accessToken))
      .send({ status: 'completed' });

    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('completed');
    expect(res.body.data.completedAt).toBeDefined();
    expect(res.body.data.completedBy.id).toBe(user.id);
  });

  it('should clear completion metadata when status moves back to pending', async () => {
    const { user, household } = await setupHousehold();
    const task = await createTask(user, household, { title: 'Reabrir' });
    await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(user.accessToken))
      .send({ status: 'completed' });

    const res = await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(user.accessToken))
      .send({ status: 'pending' });

    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('pending');
    // Stale completion metadata on a pending task would corrupt any later
    // "who finished this?" read.
    expect(res.body.data.completedAt).toBeUndefined();
    expect(res.body.data.completedBy).toBeUndefined();
  });

  it('should leave completion metadata untouched when status is not part of the update', async () => {
    const { user, household } = await setupHousehold();
    const task = await createTask(user, household, { title: 'Intacta' });
    const completed = await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}/complete`)
      .set(authHeader(user.accessToken));
    const completedAt = completed.body.data.completedAt as string;

    const res = await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Intacta renombrada', priority: 'high' });

    expect(res.status).toBe(200);
    expect(res.body.data.title).toBe('Intacta renombrada');
    expect(res.body.data.status).toBe('completed');
    expect(res.body.data.completedAt).toBe(completedAt);
    expect(res.body.data.completedBy.id).toBe(user.id);
  });
});

describe('POST /api/households/:householdId/tasks/generate-instances', () => {
  /**
   * Seed a completed recurring series with no pending successor.
   *
   * Completing a recurring task immediately generates its next occurrence, and
   * that pending row would trip the ±1-day duplicate guard on the first
   * catch-up iteration, so it is removed to model a series that fell behind.
   */
  async function seedLapsedSeries(
    user: TestUser,
    household: TestHousehold,
    dueDate: string,
    intervalDays: number,
  ): Promise<void> {
    const url = await tasksUrl(household);
    const task = await createTask(user, household, {
      title: 'Serie atrasada',
      dueDate,
      isRecurring: true,
      recurrenceRule: { type: 'daily', interval: intervalDays },
    });
    await request(app).patch(`${url}/${task.id}/complete`).set(authHeader(user.accessToken));

    const pending = await request(app)
      .get(url)
      .query({ status: 'pending', limit: 100 })
      .set(authHeader(user.accessToken));
    for (const stale of pending.body.data.items as TaskResponse[]) {
      await request(app).delete(`${url}/${stale.id}`).set(authHeader(user.accessToken));
    }
  }

  it('should generate exactly the missed occurrences up to the horizon', async () => {
    const { user, household } = await setupHousehold();
    // Weekly cadence 21 days back: occurrences fall at -14, -7 and today.
    await seedLapsedSeries(user, household, daysFromNow(-21), 7);

    const res = await request(app)
      .post(`${await tasksUrl(household)}/generate-instances`)
      .set(authHeader(user.accessToken))
      .send({});

    expect(res.status).toBe(200);
    expect(res.body.data.generated).toBe(3);
  });

  it('should be idempotent: a second consecutive catch-up generates nothing', async () => {
    const { user, household } = await setupHousehold();
    await seedLapsedSeries(user, household, daysFromNow(-21), 7);
    const url = `${await tasksUrl(household)}/generate-instances`;

    const first = await request(app).post(url).set(authHeader(user.accessToken)).send({});
    const second = await request(app).post(url).set(authHeader(user.accessToken)).send({});

    expect(first.body.data.generated).toBe(3);
    // The ±1-day duplicate guard stops the walk on the first already-planned
    // occurrence, so re-entering a household never multiplies its tasks.
    expect(second.body.data.generated).toBe(0);
  });

  it('should cap generation at 52 iterations however wide the horizon is', async () => {
    const { user, household } = await setupHousehold();
    await seedLapsedSeries(user, household, daysFromNow(0), 7);

    const res = await request(app)
      .post(`${await tasksUrl(household)}/generate-instances`)
      .set(authHeader(user.accessToken))
      .send({ upTo: daysFromNow(3650) });

    expect(res.status).toBe(200);
    // Without the cap a ten-year horizon would create ~520 rows in one request.
    expect(res.body.data.generated).toBeLessThanOrEqual(52);
    expect(res.body.data.generated).toBe(52);
  });

  it('should return 400 for an unparseable upTo', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .post(`${await tasksUrl(household)}/generate-instances`)
      .set(authHeader(user.accessToken))
      .send({ upTo: 'not-a-date' });

    expect(res.status).toBe(400);
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

describe('Task permissions — creator-or-admin for edit/delete (TD-011)', () => {
  /**
   * Three distinct roles in one household: the admin (household creator),
   * a regular member who will create the task under test, and a second
   * regular member who is neither its creator nor an admin.
   */
  async function setupThreeMemberHousehold(): Promise<{
    admin: TestUser;
    userA: TestUser;
    userB: TestUser;
    household: TestHousehold;
  }> {
    const admin = await createTestUser(app);
    const userA = await createTestUser(app);
    const userB = await createTestUser(app);
    const household = await createTestHousehold(app, admin);
    await joinTestHousehold(app, userA, household.inviteCode);
    await joinTestHousehold(app, userB, household.inviteCode);
    return { admin, userA, userB, household };
  }

  it('should return 403 when a non-creator, non-admin member tries to edit the task', async () => {
    const { userA, userB, household } = await setupThreeMemberHousehold();
    const task = await createTask(userA, household, { title: 'De A' });

    const res = await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(userB.accessToken))
      .send({ title: 'Intento de B' });

    expect(res.status).toBe(403);
    expect(res.body.error).toBe('You do not have permission to modify this task');
  });

  it('should let the creator edit their own task', async () => {
    const { userA, household } = await setupThreeMemberHousehold();
    const task = await createTask(userA, household, { title: 'De A' });

    const res = await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(userA.accessToken))
      .send({ title: 'Editada por A' });

    expect(res.status).toBe(200);
    expect(res.body.data.title).toBe('Editada por A');
  });

  it('should let an admin edit a task created by someone else', async () => {
    const { admin, userA, household } = await setupThreeMemberHousehold();
    const task = await createTask(userA, household, { title: 'De A' });

    const res = await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(admin.accessToken))
      .send({ title: 'Editada por admin' });

    expect(res.status).toBe(200);
    expect(res.body.data.title).toBe('Editada por admin');
  });

  it('should let any member complete a task they did not create', async () => {
    const { userA, userB, household } = await setupThreeMemberHousehold();
    const task = await createTask(userA, household, { title: 'De A' });

    const res = await request(app)
      .patch(`${await tasksUrl(household)}/${task.id}/complete`)
      .set(authHeader(userB.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.status).toBe('completed');
  });

  it('should return 403 when a non-creator, non-admin member tries to delete the task, and let an admin delete it', async () => {
    const { admin, userA, userB, household } = await setupThreeMemberHousehold();
    const task = await createTask(userA, household, { title: 'De A' });

    const forbidden = await request(app)
      .delete(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(userB.accessToken));
    expect(forbidden.status).toBe(403);
    expect(forbidden.body.error).toBe('You do not have permission to modify this task');

    const allowed = await request(app)
      .delete(`${await tasksUrl(household)}/${task.id}`)
      .set(authHeader(admin.accessToken));
    expect(allowed.status).toBe(200);
  });
});

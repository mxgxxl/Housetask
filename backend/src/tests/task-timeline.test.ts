import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { TaskModel } from '../models/Task';
import { buildTestApp } from './setup';
import {
  TestHousehold,
  TestUser,
  authHeader,
  createHouseholdWithMember,
  createTestHousehold,
  createTestUser,
} from './helpers';

/**
 * TD-064: the keyset timeline reads.
 *
 * What these pin is the property the old `GET /tasks?from=&to=` walk could not
 * offer: a cursor that never revisits ground. The previous flow re-fetched page
 * one of an ever-widening window, so every page re-scanned everything already
 * seen plus every undated task — correct on screen, thanks to a client-side
 * merge by id, but paying more the further you scrolled.
 *
 * The interesting cases are therefore not "does it return tasks" but: does a
 * full walk hit every task exactly once when dates TIE, does a cursor survive
 * writes landing between pages, and does a cursor from a different query get
 * rejected instead of silently resuming at a coordinate that means something
 * else.
 */
let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

const BASE = new Date('2026-09-01T09:00:00.000Z');
const iso = (d: Date) => d.toISOString();
const plusDays = (n: number) => new Date(BASE.getTime() + n * 86_400_000);

interface TaskPayload {
  id: string;
  title: string;
  dueDate?: string | null;
}

interface PageBody {
  items: TaskPayload[];
  nextCursor: string | null;
  hasMore: boolean;
  total: number | null;
}

/**
 * Seed directly through the model: these tests need controlled dueDates and
 * deliberate ties, which the create endpoint's own defaults would blur.
 */
async function seedTask(
  household: TestHousehold,
  user: TestUser,
  title: string,
  dueDate: Date | null,
  extra: Record<string, unknown> = {},
): Promise<string> {
  const task = await TaskModel.create({
    householdId: new Types.ObjectId(household.id),
    title,
    createdBy: new Types.ObjectId(user.id),
    dueDate,
    ...extra,
  });
  return task._id.toString();
}

async function getTimeline(
  household: TestHousehold,
  user: TestUser,
  query: Record<string, string>,
): Promise<{ status: number; body: { data: PageBody; error?: string } }> {
  const res = await request(app)
    .get(`/api/households/${household.id}/tasks/timeline`)
    .query(query)
    .set(authHeader(user.accessToken));
  return { status: res.status, body: res.body };
}

/** Walk every page, returning the ids in the order the server produced them. */
async function walkTimeline(
  household: TestHousehold,
  user: TestUser,
  from: string,
  limit: number,
): Promise<string[]> {
  const seen: string[] = [];
  let cursor: string | null = null;
  // Bounded so a cursor bug becomes a failed assertion instead of a hung suite.
  for (let page = 0; page < 20; page += 1) {
    const query: Record<string, string> = { from, limit: String(limit) };
    if (cursor) query.cursor = cursor;
    const res = await getTimeline(household, user, query);
    expect(res.status).toBe(200);
    seen.push(...res.body.data.items.map((t) => t.id));
    if (!res.body.data.hasMore) return seen;
    cursor = res.body.data.nextCursor;
    expect(cursor).not.toBeNull();
  }
  throw new Error('timeline did not terminate within 20 pages');
}

describe('GET /tasks/timeline', () => {
  it('should return dated tasks ordered by dueDate, excluding undated ones', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    const third = await seedTask(household, user, 'tercera', plusDays(3));
    const first = await seedTask(household, user, 'primera', plusDays(1));
    const second = await seedTask(household, user, 'segunda', plusDays(2));
    await seedTask(household, user, 'sin fecha', null);

    const res = await getTimeline(household, user, { from: iso(BASE) });

    expect(res.status).toBe(200);
    expect(res.body.data.items.map((t) => t.id)).toEqual([first, second, third]);
    expect(res.body.data.total).toBe(3);
    expect(res.body.data.hasMore).toBe(false);
    expect(res.body.data.nextCursor).toBeNull();
  });

  it('should visit every task exactly once when dueDates tie', async () => {
    // The case an id-less cursor gets wrong: with five tasks sharing a date,
    // a cursor carrying only dueDate either repeats the whole group or skips
    // past it. The `_id` tiebreaker is what makes the order total.
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    const sameDay = plusDays(1);
    const ids = [];
    for (let i = 0; i < 5; i += 1) {
      ids.push(await seedTask(household, user, `empate ${i}`, sameDay));
    }

    const walked = await walkTimeline(household, user, iso(BASE), 2);

    expect(walked).toHaveLength(5);
    expect(new Set(walked).size).toBe(5);
    expect([...walked].sort()).toEqual([...ids].sort());
  });

  it('should paginate a mixed set without gaps or duplicates', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    const created: string[] = [];
    for (let day = 1; day <= 4; day += 1) {
      for (let n = 0; n < 3; n += 1) {
        created.push(await seedTask(household, user, `d${day}-${n}`, plusDays(day)));
      }
    }

    const walked = await walkTimeline(household, user, iso(BASE), 5);

    expect(walked).toHaveLength(12);
    expect(new Set(walked).size).toBe(12);
    expect([...walked].sort()).toEqual([...created].sort());
  });

  it('should exclude tasks before `from` and soft-deleted ones', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    await seedTask(household, user, 'anterior', plusDays(-5));
    const inside = await seedTask(household, user, 'dentro', plusDays(2));
    await seedTask(household, user, 'borrada', plusDays(3), {
      isDeleted: true,
      deletedAt: new Date(),
    });

    const res = await getTimeline(household, user, { from: iso(BASE) });

    expect(res.body.data.items.map((t) => t.id)).toEqual([inside]);
    expect(res.body.data.total).toBe(1);
  });

  it('should ignore a write that lands BEHIND the cursor', async () => {
    // The property offset pagination cannot give: a cursor is a position in an
    // order, not a row number, so an insertion before it must not shift what
    // comes next. Under offset paging this row would push everything down one
    // and the next page would repeat a task the client already has.
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    const day2 = await seedTask(household, user, 'dia 2', plusDays(2));
    const day3 = await seedTask(household, user, 'dia 3', plusDays(3));

    const firstPage = await getTimeline(household, user, { from: iso(BASE), limit: '1' });
    expect(firstPage.body.data.items.map((t) => t.id)).toEqual([day2]);

    // Earlier than the cursor's position, so already passed.
    await seedTask(household, user, 'insertada detras', plusDays(1));

    const second = await getTimeline(household, user, {
      from: iso(BASE),
      limit: '1',
      cursor: firstPage.body.data.nextCursor!,
    });

    expect(second.body.data.items.map((t) => t.id)).toEqual([day3]);
    expect(second.body.data.hasMore).toBe(false);
  });

  it('should pick up a write that lands AHEAD of the cursor', async () => {
    // The complement, and equally deliberate: the walk is over live data, so
    // work scheduled into a stretch not yet reached belongs in it. Suppressing
    // it would need a snapshot the design explicitly does not take.
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    const day1 = await seedTask(household, user, 'dia 1', plusDays(1));
    const day4 = await seedTask(household, user, 'dia 4', plusDays(4));

    const firstPage = await getTimeline(household, user, { from: iso(BASE), limit: '1' });
    expect(firstPage.body.data.items.map((t) => t.id)).toEqual([day1]);

    const day2 = await seedTask(household, user, 'insertada delante', plusDays(2));

    const rest: string[] = [];
    let cursor = firstPage.body.data.nextCursor;
    while (cursor) {
      const res = await getTimeline(household, user, { from: iso(BASE), limit: '1', cursor });
      rest.push(...res.body.data.items.map((t) => t.id));
      cursor = res.body.data.hasMore ? res.body.data.nextCursor : null;
    }

    expect(rest).toEqual([day2, day4]);
  });

  it('should only count `total` on the first page', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    await seedTask(household, user, 'a', plusDays(1));
    await seedTask(household, user, 'b', plusDays(2));

    const first = await getTimeline(household, user, { from: iso(BASE), limit: '1' });
    expect(first.body.data.total).toBe(2);

    const second = await getTimeline(household, user, {
      from: iso(BASE),
      limit: '1',
      cursor: first.body.data.nextCursor!,
    });
    expect(second.body.data.total).toBeNull();
  });

  describe('cursor validation', () => {
    it('should reject a cursor issued for a different `from`', async () => {
      // The silent-corruption case: the same coordinate means a different
      // position in a differently-bounded walk, so resuming it would skip or
      // repeat rows with nothing anywhere reporting a problem.
      const user = await createTestUser(app);
      const household = await createTestHousehold(app, user);
      await seedTask(household, user, 'a', plusDays(1));
      await seedTask(household, user, 'b', plusDays(2));

      const first = await getTimeline(household, user, { from: iso(BASE), limit: '1' });
      const cursor = first.body.data.nextCursor!;

      const replayed = await getTimeline(household, user, {
        from: iso(plusDays(1)),
        limit: '1',
        cursor,
      });

      expect(replayed.status).toBe(400);
      expect(replayed.body.error).toBe('Cursor does not belong to this timeline query');
    });

    it('should reject a malformed cursor', async () => {
      const user = await createTestUser(app);
      const household = await createTestHousehold(app, user);

      const res = await getTimeline(household, user, { from: iso(BASE), cursor: 'no-base64!!' });
      expect(res.status).toBe(400);
    });

    it('should require `from`', async () => {
      const user = await createTestUser(app);
      const household = await createTestHousehold(app, user);

      const res = await getTimeline(household, user, {});
      expect(res.status).toBe(400);
      expect(res.body.error).toBe('from is required');
    });
  });

  it('should refuse a caller who is not a member', async () => {
    const { household } = await createHouseholdWithMember(app);
    const outsider = await createTestUser(app);

    const res = await getTimeline(household, outsider, { from: iso(BASE) });
    expect(res.status).toBe(403);
  });
});

describe('GET /tasks/undated', () => {
  const getUndated = (household: TestHousehold, user: TestUser, query: Record<string, string>) =>
    request(app)
      .get(`/api/households/${household.id}/tasks/undated`)
      .query(query)
      .set(authHeader(user.accessToken));

  it('should return only undated, active tasks', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    await seedTask(household, user, 'fechada', plusDays(1));
    const undated = await seedTask(household, user, 'sin fecha', null);
    await seedTask(household, user, 'sin fecha borrada', null, {
      isDeleted: true,
      deletedAt: new Date(),
    });

    const res = await getUndated(household, user, {});

    expect(res.status).toBe(200);
    expect(res.body.data.items.map((t: TaskPayload) => t.id)).toEqual([undated]);
    expect(res.body.data.total).toBe(1);
  });

  it('should paginate without gaps or duplicates, newest first', async () => {
    // Newest-first is the order these tasks already had inside the combined
    // list; splitting them out must not reshuffle a bucket users know.
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    const ids: string[] = [];
    for (let i = 0; i < 5; i += 1) ids.push(await seedTask(household, user, `u${i}`, null));

    const seen: string[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < 10; page += 1) {
      const query: Record<string, string> = { limit: '2' };
      if (cursor) query.cursor = cursor;
      const res = await getUndated(household, user, query);
      seen.push(...res.body.data.items.map((t: TaskPayload) => t.id));
      if (!res.body.data.hasMore) break;
      cursor = res.body.data.nextCursor;
    }

    expect(seen).toEqual([...ids].reverse());
  });

  it('should not be affected by a dated task backlog', async () => {
    // The reason this endpoint exists: undated tasks used to ride along with
    // every dated window, so reading them cost more as the dated set grew.
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    for (let i = 0; i < 10; i += 1) await seedTask(household, user, `d${i}`, plusDays(i + 1));
    const undated = await seedTask(household, user, 'unica sin fecha', null);

    const res = await getUndated(household, user, {});

    expect(res.body.data.items.map((t: TaskPayload) => t.id)).toEqual([undated]);
    expect(res.body.data.hasMore).toBe(false);
  });

  it('should refuse a caller who is not a member', async () => {
    const { household } = await createHouseholdWithMember(app);
    const outsider = await createTestUser(app);

    const res = await getUndated(household, outsider, {});
    expect(res.status).toBe(403);
  });
});

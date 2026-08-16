import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { buildTestApp } from './setup';
import {
  TestHousehold,
  authHeader,
  createHouseholdWithMember,
  createTestHousehold,
  createTestUser,
} from './helpers';
import { TaskModel } from '../models/Task';

let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

function daysAgo(days: number): Date {
  return new Date(Date.now() - days * 24 * 60 * 60 * 1000);
}

function statsUrl(household: TestHousehold, period?: string): string {
  const query = period ? `?period=${period}` : '';
  return `/api/households/${household.id}/stats${query}`;
}

/**
 * Insert a task directly via the model so createdAt/completedAt can be
 * backdated — going through the API always stamps "now". Backdating uses the
 * native driver (.collection), not Mongoose's Model.updateOne: the timestamps
 * plugin silently strips createdAt out of a query-based $set (same pattern as
 * pet.test.ts's backdateAdoptionRequest).
 */
async function insertTask(
  household: TestHousehold,
  opts: {
    createdBy: string;
    completedBy?: string;
    status?: 'pending' | 'completed';
    createdDaysAgo?: number;
    completedDaysAgo?: number;
    isDeleted?: boolean;
    title?: string;
  },
): Promise<string> {
  const task = await TaskModel.create({
    householdId: new Types.ObjectId(household.id),
    title: opts.title ?? 'Tarea',
    createdBy: new Types.ObjectId(opts.createdBy),
    status: opts.status ?? 'pending',
    completedBy: opts.completedBy ? new Types.ObjectId(opts.completedBy) : undefined,
    completedAt: opts.status === 'completed' ? new Date() : undefined,
    isDeleted: opts.isDeleted ?? false,
  });

  const setFields: Record<string, Date> = {};
  if (opts.createdDaysAgo !== undefined) {
    setFields.createdAt = daysAgo(opts.createdDaysAgo);
  }
  if (opts.completedDaysAgo !== undefined) {
    setFields.completedAt = daysAgo(opts.completedDaysAgo);
  }
  if (Object.keys(setFields).length > 0) {
    await TaskModel.collection.updateOne({ _id: task._id }, { $set: setFields });
  }
  return task._id.toString();
}

describe('GET /api/households/:householdId/stats (PDR-007)', () => {
  it('should require membership', async () => {
    const admin = await createTestUser(app);
    const outsider = await createTestUser(app);
    const household = await createTestHousehold(app, admin);

    const res = await request(app)
      .get(statsUrl(household))
      .set(authHeader(outsider.accessToken));

    expect(res.status).toBe(403);
  });

  it('should reject an invalid period', async () => {
    const admin = await createTestUser(app);
    const household = await createTestHousehold(app, admin);

    const res = await request(app)
      .get(statsUrl(household, 'lastYear'))
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(400);
  });

  it('should default to last30days and return null topCompleter when nobody completed anything', async () => {
    const { admin, household } = await createHouseholdWithMember(app);
    await insertTask(household, { createdBy: admin.id, status: 'pending' });

    const res = await request(app).get(statsUrl(household)).set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.period).toBe('last30days');
    expect(res.body.data.topCompleter).toBeNull();
    expect(res.body.data.completedTasks).toBe(0);
    expect(res.body.data.completionRate).toBe(0);
  });

  it('should compute totals, completionRate, memberStats and topCompleter for allTime', async () => {
    const { admin, member, household } = await createHouseholdWithMember(app);

    // admin: created 2, completed 1 (own)
    await insertTask(household, { createdBy: admin.id, status: 'pending' });
    await insertTask(household, {
      createdBy: admin.id,
      completedBy: admin.id,
      status: 'completed',
    });
    // member: created 1, completed 2 (one of admin's, one of their own)
    await insertTask(household, {
      createdBy: member.id,
      completedBy: member.id,
      status: 'completed',
    });
    await insertTask(household, {
      createdBy: admin.id,
      completedBy: member.id,
      status: 'completed',
    });

    const res = await request(app)
      .get(statsUrl(household, 'allTime'))
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    const data = res.body.data;
    expect(data.period).toBe('allTime');
    expect(data.totalTasks).toBe(4);
    expect(data.completedTasks).toBe(3);
    expect(data.completionRate).toBeCloseTo(75.0, 1);

    const byId = Object.fromEntries(
      data.memberStats.map((m: { userId: string; created: number; completed: number }) => [
        m.userId,
        m,
      ]),
    );
    expect(byId[admin.id]).toMatchObject({ created: 3, completed: 1, userName: admin.name });
    expect(byId[member.id]).toMatchObject({ created: 1, completed: 2, userName: member.name });
    expect(data.memberStats.every((m: { avatarUrl?: string }) => 'avatarUrl' in m)).toBe(true);

    expect(data.topCompleter).toMatchObject({ userId: member.id, completed: 2 });
  });

  it('should include every current member even with zero activity', async () => {
    const { admin, member, household } = await createHouseholdWithMember(app);

    const res = await request(app)
      .get(statsUrl(household, 'allTime'))
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    const ids = res.body.data.memberStats.map((m: { userId: string }) => m.userId);
    expect(ids).toEqual(expect.arrayContaining([admin.id, member.id]));
    expect(res.body.data.memberStats).toHaveLength(2);
    for (const m of res.body.data.memberStats) {
      expect(m.created).toBe(0);
      expect(m.completed).toBe(0);
    }
  });

  it('should exclude soft-deleted tasks', async () => {
    const { admin, household } = await createHouseholdWithMember(app);
    await insertTask(household, { createdBy: admin.id, status: 'pending' });
    await insertTask(household, {
      createdBy: admin.id,
      completedBy: admin.id,
      status: 'completed',
      isDeleted: true,
    });

    const res = await request(app)
      .get(statsUrl(household, 'allTime'))
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.totalTasks).toBe(1);
    expect(res.body.data.completedTasks).toBe(0);
    expect(res.body.data.topCompleter).toBeNull();
  });

  it('should scope last30days by createdAt for totals and by completedAt for completions', async () => {
    const { admin, household } = await createHouseholdWithMember(app);

    // Created 45 days ago, completed 45 days ago: outside the window on both counts.
    await insertTask(household, {
      createdBy: admin.id,
      completedBy: admin.id,
      status: 'completed',
      createdDaysAgo: 45,
      completedDaysAgo: 45,
    });
    // Created 45 days ago (excluded from totalTasks), but completed 2 days ago
    // (included in completedTasks per the split-window rule).
    await insertTask(household, {
      createdBy: admin.id,
      completedBy: admin.id,
      status: 'completed',
      createdDaysAgo: 45,
      completedDaysAgo: 2,
    });
    // Created and completed recently: counted in both.
    await insertTask(household, {
      createdBy: admin.id,
      completedBy: admin.id,
      status: 'completed',
      createdDaysAgo: 1,
      completedDaysAgo: 1,
    });

    const res = await request(app)
      .get(statsUrl(household, 'last30days'))
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    // totalTasks counts createdAt >= now-30d: only the last task qualifies.
    expect(res.body.data.totalTasks).toBe(1);
    // completedTasks counts completedAt >= now-30d: the last two qualify.
    expect(res.body.data.completedTasks).toBe(2);
    expect(res.body.data.topCompleter).toMatchObject({ userId: admin.id, completed: 2 });
  });
});

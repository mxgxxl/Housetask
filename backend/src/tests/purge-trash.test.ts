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
import { DEFAULT_PURGE_DAYS, purgeDeletedTasks } from '../services/task.service';
import { parseDaysArg } from '../scripts/purge-trash';
import * as socketConfig from '../config/socket';

let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

function daysAgo(days: number): Date {
  return new Date(Date.now() - days * 24 * 60 * 60 * 1000);
}

/**
 * Insert a soft-deleted task directly via the model, bypassing the API —
 * DELETE /tasks/:id always stamps deletedAt with "now", so backdating it (to
 * simulate trash that has aged past the retention window) requires writing
 * the document directly.
 */
async function insertDeletedTask(
  householdId: string,
  userId: string,
  opts: { title?: string; deletedDaysAgo: number },
): Promise<string> {
  const task = await TaskModel.create({
    householdId: new Types.ObjectId(householdId),
    title: opts.title ?? 'Vieja',
    createdBy: new Types.ObjectId(userId),
    isDeleted: true,
    deletedAt: daysAgo(opts.deletedDaysAgo),
  });
  return task._id.toString();
}

describe('purgeDeletedTasks (purge-trash script, TD-048)', () => {
  it('should default DEFAULT_PURGE_DAYS to 30', () => {
    expect(DEFAULT_PURGE_DAYS).toBe(30);
  });

  it('should hard-delete soft-deleted tasks older than the given days, globally', async () => {
    const user = await createTestUser(app);
    const householdA = await createTestHousehold(app, user);
    const householdB = await createTestHousehold(app, user, 'Casa B');

    const oldA = await insertDeletedTask(householdA.id, user.id, { deletedDaysAgo: 45 });
    const recentA = await insertDeletedTask(householdA.id, user.id, { deletedDaysAgo: 5 });
    const oldB = await insertDeletedTask(householdB.id, user.id, { deletedDaysAgo: 60 });

    const deleted = await purgeDeletedTasks(30);

    expect(deleted).toBe(2);
    expect(await TaskModel.findById(oldA)).toBeNull();
    expect(await TaskModel.findById(oldB)).toBeNull();
    expect(await TaskModel.findById(recentA)).not.toBeNull();
  });

  it('should never touch active (non-deleted) tasks', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    const active = await TaskModel.create({
      householdId: new Types.ObjectId(household.id),
      title: 'Activa',
      createdBy: new Types.ObjectId(user.id),
      isDeleted: false,
    });

    const deleted = await purgeDeletedTasks(0);

    expect(deleted).toBe(0);
    expect(await TaskModel.findById(active._id)).not.toBeNull();
  });

  it('should scope to one household when householdId is given', async () => {
    const user = await createTestUser(app);
    const householdA = await createTestHousehold(app, user);
    const householdB = await createTestHousehold(app, user, 'Casa B');
    const oldA = await insertDeletedTask(householdA.id, user.id, { deletedDaysAgo: 45 });
    const oldB = await insertDeletedTask(householdB.id, user.id, { deletedDaysAgo: 45 });

    const deleted = await purgeDeletedTasks(30, householdA.id);

    expect(deleted).toBe(1);
    expect(await TaskModel.findById(oldA)).toBeNull();
    expect(await TaskModel.findById(oldB)).not.toBeNull();
  });

  it('should be idempotent — a second run with nothing left to purge deletes 0', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);
    await insertDeletedTask(household.id, user.id, { deletedDaysAgo: 45 });

    expect(await purgeDeletedTasks(30)).toBe(1);
    expect(await purgeDeletedTasks(30)).toBe(0);
  });

  it('should reject a negative days value', async () => {
    await expect(purgeDeletedTasks(-1)).rejects.toThrow('days must be a non-negative number');
  });
});

describe('parseDaysArg (purge-trash script CLI parsing, TD-048)', () => {
  it('should default to 30 when --days is absent', () => {
    expect(parseDaysArg([])).toBe(30);
  });

  it('should parse a valid --days value', () => {
    expect(parseDaysArg(['--days', '60'])).toBe(60);
  });

  it('should throw for a missing value after --days', () => {
    expect(() => parseDaysArg(['--days'])).toThrow('Invalid --days value');
  });

  it('should throw for a non-integer --days value', () => {
    expect(() => parseDaysArg(['--days', 'abc'])).toThrow('Invalid --days value');
  });

  it('should throw for a negative --days value', () => {
    expect(() => parseDaysArg(['--days', '-1'])).toThrow('Invalid --days value');
  });
});

describe('POST /api/households/:householdId/tasks/purge (TD-048)', () => {
  function purgeUrl(household: TestHousehold): string {
    return `/api/households/${household.id}/tasks/purge`;
  }

  it('should return 401 with no access token', async () => {
    const { household } = await createHouseholdWithMember(app);
    const res = await request(app).post(purgeUrl(household));
    expect(res.status).toBe(401);
  });

  it('should return 403 for a non-member', async () => {
    const { household } = await createHouseholdWithMember(app);
    const outsider = await createTestUser(app);
    const res = await request(app).post(purgeUrl(household)).set(authHeader(outsider.accessToken));
    expect(res.status).toBe(403);
  });

  it('should return 403 for a non-admin member', async () => {
    const { member, household } = await createHouseholdWithMember(app);

    const res = await request(app).post(purgeUrl(household)).set(authHeader(member.accessToken));

    expect(res.status).toBe(403);
    expect(res.body.error).toBe('Only admins can purge the trash');
  });

  it('should let an admin purge tasks older than the default 30 days, keeping newer ones', async () => {
    const { admin, household } = await createHouseholdWithMember(app);
    const old = await insertDeletedTask(household.id, admin.id, { deletedDaysAgo: 45 });
    const recent = await insertDeletedTask(household.id, admin.id, { deletedDaysAgo: 5 });

    const res = await request(app).post(purgeUrl(household)).set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({ deleted: 1 });
    expect(await TaskModel.findById(old)).toBeNull();
    expect(await TaskModel.findById(recent)).not.toBeNull();
  });

  it('should honor a custom ?days= query param', async () => {
    const { admin, household } = await createHouseholdWithMember(app);
    const task10 = await insertDeletedTask(household.id, admin.id, { deletedDaysAgo: 10 });

    const res = await request(app)
      .post(purgeUrl(household))
      .query({ days: '5' })
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({ deleted: 1 });
    expect(await TaskModel.findById(task10)).toBeNull();
  });

  it('should return 400 for a non-numeric days value', async () => {
    const { admin, household } = await createHouseholdWithMember(app);

    const res = await request(app)
      .post(purgeUrl(household))
      .query({ days: 'garbage' })
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(400);
  });

  it('should return 400 for a negative days value', async () => {
    const { admin, household } = await createHouseholdWithMember(app);

    const res = await request(app)
      .post(purgeUrl(household))
      .query({ days: '-1' })
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(400);
  });

  it("should not touch a different household's old trash", async () => {
    const { admin, household } = await createHouseholdWithMember(app);
    const otherUser = await createTestUser(app);
    const otherHousehold = await createTestHousehold(app, otherUser);
    const otherOld = await insertDeletedTask(otherHousehold.id, otherUser.id, {
      deletedDaysAgo: 90,
    });

    const res = await request(app).post(purgeUrl(household)).set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({ deleted: 0 });
    expect(await TaskModel.findById(otherOld)).not.toBeNull();
  });

  it('should emit tasks:purged with the deleted count when something is purged', async () => {
    const { admin, household } = await createHouseholdWithMember(app);
    await insertDeletedTask(household.id, admin.id, { deletedDaysAgo: 45 });
    const emitSpy = jest.spyOn(socketConfig, 'emitToHousehold');

    const res = await request(app).post(purgeUrl(household)).set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    expect(emitSpy).toHaveBeenCalledTimes(1);
    const [householdId, event, payload] = emitSpy.mock.calls[0] as [
      string,
      string,
      Record<string, unknown>,
    ];
    emitSpy.mockRestore();
    expect(householdId).toBe(household.id);
    expect(event).toBe('tasks:purged');
    expect(payload).toEqual({ householdId: household.id, deleted: 1 });
  });

  it('should not emit tasks:purged when nothing was purged', async () => {
    const { admin, household } = await createHouseholdWithMember(app);
    const emitSpy = jest.spyOn(socketConfig, 'emitToHousehold');

    const res = await request(app).post(purgeUrl(household)).set(authHeader(admin.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data).toEqual({ deleted: 0 });
    expect(emitSpy).not.toHaveBeenCalled();
    emitSpy.mockRestore();
  });
});

import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { HouseholdMemberModel } from '../models/HouseholdMember';
import * as sentry from '../utils/sentry';
import { buildTestApp } from './setup';
import { authHeader, createTestHousehold, createTestUser, joinTestHousehold } from './helpers';

/**
 * Phase 2 of TD-001: `requireMembership` reads the new collection alongside
 * the embedded array and reports when they disagree, without letting the
 * comparison affect the answer.
 *
 * These tests are the contract the go/no-go for the cutover rests on. The
 * agreed criterion is a number — zero divergences under real traffic — so what
 * matters is that a divergence is actually reported (not swallowed) and that
 * agreement is silent (or the signal drowns in its own noise).
 */
let app: Server;
let warn: jest.SpyInstance;

beforeAll(async () => {
  app = await buildTestApp();
});

beforeEach(() => {
  warn = jest.spyOn(sentry, 'captureSecurityWarning').mockImplementation(() => {});
});

afterEach(() => {
  warn.mockRestore();
});

const divergences = () =>
  warn.mock.calls.filter(([message]) => String(message).includes('TD-001 dual-read divergence'));

describe('TD-001 dual read', () => {
  it('should report nothing when both sides agree', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);

    const res = await request(app)
      .get(`/api/households/${household.id}`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(divergences()).toHaveLength(0);
  });

  it('should report when the caller is missing from the collection', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);

    // Simulate the hole the verification exists to find: the dual write
    // failed to mirror this membership.
    await HouseholdMemberModel.deleteMany({ householdId: new Types.ObjectId(household.id) });

    const res = await request(app)
      .get(`/api/households/${household.id}`)
      .set(authHeader(user.accessToken));

    // The answer is unchanged: the embedded array is still the authority.
    expect(res.status).toBe(200);
    expect(divergences()).toHaveLength(1);
    expect(divergences()[0][0]).toContain('caller missing from collection');
  });

  it('should report when the roles disagree', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);

    await HouseholdMemberModel.updateOne(
      { householdId: new Types.ObjectId(household.id), userId: new Types.ObjectId(user.id) },
      { $set: { role: 'member' } },
    );

    const res = await request(app)
      .get(`/api/households/${household.id}`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(divergences()[0][0]).toContain('role embedded=admin collection=member');
  });

  it('should report when the member sets differ', async () => {
    const admin = await createTestUser(app);
    const household = await createTestHousehold(app, admin);
    const other = await createTestUser(app);
    await joinTestHousehold(app, other, household.inviteCode);

    // A row the embedded array does not know about.
    await HouseholdMemberModel.create({
      householdId: new Types.ObjectId(household.id),
      userId: new Types.ObjectId(),
    });

    await request(app)
      .get(`/api/households/${household.id}`)
      .set(authHeader(admin.accessToken));

    expect(divergences()[0][0]).toContain('member set');
  });

  it('should tag the report so the count can be read off one Sentry search',
    async () => {
      // The cutover criterion is "zero divergences"; that number has to be
      // readable without triaging individual issues.
      const user = await createTestUser(app);
      const household = await createTestHousehold(app, user);
      await HouseholdMemberModel.deleteMany({ householdId: new Types.ObjectId(household.id) });

      await request(app)
        .get(`/api/households/${household.id}`)
        .set(authHeader(user.accessToken));

      expect(divergences()[0][1]).toMatchObject({
        category: 'td001_dual_read',
        householdId: household.id,
        userId: user.id,
      });
    });

  it('should still answer normally when the verification itself fails',
    async () => {
      // A broken verification is a lost sample, not a broken request.
      const user = await createTestUser(app);
      const household = await createTestHousehold(app, user);
      const find = jest
        .spyOn(HouseholdMemberModel, 'find')
        .mockImplementation(() => {
          throw new Error('collection unavailable');
        });

      const res = await request(app)
        .get(`/api/households/${household.id}`)
        .set(authHeader(user.accessToken));

      expect(res.status).toBe(200);
      find.mockRestore();
    });
});

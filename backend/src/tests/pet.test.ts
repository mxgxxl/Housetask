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
} from './helpers';
import { PetModel } from '../models/Pet';
import { computeDecay } from '../services/economy.service';
import { HUNGER_DECAY_PER_HOUR, MOOD_DECAY_PER_HOUR } from '../config/economy';

let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

async function setupHousehold(): Promise<{ user: TestUser; household: TestHousehold }> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  return { user, household };
}

// No adoption endpoint exists yet this round (PDR-001 A1 ships the model +
// economy engine, not the consensus adoption flow) — tests create the Pet
// document directly, the same way tests/*.test.ts create RefreshToken rows
// directly where no endpoint produces them.
async function adoptPetDirectly(
  household: TestHousehold,
  user: TestUser,
  overrides: Partial<{ hunger: number; mood: number; lastFedAt: Date; lastPlayedAt: Date }> = {},
): Promise<void> {
  await PetModel.create({
    householdId: new Types.ObjectId(household.id),
    species: 'cat',
    name: 'Michi',
    adoptedBy: new Types.ObjectId(user.id),
    ...overrides,
  });
}

describe('economy.service.computeDecay', () => {
  it('should not decay a freshly-adopted pet', () => {
    const now = new Date('2026-08-14T12:00:00.000Z');
    const pet = {
      hunger: 80,
      mood: 80,
      adoptedAt: now,
      lastFedAt: undefined,
      lastPlayedAt: undefined,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any;

    const result = computeDecay(pet, now);

    expect(result.hunger).toBe(80);
    expect(result.mood).toBe(80);
  });

  it('should decay hunger and mood linearly with elapsed hours since last fed/played', () => {
    const lastFedAt = new Date('2026-08-14T00:00:00.000Z');
    const lastPlayedAt = new Date('2026-08-14T00:00:00.000Z');
    const now = new Date('2026-08-14T05:00:00.000Z'); // 5 hours later
    const pet = {
      hunger: 80,
      mood: 80,
      adoptedAt: lastFedAt,
      lastFedAt,
      lastPlayedAt,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any;

    const result = computeDecay(pet, now);

    expect(result.hunger).toBe(80 - 5 * HUNGER_DECAY_PER_HOUR);
    expect(result.mood).toBe(80 - 5 * MOOD_DECAY_PER_HOUR);
  });

  it('should clamp decay at 0, never going negative', () => {
    const lastFedAt = new Date('2026-08-01T00:00:00.000Z');
    const now = new Date('2026-08-14T00:00:00.000Z'); // 312 hours later
    const pet = {
      hunger: 80,
      mood: 80,
      adoptedAt: lastFedAt,
      lastFedAt,
      lastPlayedAt: lastFedAt,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any;

    const result = computeDecay(pet, now);

    expect(result.hunger).toBe(0);
    expect(result.mood).toBe(0);
  });

  it('should fall back to adoptedAt when the pet has never been fed or played with', () => {
    const adoptedAt = new Date('2026-08-14T00:00:00.000Z');
    const now = new Date('2026-08-14T03:00:00.000Z'); // 3 hours later
    const pet = {
      hunger: 80,
      mood: 80,
      adoptedAt,
      lastFedAt: undefined,
      lastPlayedAt: undefined,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any;

    const result = computeDecay(pet, now);

    expect(result.hunger).toBe(80 - 3 * HUNGER_DECAY_PER_HOUR);
    expect(result.mood).toBe(80 - 3 * MOOD_DECAY_PER_HOUR);
  });
});

describe('GET /api/households/:householdId/pet', () => {
  it('should return 404 when the household has not adopted a pet yet', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .get(`/api/households/${household.id}/pet`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(404);
  });

  it('should return the pet with hunger/mood decayed to the current time', async () => {
    const { user, household } = await setupHousehold();
    const threeHoursAgo = new Date(Date.now() - 3 * 60 * 60 * 1000);
    await adoptPetDirectly(household, user, {
      hunger: 80,
      mood: 80,
      lastFedAt: threeHoursAgo,
      lastPlayedAt: threeHoursAgo,
    });

    const res = await request(app)
      .get(`/api/households/${household.id}/pet`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.name).toBe('Michi');
    expect(res.body.data.species).toBe('cat');
    expect(res.body.data.hunger).toBeLessThanOrEqual(80 - 3 * HUNGER_DECAY_PER_HOUR + 1);
    expect(res.body.data.hunger).toBeGreaterThanOrEqual(80 - 3 * HUNGER_DECAY_PER_HOUR - 1);
    expect(res.body.data.mood).toBeLessThanOrEqual(80 - 3 * MOOD_DECAY_PER_HOUR + 1);
  });

  it('should not persist the decayed value back to the database', async () => {
    const { user, household } = await setupHousehold();
    const threeHoursAgo = new Date(Date.now() - 3 * 60 * 60 * 1000);
    await adoptPetDirectly(household, user, {
      hunger: 80,
      mood: 80,
      lastFedAt: threeHoursAgo,
      lastPlayedAt: threeHoursAgo,
    });

    await request(app)
      .get(`/api/households/${household.id}/pet`)
      .set(authHeader(user.accessToken));

    const stored = await PetModel.findOne({ householdId: household.id }).lean();
    expect(stored?.hunger).toBe(80);
    expect(stored?.mood).toBe(80);
  });

  it('should return 403 when the caller is not a member of the household', async () => {
    const { user, household } = await setupHousehold();
    await adoptPetDirectly(household, user);
    const outsider = await createTestUser(app);

    const res = await request(app)
      .get(`/api/households/${household.id}/pet`)
      .set(authHeader(outsider.accessToken));

    expect(res.status).toBe(403);
  });

  it('should return 401 without a token', async () => {
    const { household } = await setupHousehold();

    const res = await request(app).get(`/api/households/${household.id}/pet`);

    expect(res.status).toBe(401);
  });
});

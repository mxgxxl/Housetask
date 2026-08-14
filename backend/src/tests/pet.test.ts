import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { buildTestApp } from './setup';
import {
  TestHousehold,
  TestUser,
  authHeader,
  createHouseholdWithMember,
  createTestHousehold,
  createTestUser,
} from './helpers';
import { PetModel } from '../models/Pet';
import { AdoptionRequestModel } from '../models/AdoptionRequest';
import { computeDecay, getBalance, grantCoins } from '../services/economy.service';
import {
  ADOPTION_BONUS_COINS,
  COSMETICS,
  FEED_AMOUNT,
  HUNGER_DECAY_PER_HOUR,
  MOOD_DECAY_PER_HOUR,
  PLAY_AMOUNT,
} from '../config/economy';

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

function petUrl(household: TestHousehold): string {
  return `/api/households/${household.id}/pet`;
}

describe('POST /api/households/:householdId/pet/adopt', () => {
  it('should create a pending adoption request', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .post(`${petUrl(household)}/adopt`)
      .set(authHeader(user.accessToken))
      .send({ species: 'dog', name: 'Firulais' });

    expect(res.status).toBe(201);
    expect(res.body.data.species).toBe('dog');
    expect(res.body.data.name).toBe('Firulais');
    expect(res.body.data.requestedBy).toBe(user.id);
    expect(res.body.data.status).toBe('pending');
  });

  it('should reject when the household already has a pet', async () => {
    const { user, household } = await setupHousehold();
    await adoptPetDirectly(household, user);

    const res = await request(app)
      .post(`${petUrl(household)}/adopt`)
      .set(authHeader(user.accessToken))
      .send({ species: 'cat', name: 'Otro' });

    expect(res.status).toBe(400);
  });

  it('should reject when a request is already pending', async () => {
    const { user, household } = await setupHousehold();
    await request(app)
      .post(`${petUrl(household)}/adopt`)
      .set(authHeader(user.accessToken))
      .send({ species: 'dog', name: 'Firulais' });

    const res = await request(app)
      .post(`${petUrl(household)}/adopt`)
      .set(authHeader(user.accessToken))
      .send({ species: 'cat', name: 'Otro' });

    expect(res.status).toBe(400);
    const count = await AdoptionRequestModel.countDocuments({ householdId: household.id });
    expect(count).toBe(1);
  });
});

describe('POST /api/households/:householdId/pet/adopt/confirm', () => {
  it('should reject when the requester tries to confirm their own request', async () => {
    const { admin, household } = await createHouseholdWithMember(app);
    await request(app)
      .post(`${petUrl(household)}/adopt`)
      .set(authHeader(admin.accessToken))
      .send({ species: 'dog', name: 'Firulais' });

    const res = await request(app)
      .post(`${petUrl(household)}/adopt/confirm`)
      .set(authHeader(admin.accessToken));

    expect(res.status).toBe(403);
    expect(await PetModel.exists({ householdId: household.id })).toBeNull();
  });

  it('should reject when there is no pending request', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .post(`${petUrl(household)}/adopt/confirm`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(404);
  });

  it('should create the pet and grant the adoption bonus when a DIFFERENT member confirms', async () => {
    const { admin, member, household } = await createHouseholdWithMember(app);
    await request(app)
      .post(`${petUrl(household)}/adopt`)
      .set(authHeader(admin.accessToken))
      .send({ species: 'dog', name: 'Firulais' });

    const res = await request(app)
      .post(`${petUrl(household)}/adopt/confirm`)
      .set(authHeader(member.accessToken));

    expect(res.status).toBe(201);
    expect(res.body.data.species).toBe('dog');
    expect(res.body.data.name).toBe('Firulais');
    expect(res.body.data.hunger).toBe(80);
    expect(res.body.data.mood).toBe(80);

    const pet = await PetModel.findOne({ householdId: household.id }).lean();
    expect(pet).not.toBeNull();
    expect(pet?.adoptedBy.toString()).toBe(member.id);

    expect(await AdoptionRequestModel.countDocuments({ householdId: household.id })).toBe(0);
    expect(await getBalance(household.id)).toBe(ADOPTION_BONUS_COINS);
  });
});

describe('POST /api/households/:householdId/pet/feed', () => {
  it('should increase hunger and set lastFedAt', async () => {
    const { user, household } = await setupHousehold();
    const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000);
    await adoptPetDirectly(household, user, { hunger: 50, mood: 50, lastFedAt: twoHoursAgo });

    const res = await request(app)
      .post(`${petUrl(household)}/feed`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    // decayed hunger before feeding (~50 - 2*HUNGER_DECAY_PER_HOUR) + FEED_AMOUNT
    const expected = 50 - 2 * HUNGER_DECAY_PER_HOUR + FEED_AMOUNT;
    expect(res.body.data.hunger).toBeGreaterThanOrEqual(expected - 1);
    expect(res.body.data.hunger).toBeLessThanOrEqual(expected + 1);

    const stored = await PetModel.findOne({ householdId: household.id }).lean();
    expect(stored?.lastFedAt).toBeDefined();
  });

  it('should clamp hunger at 100', async () => {
    const { user, household } = await setupHousehold();
    const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000);
    await adoptPetDirectly(household, user, { hunger: 90, mood: 50, lastFedAt: twoHoursAgo });

    const res = await request(app)
      .post(`${petUrl(household)}/feed`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.hunger).toBe(100);
  });

  it('should return 409 when fed again before the cooldown elapses', async () => {
    const { user, household } = await setupHousehold();
    await adoptPetDirectly(household, user, { hunger: 50, mood: 50 });

    await request(app).post(`${petUrl(household)}/feed`).set(authHeader(user.accessToken));
    const res = await request(app)
      .post(`${petUrl(household)}/feed`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(409);
  });

  it('should return 404 when the household has no pet', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .post(`${petUrl(household)}/feed`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(404);
  });
});

describe('POST /api/households/:householdId/pet/play', () => {
  it('should increase mood and set lastPlayedAt', async () => {
    const { user, household } = await setupHousehold();
    const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000);
    await adoptPetDirectly(household, user, { hunger: 50, mood: 50, lastPlayedAt: twoHoursAgo });

    const res = await request(app)
      .post(`${petUrl(household)}/play`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    const expected = 50 - 2 * MOOD_DECAY_PER_HOUR + PLAY_AMOUNT;
    expect(res.body.data.mood).toBeGreaterThanOrEqual(expected - 1);
    expect(res.body.data.mood).toBeLessThanOrEqual(expected + 1);

    const stored = await PetModel.findOne({ householdId: household.id }).lean();
    expect(stored?.lastPlayedAt).toBeDefined();
  });

  it('should return 409 when played with again before the cooldown elapses', async () => {
    const { user, household } = await setupHousehold();
    await adoptPetDirectly(household, user, { hunger: 50, mood: 50 });

    await request(app).post(`${petUrl(household)}/play`).set(authHeader(user.accessToken));
    const res = await request(app)
      .post(`${petUrl(household)}/play`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(409);
  });
});

describe('POST /api/households/:householdId/pet/cosmetics/buy', () => {
  const [cheapest] = COSMETICS;

  it('should deduct the balance and add the cosmetic to the pet', async () => {
    const { user, household } = await setupHousehold();
    await adoptPetDirectly(household, user);
    await grantCoins(household.id, cheapest.price, 'adoption_bonus', `adoption-${household.id}`);

    const res = await request(app)
      .post(`${petUrl(household)}/cosmetics/buy`)
      .set(authHeader(user.accessToken))
      .send({ cosmeticId: cheapest.id });

    expect(res.status).toBe(200);
    expect(res.body.data.cosmetics).toContain(cheapest.id);
    expect(await getBalance(household.id)).toBe(0);
  });

  it('should reject buying the same cosmetic twice', async () => {
    const { user, household } = await setupHousehold();
    await adoptPetDirectly(household, user);
    await grantCoins(household.id, cheapest.price * 2, 'adoption_bonus', `adoption-${household.id}`);

    const first = await request(app)
      .post(`${petUrl(household)}/cosmetics/buy`)
      .set(authHeader(user.accessToken))
      .send({ cosmeticId: cheapest.id });
    expect(first.status).toBe(200);

    const second = await request(app)
      .post(`${petUrl(household)}/cosmetics/buy`)
      .set(authHeader(user.accessToken))
      .send({ cosmeticId: cheapest.id });

    expect(second.status).toBe(400);
    expect(await getBalance(household.id)).toBe(cheapest.price);
  });

  it('should reject when the balance is insufficient', async () => {
    const { user, household } = await setupHousehold();
    await adoptPetDirectly(household, user);

    const res = await request(app)
      .post(`${petUrl(household)}/cosmetics/buy`)
      .set(authHeader(user.accessToken))
      .send({ cosmeticId: cheapest.id });

    expect(res.status).toBe(400);
  });

  it('should reject an unknown cosmeticId', async () => {
    const { user, household } = await setupHousehold();
    await adoptPetDirectly(household, user);

    const res = await request(app)
      .post(`${petUrl(household)}/cosmetics/buy`)
      .set(authHeader(user.accessToken))
      .send({ cosmeticId: 'not-a-real-cosmetic' });

    expect(res.status).toBe(400);
  });
});

describe('POST /api/households/:householdId/pet/cosmetics/active', () => {
  const [cheapest] = COSMETICS;

  it('should reject setting a cosmetic the household does not own', async () => {
    const { user, household } = await setupHousehold();
    await adoptPetDirectly(household, user);

    const res = await request(app)
      .post(`${petUrl(household)}/cosmetics/active`)
      .set(authHeader(user.accessToken))
      .send({ cosmeticId: cheapest.id });

    expect(res.status).toBe(400);
  });

  it('should set the active cosmetic once owned', async () => {
    const { user, household } = await setupHousehold();
    await adoptPetDirectly(household, user);
    await grantCoins(household.id, cheapest.price, 'adoption_bonus', `adoption-${household.id}`);
    await request(app)
      .post(`${petUrl(household)}/cosmetics/buy`)
      .set(authHeader(user.accessToken))
      .send({ cosmeticId: cheapest.id });

    const res = await request(app)
      .post(`${petUrl(household)}/cosmetics/active`)
      .set(authHeader(user.accessToken))
      .send({ cosmeticId: cheapest.id });

    expect(res.status).toBe(200);
    expect(res.body.data.activeCosmetic).toBe(cheapest.id);
  });
});

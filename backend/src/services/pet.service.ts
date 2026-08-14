import { Types } from 'mongoose';
import { PetModel, IPet, PetSpecies } from '../models/Pet';
import { AdoptionRequestModel, IAdoptionRequest } from '../models/AdoptionRequest';
import { AppError } from '../middleware/error.middleware';
import { emitToHousehold } from '../config/socket';
import { logger } from '../utils/logger';
import { sanitizeString } from '../utils/sanitize';
import { grantCoins, getBalance, computeDecay } from './economy.service';
import { Role } from '../types';
import {
  ADOPTION_BONUS_COINS,
  ADOPTION_REQUEST_TTL_DAYS,
  COSMETICS,
  FEED_AMOUNT,
  FEED_COOLDOWN_HOURS,
  PLAY_AMOUNT,
  PLAY_COOLDOWN_HOURS,
} from '../config/economy';

const ADOPTION_REQUEST_TTL_MS = ADOPTION_REQUEST_TTL_DAYS * 24 * 60 * 60 * 1000;

/**
 * The household's pending adoption request, or null if there is none — OR
 * if there was one but it is older than ADOPTION_REQUEST_TTL_DAYS (PDR-001
 * A3), in which case it is deleted here and treated as if it never
 * existed. Centralizing the TTL check here means request/confirm/cancel
 * all agree on what "pending" means without duplicating the expiry math.
 */
async function getLiveAdoptionRequest(householdId: string): Promise<IAdoptionRequest | null> {
  const request = await AdoptionRequestModel.findOne({ householdId });
  if (!request) {
    return null;
  }
  if (Date.now() - request.createdAt.getTime() > ADOPTION_REQUEST_TTL_MS) {
    await request.deleteOne();
    return null;
  }
  return request;
}

const MAX_PET_NAME_LENGTH = 50;

/** Serialize a pet with hunger/mood decayed to "now" — never persisted. */
function serializePet(pet: IPet): Record<string, unknown> {
  return { ...pet.toJSON(), ...computeDecay(pet) };
}

/**
 * The household's pet, with hunger/mood decayed to the current time
 * (economy.service.ts's computeDecay — lazy, nothing is written back).
 * 404 until the household has adopted one.
 */
export async function getPet(householdId: string): Promise<Record<string, unknown>> {
  const pet = await PetModel.findOne({ householdId });
  if (!pet) {
    throw new AppError('This household has not adopted a pet yet', 404);
  }
  return serializePet(pet);
}

/**
 * The household's pending adoption request (PDR-001 A3). Without this,
 * nothing lets the OTHER member discover that a proposal exists at all —
 * confirm/adopt would have to be attempted blind. 404 when there is none
 * (or it expired), same convention as getPet.
 */
export async function getAdoptionRequest(householdId: string): Promise<IAdoptionRequest> {
  const request = await getLiveAdoptionRequest(householdId);
  if (!request) {
    throw new AppError('No pending adoption request for this household', 404);
  }
  return request;
}

export interface RequestAdoptionInput {
  species: PetSpecies;
  name: string;
}

/**
 * Start a household's adoption (PDR-001 A2, step 1 of 2): records a
 * proposal, does not create the Pet. Rejects if the household already has
 * a pet or already has a LIVE pending request (getLiveAdoptionRequest —
 * PDR-001 A3 — silently clears an expired one first, freeing the slot).
 * Both are unique-per-household by construction (Pet.householdId and
 * AdoptionRequest.householdId are each unique indexes), but checked here
 * first for a clean 400 instead of a raw duplicate-key 409.
 */
export async function requestAdoption(
  householdId: string,
  userId: string,
  input: RequestAdoptionInput,
): Promise<IAdoptionRequest> {
  const existingPet = await PetModel.exists({ householdId });
  if (existingPet) {
    throw new AppError('This household already has a pet', 400);
  }

  const existingRequest = await getLiveAdoptionRequest(householdId);
  if (existingRequest) {
    throw new AppError('An adoption request is already pending for this household', 400);
  }

  const request = await AdoptionRequestModel.create({
    householdId: new Types.ObjectId(householdId),
    species: input.species,
    name: sanitizeString(input.name, MAX_PET_NAME_LENGTH, 'Pet name'),
    requestedBy: new Types.ObjectId(userId),
  });

  emitToHousehold(householdId, 'pet:adopt_requested', request.toJSON());
  return request;
}

/**
 * Confirm a household's pending adoption (PDR-001 A2, step 2 of 2): must be
 * a DIFFERENT member than the one who requested it — this is the whole
 * point of "consenso del hogar" (docs/PRODUCT_DECISIONS.md PDR-001).
 * Creates the Pet, deletes the request, and grants a one-time adoption
 * bonus (best-effort — the bonus is a nice-to-have, never a dependency of
 * the adoption itself succeeding). A request older than
 * ADOPTION_REQUEST_TTL_DAYS (PDR-001 A3) is treated as if it never existed
 * — same 404 as no request at all.
 */
export async function confirmAdoption(
  householdId: string,
  userId: string,
): Promise<Record<string, unknown>> {
  const request = await getLiveAdoptionRequest(householdId);
  if (!request) {
    throw new AppError('No pending adoption request for this household', 404);
  }

  if (request.requestedBy.toString() === userId) {
    throw new AppError('A different household member must confirm the adoption', 403);
  }

  // Defensive: Pet.householdId is unique too, so this can only fire if a
  // pet was created through some path other than this function.
  const existingPet = await PetModel.exists({ householdId });
  if (existingPet) {
    throw new AppError('This household already has a pet', 400);
  }

  const pet = await PetModel.create({
    householdId: new Types.ObjectId(householdId),
    species: request.species,
    name: request.name,
    adoptedBy: new Types.ObjectId(userId),
  });

  await request.deleteOne();

  try {
    await grantCoins(
      householdId,
      ADOPTION_BONUS_COINS,
      'adoption_bonus',
      `adoption-${householdId}`,
    );
  } catch (err) {
    logger.error('Error granting adoption bonus', (err as Error).message);
  }

  const result = serializePet(pet);
  emitToHousehold(householdId, 'pet:adopted', result);
  return result;
}

/**
 * Cancel a household's pending adoption (PDR-001 A3): only the member who
 * requested it, or a household admin, may cancel — anyone else has no say
 * over a proposal they didn't make and isn't running the household. A
 * request older than ADOPTION_REQUEST_TTL_DAYS is treated as if it never
 * existed — same 404 as no request at all.
 */
export async function cancelAdoption(
  householdId: string,
  userId: string,
  memberRole: Role,
): Promise<void> {
  const request = await getLiveAdoptionRequest(householdId);
  if (!request) {
    throw new AppError('No pending adoption request for this household', 404);
  }

  if (request.requestedBy.toString() !== userId && memberRole !== 'admin') {
    throw new AppError('Only the requester or a household admin can cancel this adoption', 403);
  }

  await request.deleteOne();
  emitToHousehold(householdId, 'pet:adopt_cancelled', { householdId });
}

/**
 * Feed the household's pet: restores FEED_AMOUNT hunger (clamped to
 * [0, 100]), gated by FEED_COOLDOWN_HOURS since the last feed (anti-farm —
 * this action grants no coins, so the cooldown is the only thing standing
 * between a bored user and an infinite hunger bar). The restore is applied
 * on top of the CURRENT decayed hunger, not the stale stored value —
 * otherwise a household that waited longer between feeds would gain more
 * from the same action, rewarding neglect.
 */
export async function feedPet(householdId: string): Promise<Record<string, unknown>> {
  const pet = await PetModel.findOne({ householdId });
  if (!pet) {
    throw new AppError('This household has not adopted a pet yet', 404);
  }

  const now = new Date();
  if (pet.lastFedAt && now.getTime() - pet.lastFedAt.getTime() < FEED_COOLDOWN_HOURS * 3_600_000) {
    throw new AppError('The pet was already fed recently — try again later', 409);
  }

  const currentHunger = computeDecay(pet, now).hunger;
  pet.hunger = Math.max(0, Math.min(100, currentHunger + FEED_AMOUNT));
  pet.lastFedAt = now;
  await pet.save();

  const result = serializePet(pet);
  emitToHousehold(householdId, 'pet:updated', result);
  return result;
}

/** Play with the household's pet — mood's counterpart to feedPet. */
export async function playWithPet(householdId: string): Promise<Record<string, unknown>> {
  const pet = await PetModel.findOne({ householdId });
  if (!pet) {
    throw new AppError('This household has not adopted a pet yet', 404);
  }

  const now = new Date();
  if (
    pet.lastPlayedAt &&
    now.getTime() - pet.lastPlayedAt.getTime() < PLAY_COOLDOWN_HOURS * 3_600_000
  ) {
    throw new AppError('The pet already played recently — try again later', 409);
  }

  const currentMood = computeDecay(pet, now).mood;
  pet.mood = Math.max(0, Math.min(100, currentMood + PLAY_AMOUNT));
  pet.lastPlayedAt = now;
  await pet.save();

  const result = serializePet(pet);
  emitToHousehold(householdId, 'pet:updated', result);
  return result;
}

/**
 * Buy a cosmetic for the household's pet: spends coins (a negative ledger
 * entry, reason `cosmetic_buy`) and adds it to the pet's cosmetics.
 * Idempotent the same way earning is: the ledger's unique
 * (householdId, refId, reason) index means this exact cosmetic can only
 * ever be bought once for this household, however many times the request
 * races or retries.
 */
export async function buyCosmetic(
  householdId: string,
  cosmeticId: string,
): Promise<Record<string, unknown>> {
  const cosmetic = COSMETICS.find((c) => c.id === cosmeticId);
  if (!cosmetic) {
    throw new AppError('Unknown cosmetic', 400);
  }

  const pet = await PetModel.findOne({ householdId });
  if (!pet) {
    throw new AppError('This household has not adopted a pet yet', 404);
  }

  if (pet.cosmetics.includes(cosmeticId)) {
    throw new AppError('This household already owns this cosmetic', 400);
  }

  const balance = await getBalance(householdId);
  if (balance < cosmetic.price) {
    throw new AppError('Insufficient balance', 400);
  }

  const spent = await grantCoins(householdId, -cosmetic.price, 'cosmetic_buy', cosmeticId);
  if (spent === 0) {
    // Only reachable via a genuine race: two concurrent buys for the same
    // cosmetic both passed the ownership check above before either saved.
    // The ledger's unique index is the real guard; the check above is just
    // the common-case fast path with a clearer message.
    throw new AppError('This household already owns this cosmetic', 409);
  }

  pet.cosmetics.push(cosmeticId);
  await pet.save();

  const result = serializePet(pet);
  emitToHousehold(householdId, 'pet:updated', result);
  return result;
}

/** Set the pet's active cosmetic — must already be owned. */
export async function setActiveCosmetic(
  householdId: string,
  cosmeticId: string,
): Promise<Record<string, unknown>> {
  const pet = await PetModel.findOne({ householdId });
  if (!pet) {
    throw new AppError('This household has not adopted a pet yet', 404);
  }

  if (!pet.cosmetics.includes(cosmeticId)) {
    throw new AppError('This household does not own this cosmetic', 400);
  }

  pet.activeCosmetic = cosmeticId;
  await pet.save();

  const result = serializePet(pet);
  emitToHousehold(householdId, 'pet:updated', result);
  return result;
}

import { Response } from 'express';
import * as petService from '../services/pet.service';
import { sendSuccess } from '../utils/response';
import { AuthenticatedRequest } from '../types';

/**
 * GET /api/households/:householdId/pet
 * Returns the household's pet with hunger/mood decayed to the current time.
 * 404 until the household has adopted one.
 */
export async function get(req: AuthenticatedRequest, res: Response): Promise<void> {
  const pet = await petService.getPet(req.params.householdId);
  sendSuccess(res, pet);
}

/**
 * GET /api/households/:householdId/pet/adopt
 * Returns the pending adoption request, if any. 404 when there is none.
 */
export async function getAdoptionRequest(req: AuthenticatedRequest, res: Response): Promise<void> {
  const request = await petService.getAdoptionRequest(req.params.householdId);
  sendSuccess(res, request);
}

/**
 * POST /api/households/:householdId/pet/adopt
 * Starts a household adoption; broadcasts pet:adopt_requested. For a
 * single-member household this adopts instantly instead (no other member
 * exists to confirm) and broadcasts pet:adopted.
 */
export async function requestAdopt(req: AuthenticatedRequest, res: Response): Promise<void> {
  const request = await petService.requestAdoption(
    req.params.householdId,
    req.user!.userId,
    req.body ?? {},
    req.member!.memberIds,
  );
  sendSuccess(res, request, 201);
}

/**
 * POST /api/households/:householdId/pet/adopt/confirm
 * Confirms a pending adoption (by a different member than the requester),
 * creating the Pet; broadcasts pet:adopted.
 */
export async function confirmAdopt(req: AuthenticatedRequest, res: Response): Promise<void> {
  const pet = await petService.confirmAdoption(req.params.householdId, req.user!.userId);
  sendSuccess(res, pet, 201);
}

/**
 * DELETE /api/households/:householdId/pet/adopt
 * Cancels the pending adoption request (requester or admin only);
 * broadcasts pet:adopt_cancelled.
 */
export async function cancelAdopt(req: AuthenticatedRequest, res: Response): Promise<void> {
  await petService.cancelAdoption(req.params.householdId, req.user!.userId, req.member!.role);
  sendSuccess(res, { message: 'Adoption request cancelled' });
}

/**
 * POST /api/households/:householdId/pet/feed
 * Feeds the pet (cooldown-gated); broadcasts pet:updated.
 */
export async function feed(req: AuthenticatedRequest, res: Response): Promise<void> {
  const pet = await petService.feedPet(req.params.householdId);
  sendSuccess(res, pet);
}

/**
 * POST /api/households/:householdId/pet/play
 * Plays with the pet (cooldown-gated); broadcasts pet:updated.
 */
export async function play(req: AuthenticatedRequest, res: Response): Promise<void> {
  const pet = await petService.playWithPet(req.params.householdId);
  sendSuccess(res, pet);
}

/**
 * POST /api/households/:householdId/pet/cosmetics/buy
 * Spends coins on a cosmetic; broadcasts pet:updated.
 */
export async function buyCosmetic(req: AuthenticatedRequest, res: Response): Promise<void> {
  const pet = await petService.buyCosmetic(req.params.householdId, req.body.cosmeticId as string);
  sendSuccess(res, pet);
}

/**
 * POST /api/households/:householdId/pet/cosmetics/active
 * Sets the pet's active cosmetic (must already be owned); broadcasts pet:updated.
 */
export async function setActiveCosmetic(req: AuthenticatedRequest, res: Response): Promise<void> {
  const pet = await petService.setActiveCosmetic(
    req.params.householdId,
    req.body.cosmeticId as string,
  );
  sendSuccess(res, pet);
}

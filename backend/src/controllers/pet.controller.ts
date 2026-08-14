import { Response } from 'express';
import { PetModel } from '../models/Pet';
import { computeDecay } from '../services/economy.service';
import { AppError } from '../middleware/error.middleware';
import { sendSuccess } from '../utils/response';
import { AuthenticatedRequest } from '../types';

/**
 * GET /api/households/:householdId/pet
 * Returns the household's pet with hunger/mood decayed to the current time
 * (economy.service.ts's computeDecay — lazy, nothing is written back).
 * 404 until the household has adopted one: this round (PDR-001 A1) ships
 * the model and economy engine, not the adoption flow itself.
 */
export async function get(req: AuthenticatedRequest, res: Response): Promise<void> {
  const pet = await PetModel.findOne({ householdId: req.params.householdId });
  if (!pet) {
    throw new AppError('This household has not adopted a pet yet', 404);
  }

  const { hunger, mood } = computeDecay(pet);
  sendSuccess(res, { ...pet.toJSON(), hunger, mood });
}

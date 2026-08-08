import { Response } from 'express';
import * as householdService from '../services/household.service';
import { AppError } from '../middleware/error.middleware';
import { sendSuccess } from '../utils/response';
import { AuthenticatedRequest } from '../types';

/**
 * POST /api/households
 * Body: { name }
 * Creates a household with the caller as its first admin.
 */
export async function create(req: AuthenticatedRequest, res: Response): Promise<void> {
  const { name } = req.body ?? {};
  if (typeof name !== 'string' || name.trim().length === 0) {
    throw new AppError('Household name is required', 400);
  }

  const household = await householdService.createHousehold(req.user!.userId, name);
  sendSuccess(res, householdService.serializeHousehold(household), 201);
}

/**
 * GET /api/households/:id
 * Returns the household with members populated (members only).
 */
export async function getById(req: AuthenticatedRequest, res: Response): Promise<void> {
  const household = await householdService.getHousehold(req.params.id, req.user!.userId);
  sendSuccess(res, householdService.serializeHousehold(household));
}

/**
 * POST /api/households/join
 * Body: { inviteCode }
 * Adds the caller to a household as a member.
 */
export async function join(req: AuthenticatedRequest, res: Response): Promise<void> {
  const { inviteCode } = req.body ?? {};
  if (typeof inviteCode !== 'string' || inviteCode.trim().length === 0) {
    throw new AppError('Invite code is required', 400);
  }

  const household = await householdService.joinHousehold(req.user!.userId, inviteCode);
  sendSuccess(res, householdService.serializeHousehold(household));
}

/**
 * GET /api/households/:id/members
 * Lists the household's members (members only).
 */
export async function listMembers(req: AuthenticatedRequest, res: Response): Promise<void> {
  const household = await householdService.getHousehold(req.params.id, req.user!.userId);
  sendSuccess(res, householdService.serializeHousehold(household).members);
}

/**
 * DELETE /api/households/:id/members/:userId
 * Removes a member (admin only; cannot remove the last admin).
 */
export async function removeMember(req: AuthenticatedRequest, res: Response): Promise<void> {
  const household = await householdService.removeMember(
    req.params.id,
    req.user!.userId,
    req.params.userId
  );
  sendSuccess(res, householdService.serializeHousehold(household));
}

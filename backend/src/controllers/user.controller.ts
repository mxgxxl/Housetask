import { Response } from 'express';
import { UserModel } from '../models/User';
import { toPublicUser } from '../services/auth.service';
import { AppError } from '../middleware/error.middleware';
import { sanitizeString } from '../utils/sanitize';
import { sendSuccess } from '../utils/response';
import { AuthenticatedRequest } from '../types';

/**
 * GET /api/users/me
 * Returns the authenticated user's public profile.
 */
export async function getProfile(req: AuthenticatedRequest, res: Response): Promise<void> {
  const user = await UserModel.findById(req.user!.userId);
  if (!user) {
    throw new AppError('User not found', 404);
  }
  sendSuccess(res, await toPublicUser(user));
}

/**
 * PATCH /api/users/me
 * Body: { name?, avatarUrl? }
 * Updates the authenticated user's editable profile fields.
 */
export async function updateProfile(req: AuthenticatedRequest, res: Response): Promise<void> {
  const { name, avatarUrl } = req.body ?? {};
  const update: Record<string, unknown> = {};

  if (name !== undefined) {
    if (typeof name !== 'string' || name.trim().length === 0) {
      throw new AppError('Name must be a non-empty string', 400);
    }
    update.name = sanitizeString(name, 100, 'Name');
  }
  if (avatarUrl !== undefined) {
    if (typeof avatarUrl !== 'string') {
      throw new AppError('avatarUrl must be a string', 400);
    }
    update.avatarUrl = avatarUrl;
  }

  const user = await UserModel.findByIdAndUpdate(req.user!.userId, update, { new: true });
  if (!user) {
    throw new AppError('User not found', 404);
  }
  sendSuccess(res, await toPublicUser(user));
}

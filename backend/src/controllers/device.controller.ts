import { Response } from 'express';
import * as notificationService from '../services/notification.service';
import { sendSuccess } from '../utils/response';
import { AuthenticatedRequest } from '../types';

/**
 * POST /api/devices/register
 * Body: { token, platform }. Registers (or re-registers) the caller's FCM
 * device token for push notifications (PDR-008).
 */
export async function register(req: AuthenticatedRequest, res: Response): Promise<void> {
  const { token, platform } = req.body as { token: string; platform: 'ios' | 'android' };
  await notificationService.registerDeviceToken(req.user!.userId, token, platform);
  sendSuccess(res, { message: 'Device registered' }, 201);
}

/**
 * DELETE /api/devices/:token
 * Removes the caller's own device token (e.g. on logout). Idempotent —
 * deleting an already-removed or unknown token is a safe no-op.
 */
export async function remove(req: AuthenticatedRequest, res: Response): Promise<void> {
  await notificationService.removeDeviceToken(req.user!.userId, req.params.token);
  sendSuccess(res, { message: 'Device removed' });
}

import { Request, Response } from 'express';
import * as authService from '../services/auth.service';
import { sendSuccess } from '../utils/response';
import { AuthenticatedRequest } from '../types';

/**
 * POST /api/auth/register
 * Body: { email, password, name } — shape/format validated by
 * schemas/auth.schema.ts's registerSchema (TD-028).
 * Creates a user, hashes the password, and returns the user + token pair.
 */
export async function register(req: Request, res: Response): Promise<void> {
  const { email, password, name } = req.body;
  const result = await authService.register(email, password, name);
  sendSuccess(res, result, 201);
}

/**
 * POST /api/auth/login
 * Body: { email, password } — shape/format validated by loginSchema (TD-028).
 * Verifies credentials and returns the user + token pair.
 */
export async function login(req: Request, res: Response): Promise<void> {
  const { email, password } = req.body;
  const result = await authService.login(email, password);
  sendSuccess(res, result);
}

/**
 * POST /api/auth/refresh
 * Body: { refreshToken } — shape validated by refreshTokenSchema (TD-028).
 * Rotates the refresh token and returns a new token pair.
 */
export async function refresh(req: Request, res: Response): Promise<void> {
  const { refreshToken } = req.body;
  const tokens = await authService.refresh(refreshToken);
  sendSuccess(res, tokens);
}

/**
 * POST /api/auth/logout
 * Body: { refreshToken } — shape validated by refreshTokenSchema (TD-028).
 * Invalidates the given refresh token.
 */
export async function logout(req: Request, res: Response): Promise<void> {
  const { refreshToken } = req.body;
  await authService.logout(refreshToken);
  sendSuccess(res, { message: 'Logged out' });
}

/**
 * GET /api/auth/me
 * Returns the authenticated user's profile.
 */
export async function me(req: AuthenticatedRequest, res: Response): Promise<void> {
  const user = await authService.getMe(req.user!.userId);
  sendSuccess(res, user);
}

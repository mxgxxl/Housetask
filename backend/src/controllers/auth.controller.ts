import { Request, Response } from 'express';
import * as authService from '../services/auth.service';
import { AppError } from '../middleware/error.middleware';
import { sendSuccess } from '../utils/response';
import { AuthenticatedRequest } from '../types';

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * POST /api/auth/register
 * Body: { email, password, name }
 * Creates a user, hashes the password, and returns the user + token pair.
 */
export async function register(req: Request, res: Response): Promise<void> {
  const { email, password, name } = req.body ?? {};

  if (typeof email !== 'string' || !EMAIL_REGEX.test(email)) {
    throw new AppError('A valid email is required', 400);
  }
  if (typeof password !== 'string' || password.length < 6) {
    throw new AppError('Password must be at least 6 characters', 400);
  }
  if (typeof name !== 'string' || name.trim().length === 0) {
    throw new AppError('Name is required', 400);
  }

  const result = await authService.register(email, password, name);
  sendSuccess(res, result, 201);
}

/**
 * POST /api/auth/login
 * Body: { email, password }
 * Verifies credentials and returns the user + token pair.
 */
export async function login(req: Request, res: Response): Promise<void> {
  const { email, password } = req.body ?? {};

  if (typeof email !== 'string' || typeof password !== 'string') {
    throw new AppError('Email and password are required', 400);
  }

  const result = await authService.login(email, password);
  sendSuccess(res, result);
}

/**
 * POST /api/auth/refresh
 * Body: { refreshToken }
 * Rotates the refresh token and returns a new token pair.
 */
export async function refresh(req: Request, res: Response): Promise<void> {
  const { refreshToken } = req.body ?? {};

  if (typeof refreshToken !== 'string' || refreshToken.length === 0) {
    throw new AppError('Refresh token is required', 400);
  }

  const tokens = await authService.refresh(refreshToken);
  sendSuccess(res, tokens);
}

/**
 * POST /api/auth/logout
 * Body: { refreshToken }
 * Invalidates the given refresh token.
 */
export async function logout(req: Request, res: Response): Promise<void> {
  const { refreshToken } = req.body ?? {};

  if (typeof refreshToken !== 'string' || refreshToken.length === 0) {
    throw new AppError('Refresh token is required', 400);
  }

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

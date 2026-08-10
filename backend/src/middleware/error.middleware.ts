import { Request, Response, NextFunction } from 'express';
import { logger } from '../utils/logger';
import { sendError } from '../utils/response';

/**
 * A typed application error carrying an HTTP status code. Controllers and
 * services throw these; the error middleware turns them into API responses.
 */
export class AppError extends Error {
  public readonly status: number;

  constructor(message: string, status = 400) {
    super(message);
    this.status = status;
    this.name = 'AppError';
  }
}

/**
 * 404 handler for unmatched routes.
 */
export function notFoundHandler(req: Request, res: Response): void {
  sendError(res, `Route not found: ${req.method} ${req.originalUrl}`, 404);
}

/**
 * Centralized error handler. Normalizes known error shapes (AppError,
 * Mongoose validation/cast/duplicate-key) into the standard envelope.
 */
export function errorHandler(
  err: unknown,
  _req: Request,
  res: Response,
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  _next: NextFunction
): void {
  if (err instanceof AppError) {
    sendError(res, err.message, err.status);
    return;
  }

  const error = err as { name?: string; code?: number; message?: string; type?: string };

  // body-parser rejects oversized bodies with type 'entity.too.large'. Without
  // this branch it would fall through to the catch-all and surface as a 500,
  // hiding a client mistake behind a server error.
  if (error.type === 'entity.too.large') {
    sendError(res, 'Payload too large', 413);
    return;
  }

  // Mongoose validation error.
  if (error.name === 'ValidationError') {
    sendError(res, error.message || 'Validation error', 400);
    return;
  }

  // Mongoose bad ObjectId.
  if (error.name === 'CastError') {
    sendError(res, 'Invalid identifier', 400);
    return;
  }

  // MongoDB duplicate key.
  if (error.code === 11000) {
    sendError(res, 'Duplicate value violates a unique constraint', 409);
    return;
  }

  logger.error('Unhandled error', error.message || err);
  sendError(res, 'Internal server error', 500);
}

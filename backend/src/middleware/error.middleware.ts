import { Request, Response, NextFunction } from 'express';
import { logger } from '../utils/logger';
import { sendError } from '../utils/response';
import { captureServerError } from '../utils/sentry';
import { AuthenticatedRequest } from '../types';

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
 *
 * Only 5xx responses reach Sentry: a 4xx is an expected client outcome (bad
 * input, missing resource, duplicate key) and reporting every one would bury
 * genuine server failures in client noise. The one exception — a 401 from
 * detected refresh-token replay — is security-relevant despite being a 4xx,
 * so auth.service reports it itself via captureSecurityWarning, not here.
 */
export function errorHandler(
  err: unknown,
  req: Request,
  res: Response,
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  _next: NextFunction,
): void {
  const respond = (message: string, status: number): void => {
    if (status >= 500) {
      // req is typed as plain Request (Express's error-middleware signature
      // is fixed), but auth/membership middleware may have already enriched
      // it — userId/householdId are attached to the Sentry report whenever
      // they happen to be known, omitted otherwise (TD-037).
      const authReq = req as AuthenticatedRequest;
      // req.params is always populated by Express itself, but error-path
      // tests sometimes construct a bare object literal `as Request`
      // without it — optional chaining keeps this from crashing while
      // handling an error on a request shape that's already unusual.
      const householdId = req.params?.householdId;
      captureServerError(err, {
        category: 'http_5xx',
        route: req.path,
        ...(authReq.user?.userId ? { userId: authReq.user.userId } : {}),
        ...(householdId ? { householdId } : {}),
      });
    }
    sendError(res, message, status);
  };

  if (err instanceof AppError) {
    respond(err.message, err.status);
    return;
  }

  const error = err as { name?: string; code?: number; message?: string; type?: string };

  // body-parser rejects oversized bodies with type 'entity.too.large'. Without
  // this branch it would fall through to the catch-all and surface as a 500,
  // hiding a client mistake behind a server error.
  if (error.type === 'entity.too.large') {
    respond('Payload too large', 413);
    return;
  }

  // Malformed JSON is a client mistake, not a server fault. Left to the
  // catch-all it would answer 500, breaking the envelope's meaning and burying
  // real server errors in client noise once error tracking is wired up.
  if (error.type === 'entity.parse.failed') {
    respond('Invalid JSON payload', 400);
    return;
  }

  // Mongoose validation error.
  if (error.name === 'ValidationError') {
    respond(error.message || 'Validation error', 400);
    return;
  }

  // Mongoose bad ObjectId.
  if (error.name === 'CastError') {
    respond('Invalid identifier', 400);
    return;
  }

  // MongoDB duplicate key.
  if (error.code === 11000) {
    respond('Duplicate value violates a unique constraint', 409);
    return;
  }

  logger.error('Unhandled error', error.message || err);
  respond('Internal server error', 500);
}

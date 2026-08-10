import { Router, RequestHandler } from 'express';
import rateLimit from 'express-rate-limit';
import * as authController from '../controllers/auth.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { asyncHandler } from '../utils/asyncHandler';

/**
 * Rate limiter for credential endpoints: max 5 attempts per IP / 15 minutes.
 */
function buildAuthLimiter(): RequestHandler {
  return rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 5,
    standardHeaders: true,
    legacyHeaders: false,
    message: { success: false, error: 'Too many attempts, please try again later' },
  });
}

export interface AuthRouterOptions {
  /**
   * Mount the credential rate limiter. Disabled by the app factory under
   * NODE_ENV=test (integration tests drive many logins from one IP and would
   * exhaust the window), and opted back in by the test that asserts the 429.
   */
  rateLimit: boolean;
}

/**
 * Build the /api/auth router. It is a factory rather than a module-level
 * singleton so the rate limiter can be toggled per app instance — a shared
 * limiter would also leak its request counters between tests.
 */
export function createAuthRouter(options: AuthRouterOptions): Router {
  const router = Router();

  // No-op passthrough keeps the route definitions identical either way.
  const limiter: RequestHandler = options.rateLimit
    ? buildAuthLimiter()
    : (_req, _res, next) => next();

  router.post('/register', limiter, asyncHandler(authController.register));
  router.post('/login', limiter, asyncHandler(authController.login));
  router.post('/refresh', asyncHandler(authController.refresh));
  router.post('/logout', asyncHandler(authController.logout));
  router.get('/me', authMiddleware, asyncHandler(authController.me));

  return router;
}

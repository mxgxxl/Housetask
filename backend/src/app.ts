import express, { Application, NextFunction, Request, RequestHandler, Response } from 'express';
import cors from 'cors';
import mongoSanitize from 'express-mongo-sanitize';
import rateLimit from 'express-rate-limit';
import swaggerUi from 'swagger-ui-express';
import * as Sentry from '@sentry/node';

import { swaggerSpec } from './config/swagger';
import { notFoundHandler, errorHandler } from './middleware/error.middleware';
import { IDEMPOTENCY_STORE_KEY, idempotencyMetrics } from './middleware/idempotency.middleware';
import { requireJsonContentType } from './middleware/contentType.middleware';
import { authMiddleware } from './middleware/auth.middleware';
import { sendSuccess } from './utils/response';
import { IdempotencyStore, InMemoryIdempotencyStore } from './services/idempotency.store';

import { createAuthRouter } from './routes/auth.routes';
import householdRoutes from './routes/household.routes';
import taskRoutes from './routes/task.routes';
import shoppingRoutes from './routes/shopping.routes';
import userRoutes from './routes/user.routes';
import petRoutes from './routes/pet.routes';
import economyRoutes from './routes/economy.routes';
import deviceRoutes from './routes/device.routes';

export interface CreateAppOptions {
  /**
   * Force the credential rate limiter on or off. Defaults to enabled
   * everywhere except NODE_ENV=test, where hundreds of logins from a single
   * IP would otherwise exhaust the 5-per-15-minutes window and mask real
   * assertions. The test that asserts the 429 passes `true` explicitly.
   */
  authRateLimit?: boolean;
  /**
   * Force the global API rate limiter (TD-006) on or off. Defaults to
   * enabled everywhere except NODE_ENV=test, same reasoning as
   * authRateLimit: most suites fire far more than 100 requests against one
   * shared app instance across their `it()` blocks, which would start
   * returning 429s long before any assertion about the limiter itself runs.
   * The test that asserts the 429 opts back in explicitly.
   */
  globalRateLimit?: boolean;
  /**
   * Backing store for Idempotency-Key handling (ADR-007). Omitted outside
   * tests means the feature is off and the header is ignored; server.ts wires
   * the Redis-backed store.
   */
  idempotencyStore?: IdempotencyStore;
}

/**
 * Credential endpoints that carry their own stricter limiter (5/15min, see
 * auth.routes.ts). Only these are exempted from the global counter, so they
 * are never limited twice against two independent budgets.
 *
 * Deliberately NOT the whole `/api/auth` prefix: `/api/auth/refresh` and
 * `/api/auth/logout` have no limiter of their own, so exempting them left
 * them as the only completely unbounded routes in the API. They now fall
 * under the global 100/15min budget below — generous next to a legitimate
 * client's ~1 refresh per 15 minutes per device, while still bounding abuse.
 */
const OWN_LIMITER_PREFIXES = ['/api/auth/register', '/api/auth/login'];

/**
 * TD-006: 100 requests / 15 minutes / IP across every `/api` route except
 * the credential endpoints listed in {@link OWN_LIMITER_PREFIXES}. Uses
 * `req.originalUrl` rather than `req.path`/`req.baseUrl` so the exemption
 * holds regardless of exactly where this middleware ends up mounted.
 */
function buildGlobalLimiter(): RequestHandler {
  return rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 100,
    message: { success: false, error: 'Too many requests from this IP' },
    standardHeaders: true,
    legacyHeaders: false,
    skip: (req) => OWN_LIMITER_PREFIXES.some((prefix) => req.originalUrl.startsWith(prefix)),
  });
}

/**
 * Build and configure the Express application.
 *
 * Pure by design: no database/Redis/Socket.io connection and no `listen()`.
 * The bootstrap that wires those side effects lives in `server.ts`, which
 * lets tests mount the app against an in-memory MongoDB with no other
 * infrastructure running.
 */
export function createApp(options: CreateAppOptions = {}): Application {
  const app = express();

  // First middleware, only when Sentry is initialized (no-op otherwise).
  //
  // Deviation from the literal spec: @sentry/node v8+ removed
  // `Sentry.Handlers.requestHandler()` — calling it would throw, since
  // `Sentry.Handlers` no longer exists. HTTP instrumentation (spans, breadcrumbs)
  // is automatic once `initSentry()` runs, via the SDK's default httpIntegration
  // and its per-request isolation scope. What a request handler still usefully
  // adds is tagging that isolation scope with the request's method/path, so any
  // later capture during this request — even deep in a service with no access
  // to `req` — carries it without every call site passing context explicitly.
  app.use((req: Request, _res: Response, next: NextFunction) => {
    if (Sentry.isInitialized()) {
      Sentry.setContext('request', { method: req.method, path: req.path });
    }
    next();
  });

  const authRateLimit = options.authRateLimit ?? process.env.NODE_ENV !== 'test';

  // Routers read the store off the app so they can stay module singletons.
  app.set(
    IDEMPOTENCY_STORE_KEY,
    options.idempotencyStore ??
      (process.env.NODE_ENV === 'test' ? new InMemoryIdempotencyStore() : null),
  );

  // Behind a proxy (e.g. Railway) so rate-limit sees the real client IP.
  app.set('trust proxy', 1);

  // CORS: allow all in dev; restrict to CORS_ORIGINS in production.
  const corsOrigins = process.env.CORS_ORIGINS?.trim();
  app.use(
    cors({
      origin: corsOrigins ? corsOrigins.split(',').map((o) => o.trim()) : '*',
      credentials: true,
    }),
  );

  // Reject non-JSON payloads before parsing so they fail with 415 rather than
  // arriving as a silently empty body.
  app.use(requireJsonContentType);

  // Hard Rule 14: a bounded body is the cheapest defence against a trivial
  // memory-exhaustion DoS.
  app.use(express.json({ limit: '100kb' }));

  // Strip $-prefixed and dotted keys from body/params/query so a payload like
  // { "email": { "$ne": null } } cannot turn a findOne into an operator (TD-004).
  app.use(mongoSanitize());
  // No urlencoded parser: the API is JSON-only, so parsing form bodies would
  // only widen the attack surface (extended:true pulls in qs prototype/deep
  // object parsing) for input no route ever reads.

  // Health check.
  app.get('/health', (_req: Request, res: Response) => {
    res.json({ success: true, data: { status: 'ok', uptime: process.uptime() } });
  });

  // Fail-open counters for the idempotency store (TD-033). Authenticated
  // because it reveals operational state; a Prometheus exporter can scrape it
  // once APM lands, but the numbers are useful today for postmortems asking
  // "how many writes ran without duplicate protection during the outage?".
  app.get('/metrics/idempotency', authMiddleware, (_req: Request, res: Response) => {
    sendSuccess(res, idempotencyMetrics());
  });

  // API documentation (Swagger UI) — mounted before the global limiter below,
  // so browsing the docs (which fires several sub-resource requests) is never
  // rate-limited.
  app.use('/api/docs', swaggerUi.serve, swaggerUi.setup(swaggerSpec));

  // TD-006: global rate limit across every /api route (auth endpoints excluded,
  // see buildGlobalLimiter's `skip`).
  const globalRateLimitEnabled = options.globalRateLimit ?? process.env.NODE_ENV !== 'test';
  if (globalRateLimitEnabled) {
    app.use('/api', buildGlobalLimiter());
  }

  // API routes.
  app.use('/api/auth', createAuthRouter({ rateLimit: authRateLimit }));
  app.use('/api/users', userRoutes);
  app.use('/api/households', householdRoutes);
  // Nested, household-scoped resources.
  app.use('/api/households/:householdId/tasks', taskRoutes);
  app.use('/api/households/:householdId/shopping', shoppingRoutes);
  // PDR-001 A1: household pet + economy. Nested rather than the flat
  // /api/pets and /api/economy sketched in the spec, to reuse requireMembership
  // as the single membership checkpoint (Hard Rule 8) instead of inventing a
  // second way to resolve "which household" from query params.
  app.use('/api/households/:householdId/pet', petRoutes);
  app.use('/api/households/:householdId/economy', economyRoutes);
  // PDR-008: not household-scoped — a device token belongs to a user
  // (they may be in multiple households), so no requireMembership check.
  app.use('/api/devices', deviceRoutes);

  // 404 + centralized error handling (must be last).
  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}

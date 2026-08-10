import express, { Application, Request, Response } from 'express';
import cors from 'cors';
import swaggerUi from 'swagger-ui-express';

import { swaggerSpec } from './config/swagger';
import { notFoundHandler, errorHandler } from './middleware/error.middleware';
import { IDEMPOTENCY_STORE_KEY } from './middleware/idempotency.middleware';
import { IdempotencyStore, InMemoryIdempotencyStore } from './services/idempotency.store';

import { createAuthRouter } from './routes/auth.routes';
import householdRoutes from './routes/household.routes';
import taskRoutes from './routes/task.routes';
import shoppingRoutes from './routes/shopping.routes';
import userRoutes from './routes/user.routes';

export interface CreateAppOptions {
  /**
   * Force the credential rate limiter on or off. Defaults to enabled
   * everywhere except NODE_ENV=test, where hundreds of logins from a single
   * IP would otherwise exhaust the 5-per-15-minutes window and mask real
   * assertions. The test that asserts the 429 passes `true` explicitly.
   */
  authRateLimit?: boolean;
  /**
   * Backing store for Idempotency-Key handling (ADR-007). Omitted outside
   * tests means the feature is off and the header is ignored; server.ts wires
   * the Redis-backed store.
   */
  idempotencyStore?: IdempotencyStore;
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

  const authRateLimit = options.authRateLimit ?? process.env.NODE_ENV !== 'test';

  // Routers read the store off the app so they can stay module singletons.
  app.set(
    IDEMPOTENCY_STORE_KEY,
    options.idempotencyStore ??
      (process.env.NODE_ENV === 'test' ? new InMemoryIdempotencyStore() : null)
  );

  // Behind a proxy (e.g. Railway) so rate-limit sees the real client IP.
  app.set('trust proxy', 1);

  // CORS: allow all in dev; restrict to CORS_ORIGINS in production.
  const corsOrigins = process.env.CORS_ORIGINS?.trim();
  app.use(
    cors({
      origin: corsOrigins ? corsOrigins.split(',').map((o) => o.trim()) : '*',
      credentials: true,
    })
  );

  // Hard Rule 14: a bounded body is the cheapest defence against a trivial
  // memory-exhaustion DoS.
  app.use(express.json({ limit: '100kb' }));
  // No urlencoded parser: the API is JSON-only, so parsing form bodies would
  // only widen the attack surface (extended:true pulls in qs prototype/deep
  // object parsing) for input no route ever reads.

  // Health check.
  app.get('/health', (_req: Request, res: Response) => {
    res.json({ success: true, data: { status: 'ok', uptime: process.uptime() } });
  });

  // API documentation (Swagger UI).
  app.use('/api/docs', swaggerUi.serve, swaggerUi.setup(swaggerSpec));

  // API routes.
  app.use('/api/auth', createAuthRouter({ rateLimit: authRateLimit }));
  app.use('/api/users', userRoutes);
  app.use('/api/households', householdRoutes);
  // Nested, household-scoped resources.
  app.use('/api/households/:householdId/tasks', taskRoutes);
  app.use('/api/households/:householdId/shopping', shoppingRoutes);

  // 404 + centralized error handling (must be last).
  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}

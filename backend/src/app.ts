import express, { Application, Request, Response } from 'express';
import cors from 'cors';
import swaggerUi from 'swagger-ui-express';

import { swaggerSpec } from './config/swagger';
import { notFoundHandler, errorHandler } from './middleware/error.middleware';

import authRoutes from './routes/auth.routes';
import householdRoutes from './routes/household.routes';
import taskRoutes from './routes/task.routes';
import shoppingRoutes from './routes/shopping.routes';
import userRoutes from './routes/user.routes';

/**
 * Build and configure the Express application.
 *
 * Pure by design: no database/Redis/Socket.io connection and no `listen()`.
 * The bootstrap that wires those side effects lives in `server.ts`, which
 * lets tests mount the app against an in-memory MongoDB with no other
 * infrastructure running.
 */
export function createApp(): Application {
  const app = express();

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

  app.use(express.json({ limit: '1mb' }));
  app.use(express.urlencoded({ extended: true }));

  // Health check.
  app.get('/health', (_req: Request, res: Response) => {
    res.json({ success: true, data: { status: 'ok', uptime: process.uptime() } });
  });

  // API documentation (Swagger UI).
  app.use('/api/docs', swaggerUi.serve, swaggerUi.setup(swaggerSpec));

  // API routes.
  app.use('/api/auth', authRoutes);
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

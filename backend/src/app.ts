import 'dotenv/config';
import express, { Application, Request, Response } from 'express';
import cors from 'cors';
import { createServer } from 'http';

import { connectDatabase, disconnectDatabase } from './config/database';
import { initSocket } from './config/socket';
import { disconnectRedis } from './config/redis';
import { logger } from './utils/logger';
import { notFoundHandler, errorHandler } from './middleware/error.middleware';

import authRoutes from './routes/auth.routes';
import householdRoutes from './routes/household.routes';
import taskRoutes from './routes/task.routes';
import shoppingRoutes from './routes/shopping.routes';
import userRoutes from './routes/user.routes';

const PORT = Number(process.env.PORT) || 3000;

/**
 * Build and configure the Express application (without starting it).
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

/**
 * Boot the server: connect to MongoDB, start HTTP + Socket.io (with the
 * Redis adapter), and register graceful shutdown handlers.
 */
async function start(): Promise<void> {
  try {
    await connectDatabase();

    const app = createApp();
    const httpServer = createServer(app);

    // Attach Socket.io (initializes Redis + adapter internally).
    await initSocket(httpServer);

    httpServer.listen(PORT, () => {
      logger.info(`HomeSync API listening on port ${PORT}`);
    });

    const shutdown = async (signal: string): Promise<void> => {
      logger.info(`Received ${signal}, shutting down gracefully...`);
      httpServer.close();
      await Promise.allSettled([disconnectDatabase(), disconnectRedis()]);
      process.exit(0);
    };

    process.on('SIGINT', () => void shutdown('SIGINT'));
    process.on('SIGTERM', () => void shutdown('SIGTERM'));
  } catch (err) {
    logger.error('Failed to start server', (err as Error).message);
    process.exit(1);
  }
}

// Only auto-start when run directly (not when imported for tests).
if (require.main === module) {
  void start();
}

import 'dotenv/config';
import { createServer } from 'http';

import { createApp } from './app';
import { connectDatabase, disconnectDatabase } from './config/database';
import { initSocket } from './config/socket';
import { disconnectRedis } from './config/redis';
import { logger } from './utils/logger';
import { validateProductionEnv } from './utils/env';
import { RedisIdempotencyStore } from './services/idempotency.store';

const PORT = Number(process.env.PORT) || 3000;

/**
 * Boot the server: connect to MongoDB, build the Express app, start HTTP +
 * Socket.io (with the Redis adapter), and register graceful shutdown handlers.
 *
 * All I/O side effects live here so that `createApp()` stays pure and can be
 * mounted in tests without MongoDB, Redis or Socket.io.
 */
export async function start(): Promise<void> {
  try {
    // Refuse to boot a misconfigured production process before anything binds.
    validateProductionEnv();

    await connectDatabase();

    // Redis-backed so idempotency holds across horizontally scaled instances.
    // The store resolves its client lazily, so it may be built before initSocket
    // establishes the Redis connection.
    const app = createApp({ idempotencyStore: new RedisIdempotencyStore() });
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

// Only auto-start when run directly (not when imported).
if (require.main === module) {
  void start();
}

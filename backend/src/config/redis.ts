import { Redis } from 'ioredis';
import { logger } from '../utils/logger';

const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379';

/**
 * Two dedicated connections are required by the Socket.io Redis adapter
 * (one to publish, one to subscribe). We also expose the pub client for
 * generic app-level caching if needed.
 */
let pubClient: Redis | null = null;
let subClient: Redis | null = null;

function createClient(label: string): Redis {
  const client = new Redis(REDIS_URL, {
    lazyConnect: false,
    maxRetriesPerRequest: null,
    retryStrategy: (times) => Math.min(times * 200, 5000),
  });

  client.on('connect', () => logger.info(`Redis (${label}) connected`));
  client.on('error', (err) => logger.error(`Redis (${label}) error`, err.message));

  return client;
}

/**
 * Initialize the Redis pub/sub client pair and wait until both are ready.
 * @returns The pub and sub clients for the Socket.io adapter.
 */
export async function initRedis(): Promise<{ pubClient: Redis; subClient: Redis }> {
  pubClient = createClient('pub');
  subClient = pubClient.duplicate();
  subClient.on('connect', () => logger.info('Redis (sub) connected'));
  subClient.on('error', (err) => logger.error('Redis (sub) error', err.message));

  return { pubClient, subClient };
}

/**
 * Access the primary Redis client. Throws if Redis was not initialized.
 */
export function getRedis(): Redis {
  if (!pubClient) {
    throw new Error('Redis has not been initialized. Call initRedis() first.');
  }
  return pubClient;
}

/**
 * Gracefully disconnect Redis clients (used on shutdown).
 */
export async function disconnectRedis(): Promise<void> {
  await Promise.allSettled([pubClient?.quit(), subClient?.quit()]);
  pubClient = null;
  subClient = null;
}

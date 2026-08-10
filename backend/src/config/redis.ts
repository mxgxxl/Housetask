import { Redis, RedisOptions } from 'ioredis';
import { logger } from '../utils/logger';

const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379';

/**
 * Two dedicated connections are required by the Socket.io Redis adapter
 * (one to publish, one to subscribe). We also expose the pub client for
 * generic app-level caching if needed.
 */
let pubClient: Redis | null = null;
let subClient: Redis | null = null;
let commandClient: Redis | null = null;

/**
 * Deadline for application-level Redis commands. Without it ioredis queues
 * commands indefinitely while disconnected and an Idempotency-Key POST never
 * returns (TD-031).
 *
 * It is deliberately NOT applied to the pub/sub pair: the Socket.io adapter
 * holds long-lived subscriptions and does not catch command rejections, so a
 * timeout there surfaces as an unhandled rejection that kills the process —
 * turning a Redis blip into a crash loop.
 */
const COMMAND_TIMEOUT_MS = 1000;

function createClient(label: string, extra: Partial<RedisOptions> = {}): Redis {
  const client = new Redis(REDIS_URL, {
    lazyConnect: false,
    maxRetriesPerRequest: null,
    retryStrategy: (times) => Math.min(times * 200, 5000),
    ...extra,
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

  // Separate connection for application commands, bounded so a Redis outage
  // rejects fast instead of queueing forever.
  commandClient = createClient('commands', { commandTimeout: COMMAND_TIMEOUT_MS });

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
 * Access the bounded client for application-level commands (idempotency store).
 * Throws if Redis was not initialized, which callers treat as "unavailable".
 */
export function getCommandClient(): Redis {
  if (!commandClient) {
    throw new Error('Redis has not been initialized. Call initRedis() first.');
  }
  return commandClient;
}

/**
 * Gracefully disconnect Redis clients (used on shutdown).
 */
export async function disconnectRedis(): Promise<void> {
  await Promise.allSettled([pubClient?.quit(), subClient?.quit(), commandClient?.quit()]);
  pubClient = null;
  subClient = null;
  commandClient = null;
}

import { Server as HttpServer } from 'http';
import { Server as SocketIOServer, Socket } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { initRedis } from './redis';
import { verifyAccessToken } from '../utils/jwt';
import { UserModel } from '../models/User';
import { logger } from '../utils/logger';

let io: SocketIOServer | null = null;

/**
 * Compute the room name for a given household.
 */
export function householdRoom(householdId: string): string {
  return `household_${householdId}`;
}

/**
 * Initialize Socket.io on top of the given HTTP server:
 *  - Attaches the Redis adapter so events broadcast across all instances.
 *  - Authenticates every connection with the JWT sent in `auth.token`.
 *  - Joins each socket to a room per household the user belongs to.
 */
export async function initSocket(httpServer: HttpServer): Promise<SocketIOServer> {
  io = new SocketIOServer(httpServer, {
    cors: {
      origin: resolveCorsOrigins(),
      credentials: true,
    },
  });

  // Multi-instance broadcasting via Redis pub/sub.
  const { pubClient, subClient } = await initRedis();
  io.adapter(createAdapter(pubClient, subClient));

  // Authenticate each socket handshake with the access token.
  io.use(async (socket, next) => {
    try {
      const token =
        (socket.handshake.auth?.token as string | undefined) ||
        (socket.handshake.headers?.authorization?.replace('Bearer ', '') as string | undefined);

      if (!token) {
        return next(new Error('Authentication token missing'));
      }

      const payload = verifyAccessToken(token);
      const user = await UserModel.findById(payload.userId).select('households').lean();
      if (!user) {
        return next(new Error('User not found'));
      }

      socket.data.userId = payload.userId;
      socket.data.households = (user.households || []).map((h) => h.toString());
      next();
    } catch (err) {
      logger.warn('Socket auth failed', (err as Error).message);
      next(new Error('Authentication failed'));
    }
  });

  io.on('connection', (socket: Socket) => {
    const userId = socket.data.userId as string;
    const households = (socket.data.households as string[]) || [];

    // Join a room per household so household-scoped events reach this user.
    households.forEach((id) => socket.join(householdRoom(id)));
    logger.debug(`Socket connected: user=${userId} rooms=${households.length}`);

    // Allow the client to (re)join a household room after joining/creating one.
    socket.on('household:join', (householdId: string) => {
      if (typeof householdId === 'string' && householdId.length > 0) {
        socket.join(householdRoom(householdId));
      }
    });

    socket.on('household:leave', (householdId: string) => {
      if (typeof householdId === 'string' && householdId.length > 0) {
        socket.leave(householdRoom(householdId));
      }
    });

    socket.on('disconnect', (reason) => {
      logger.debug(`Socket disconnected: user=${userId} reason=${reason}`);
    });
  });

  logger.info('Socket.io initialized with Redis adapter');
  return io;
}

/**
 * Access the initialized Socket.io server.
 */
export function getIO(): SocketIOServer {
  if (!io) {
    throw new Error('Socket.io has not been initialized. Call initSocket() first.');
  }
  return io;
}

// Emitting before initSocket() is legitimate in tests but a bug in production,
// so it is logged once per process rather than on every emit (avoids flooding).
let warnedUninitialized = false;

/**
 * Emit an event to every member of a household currently connected.
 *
 * Safe no-op when Socket.io has not been initialized — services can therefore
 * be exercised in tests without a running HTTP server or Redis. The first
 * skipped emit logs a warning so a missing `initSocket()` in production is
 * visible instead of silent.
 */
export function emitToHousehold(householdId: string, event: string, payload: unknown): void {
  if (!io) {
    if (!warnedUninitialized) {
      warnedUninitialized = true;
      logger.warn(
        `Socket.io not initialized — skipping realtime emits (first skipped: ${event})`
      );
    }
    return;
  }
  io.to(householdRoom(householdId)).emit(event, payload);
}

/**
 * Whether Socket.io has been initialized. Useful for health checks and tests.
 */
export function isSocketInitialized(): boolean {
  return io !== null;
}

function resolveCorsOrigins(): string | string[] {
  const origins = process.env.CORS_ORIGINS;
  if (!origins || origins.trim() === '') return '*';
  return origins.split(',').map((o) => o.trim());
}

import { Server as HttpServer } from 'http';
import { Server as SocketIOServer, Socket, ExtendedError } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { initRedis } from './redis';
import { verifyAccessToken } from '../utils/jwt';
import { UserModel } from '../models/User';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { logger } from '../utils/logger';
import { captureServerError } from '../utils/sentry';

let io: SocketIOServer | null = null;

/**
 * Compute the room name for a given household.
 */
export function householdRoom(householdId: string): string {
  return `household_${householdId}`;
}

/**
 * Compute the room name for a single user (TD-066 B5).
 *
 * P1 splits the economy in two: household XP and the joint savings goal are
 * shared, but the wallet, the weekly budget and personal XP belong to ONE
 * member (PDR-012, PDR-017). Broadcasting those to `household_<id>` would
 * hand every member everyone else's balance — a privacy leak the Fase A
 * economy never had, because there was only ever one shared purse to leak.
 *
 * A per-user room rather than tracking socket ids: a member can have several
 * devices connected at once, and all of them must see their own wallet move.
 */
export function userRoom(userId: string): string {
  return `user_${userId}`;
}

/**
 * Socket.io handshake middleware logic, extracted so it can be invoked as
 * `void authenticateSocket(...)` from the void-returning io.use() callback.
 */
async function authenticateSocket(
  socket: Socket,
  next: (err?: ExtendedError) => void,
): Promise<void> {
  try {
    const token =
      (socket.handshake.auth?.token as string | undefined) ||
      (socket.handshake.headers?.authorization?.replace('Bearer ', '') as string | undefined);

    if (!token) {
      return next(new Error('Authentication token missing'));
    }

    const payload = verifyAccessToken(token);
    const user = await UserModel.findById(payload.userId).select('_id').lean();
    if (!user) {
      return next(new Error('User not found'));
    }

    // TD-001 commit 7: rooms are resolved from HouseholdMember, the single
    // source of membership, instead of the denormalized `User.households` that
    // used to shadow it (finding H1). Until this commit the socket and the HTTP
    // surface answered from DIFFERENT copies, so a drift between them showed up
    // as the worst kind of bug: data that loads correctly over HTTP and then
    // never updates live, indistinguishable from nothing happening. One indexed
    // lookup on `{userId: 1}`, once per connection.
    const memberships = await HouseholdMemberModel.find({ userId: user._id })
      .select('householdId')
      .lean();

    socket.data.userId = payload.userId;
    socket.data.households = memberships.map((m) => m.householdId.toString());

    if (memberships.length === 0) {
      // Called out in docs/TD-001-DESIGN.md §7 as a risk of this phase: a user
      // who joins no rooms loses realtime with no visible error. Legitimate for
      // someone with no household yet, so it is a debug line, not a warning —
      // but it has to be greppable when someone reports "it stopped updating".
      logger.debug(`Socket auth: user=${payload.userId} belongs to no household`);
    }
    next();
  } catch (err) {
    logger.warn('Socket auth failed', (err as Error).message);
    // No userId yet — auth hasn't succeeded (TD-037). Expected to have some
    // background noise (an access token expiring mid-session before the
    // client refreshes and reconnects is routine); alert on a rate spike,
    // not on any single occurrence — see CLAUDE.md's TD-037 alert guide.
    captureServerError(err, { category: 'socket_auth' });
    next(new Error('Authentication failed'));
  }
}

// Recovers the householdId from a room name (`household_<id>`) for the
// Sentry householdId tag (TD-037) — joinRoomSafely/leaveRoomSafely only
// ever get called with household rooms, but this stays defensive (returns
// undefined, tag omitted) rather than assuming the prefix is always there.
function householdIdFromRoom(room: string): string | undefined {
  const prefix = 'household_';
  return room.startsWith(prefix) ? room.slice(prefix.length) : undefined;
}

/**
 * `Socket.join`/`leave` are typed `Promise<void> | void` because a custom
 * adapter (this app uses `@socket.io/redis-adapter`, ADR-002) can make room
 * membership a real cross-instance Redis operation that can reject — the
 * built-in in-memory adapter resolves synchronously (`void`). Wrapping in
 * `Promise.resolve()` handles both without a runtime type check, and
 * `.catch()` logs with the socket/room context a bare `void` would discard,
 * rather than relying solely on the generic unhandledRejection handler
 * (TD-032) that has none.
 */
function joinRoomSafely(socket: Socket, userId: string, room: string): void {
  Promise.resolve(socket.join(room)).catch((err: unknown) => {
    logger.warn(`Socket failed to join room: user=${userId} room=${room}`, err);
    const householdId = householdIdFromRoom(room);
    captureServerError(err, {
      category: 'socket_room',
      userId,
      ...(householdId ? { householdId } : {}),
    });
  });
}

function leaveRoomSafely(socket: Socket, userId: string, room: string): void {
  Promise.resolve(socket.leave(room)).catch((err: unknown) => {
    logger.warn(`Socket failed to leave room: user=${userId} room=${room}`, err);
    const householdId = householdIdFromRoom(room);
    captureServerError(err, {
      category: 'socket_room',
      userId,
      ...(householdId ? { householdId } : {}),
    });
  });
}

export interface InitSocketOptions {
  /**
   * Skip the Redis adapter, keeping broadcasts inside this process.
   *
   * Exists so the socket layer can be tested for real — two clients, actual
   * delivery — instead of by the stand-in assertions that were the only
   * option before (see td001-commit7-single-source.test.ts, which documents
   * the gap: "the risk this commit carries is not a wrong answer, it is a
   * SILENT one"). Everything else about the server stays identical, so what
   * a test exercises is the production wiring minus the broker.
   *
   * Refused outright under NODE_ENV=production: a single-instance broadcast
   * there would silently break realtime for everyone not connected to the
   * instance that happened to handle the write (ADR-002).
   */
  withoutRedisAdapter?: boolean;
}

/**
 * Initialize Socket.io on top of the given HTTP server:
 *  - Attaches the Redis adapter so events broadcast across all instances.
 *  - Authenticates every connection with the JWT sent in `auth.token`.
 *  - Joins each socket to a room per household the user belongs to, plus one
 *    room of its own so personal economy events can reach it alone (B5).
 */
export async function initSocket(
  httpServer: HttpServer,
  options: InitSocketOptions = {},
): Promise<SocketIOServer> {
  if (options.withoutRedisAdapter && process.env.NODE_ENV === 'production') {
    throw new Error('withoutRedisAdapter is a test-only option and must never be used in production');
  }

  io = new SocketIOServer(httpServer, {
    cors: {
      origin: resolveCorsOrigins(),
      credentials: true,
    },
  });

  if (!options.withoutRedisAdapter) {
    // Multi-instance broadcasting via Redis pub/sub.
    const { pubClient, subClient } = await initRedis();
    io.adapter(createAdapter(pubClient, subClient));
  }

  // Authenticate each socket handshake with the access token. io.use()'s
  // middleware type is void-returning (socket, next) => void, so the async
  // logic lives in a named function and is invoked with `void` below —
  // fire-and-forget: authenticateSocket's own try/catch always resolves
  // (never rejects) since every failure path calls next(new Error(...))
  // instead of throwing past the catch, so there is nothing an unhandled
  // rejection could hide here.
  io.use((socket, next) => {
    void authenticateSocket(socket, next);
  });

  io.on('connection', (socket: Socket) => {
    const userId = socket.data.userId as string;
    const households = (socket.data.households as string[]) || [];

    // Join a room per household so household-scoped events reach this user.
    households.forEach((id) => joinRoomSafely(socket, userId, householdRoom(id)));

    // ...and one room of this user's own (TD-066 B5). Unconditional, unlike
    // the household rooms: a member with no household still has a wallet and
    // personal XP, both of which travel with the account (PDR-017).
    joinRoomSafely(socket, userId, userRoom(userId));

    logger.debug(`Socket connected: user=${userId} rooms=${households.length}`);

    // Allow the client to (re)join a household room after joining/creating one.
    socket.on('household:join', (householdId: string) => {
      if (typeof householdId === 'string' && householdId.length > 0) {
        joinRoomSafely(socket, userId, householdRoom(householdId));
      }
    });

    socket.on('household:leave', (householdId: string) => {
      if (typeof householdId === 'string' && householdId.length > 0) {
        leaveRoomSafely(socket, userId, householdRoom(householdId));
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
      logger.warn(`Socket.io not initialized — skipping realtime emits (first skipped: ${event})`);
    }
    return;
  }
  io.to(householdRoom(householdId)).emit(event, payload);
}

/**
 * Emit an event to one user's devices only (TD-066 B5).
 *
 * The counterpart to `emitToHousehold` for everything P1 makes personal:
 * `economy:reward` and `economy:budget_updated` carry a member's own coins,
 * XP and remaining budget, and no other member of the household is entitled
 * to see them (PDR-012). Reaches every device that member has connected,
 * because the room is keyed on the user rather than on a socket.
 *
 * Same safe no-op contract as `emitToHousehold`, sharing its one-per-process
 * warning: a service must remain testable without a running Socket.io, and a
 * missing `initSocket()` in production must still be visible rather than
 * silently swallowing every realtime update.
 */
export function emitToUser(userId: string, event: string, payload: unknown): void {
  if (!io) {
    if (!warnedUninitialized) {
      warnedUninitialized = true;
      logger.warn(`Socket.io not initialized — skipping realtime emits (first skipped: ${event})`);
    }
    return;
  }
  io.to(userRoom(userId)).emit(event, payload);
}

/**
 * Whether Socket.io has been initialized. Useful for health checks and tests.
 */
export function isSocketInitialized(): boolean {
  return io !== null;
}

/**
 * Shut the server down and forget it, so `emitToHousehold`/`emitToUser` go
 * back to their no-op behaviour.
 *
 * Test teardown: a suite that starts a real server must also stop it, or Jest
 * reports an open handle and the next suite inherits a live `io` that quietly
 * changes what "not initialized" means for every service under test.
 */
export async function closeSocket(): Promise<void> {
  if (!io) return;
  const server = io;
  io = null;
  // Block body, not a concise one: `close()` is typed as returning a Promise
  // as well as taking a callback, and returning it from the executor would
  // hand `new Promise` a thenable it never awaits (no-misused-promises).
  await new Promise<void>((resolve) => {
    void server.close(() => resolve());
  });
}

function resolveCorsOrigins(): string | string[] {
  const origins = process.env.CORS_ORIGINS;
  if (!origins || origins.trim() === '') return '*';
  return origins.split(',').map((o) => o.trim());
}

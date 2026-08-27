import { AddressInfo } from 'net';
import { Server, createServer } from 'http';
import { Server as SocketIOServer } from 'socket.io';
import { io as ioClient, Socket as ClientSocket } from 'socket.io-client';
import { closeSocket, emitToHousehold, emitToUser, householdRoom, initSocket, userRoom } from '../config/socket';
import { buildTestApp } from './setup';
import {
  TestUser,
  createTestHousehold,
  createTestUser,
  joinTestHousehold,
} from './helpers';

/**
 * Socket rooms and per-user delivery (TD-066 B5).
 *
 * The FIRST test in this repo that drives a real Socket.io server with real
 * clients. Everything before it stood in for delivery by asserting the
 * handshake's inputs — td001-commit7-single-source.test.ts says so in as many
 * words, and names the reason it mattered: a broken handshake is a SILENT
 * failure, since HTTP keeps working and only realtime dies.
 *
 * B5 makes that gap dangerous rather than merely untested. Until now every
 * event was household-wide, so a mis-targeted emit was at worst noise. A
 * personal wallet event delivered to the wrong room is a privacy leak
 * (PDR-012), and no amount of input-assertion can prove it does not happen —
 * only watching who actually receives it can.
 *
 * Runs without Redis via `withoutRedisAdapter`, which is refused outright
 * under NODE_ENV=production; everything else is the production wiring.
 */
let app: Server;
let httpServer: Server;
let ioServer: SocketIOServer;
let port: number;

const clients: ClientSocket[] = [];

/** Connect a client with a user's real access token and wait for the handshake. */
async function connectAs(user: TestUser): Promise<ClientSocket> {
  const client = ioClient(`http://localhost:${port}`, {
    auth: { token: user.accessToken },
    transports: ['websocket'],
    reconnection: false,
  });
  clients.push(client);

  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('socket did not connect in time')), 5000);
    client.on('connect', () => {
      clearTimeout(timer);
      resolve();
    });
    client.on('connect_error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });

  return client;
}

/** Collect every occurrence of `event` on a client until `waitMs` elapses. */
function collect(client: ClientSocket, event: string): { received: unknown[] } {
  const received: unknown[] = [];
  client.on(event, (payload: unknown) => received.push(payload));
  return { received };
}

/**
 * Give the event loop time for a broadcast to land.
 *
 * Deliberately a real wait rather than an await on a promise that resolves on
 * receipt: half of these assertions are that something NEVER arrives, and
 * "never" can only be observed by waiting and finding nothing.
 */
function settle(ms = 150): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

beforeAll(async () => {
  app = await buildTestApp();

  httpServer = createServer();
  await new Promise<void>((resolve) => httpServer.listen(0, resolve));
  port = (httpServer.address() as AddressInfo).port;

  ioServer = await initSocket(httpServer, { withoutRedisAdapter: true });
});

afterEach(async () => {
  for (const client of clients.splice(0)) {
    client.close();
  }
  await settle(20);
});

afterAll(async () => {
  await closeSocket();
  await new Promise<void>((resolve) => httpServer.close(() => resolve()));
});

describe('room names', () => {
  it('keeps household and user rooms in separate namespaces', () => {
    // A household id and a user id are both ObjectId hex strings, so without
    // distinct prefixes a user could land in a household's room by collision
    // of format rather than of value.
    expect(householdRoom('abc')).toBe('household_abc');
    expect(userRoom('abc')).toBe('user_abc');
    expect(householdRoom('abc')).not.toBe(userRoom('abc'));
  });
});

describe('handshake', () => {
  it('joins the user to both its household rooms and its own room', async () => {
    const user = await createTestUser(app);
    const household = await createTestHousehold(app, user);

    const client = await connectAs(user);
    await settle();

    const sockets = await ioServer.in(userRoom(user.id)).fetchSockets();
    expect(sockets).toHaveLength(1);
    expect(sockets[0].rooms.has(householdRoom(household.id))).toBe(true);
    expect(sockets[0].rooms.has(userRoom(user.id))).toBe(true);

    client.close();
  });

  it('joins the user room even when the user belongs to no household', async () => {
    // A wallet and personal XP travel with the account (PDR-017), so they
    // exist before any household does — the personal room must not be
    // conditional on membership the way the household rooms are.
    const user = await createTestUser(app);

    await connectAs(user);
    await settle();

    const sockets = await ioServer.in(userRoom(user.id)).fetchSockets();
    expect(sockets).toHaveLength(1);
    expect(sockets[0].rooms.has(userRoom(user.id))).toBe(true);
  });

  it('reaches every device the same user has connected', async () => {
    // Keyed on the user rather than on a socket precisely for this: a phone
    // and a tablet must both see the wallet move.
    const user = await createTestUser(app);
    await createTestHousehold(app, user);

    const phone = await connectAs(user);
    const tablet = await connectAs(user);
    await settle();

    const onPhone = collect(phone, 'economy:reward');
    const onTablet = collect(tablet, 'economy:reward');

    emitToUser(user.id, 'economy:reward', { coins: 5 });
    await settle();

    expect(onPhone.received).toEqual([{ coins: 5 }]);
    expect(onTablet.received).toEqual([{ coins: 5 }]);
  });
});

describe('emitToUser isolation — the reason the user room exists', () => {
  it('delivers a personal event to its owner and to nobody else in the household',
    async () => {
      const owner = await createTestUser(app);
      const household = await createTestHousehold(app, owner);
      const mate = await createTestUser(app);
      await joinTestHousehold(app, mate, household.inviteCode);

      const ownerClient = await connectAs(owner);
      const mateClient = await connectAs(mate);
      await settle();

      const onOwner = collect(ownerClient, 'economy:reward');
      const onMate = collect(mateClient, 'economy:reward');

      emitToUser(owner.id, 'economy:reward', { receiptId: 'r1', coins: 5, personalXp: 10 });
      await settle();

      expect(onOwner.received).toEqual([{ receiptId: 'r1', coins: 5, personalXp: 10 }]);
      // The whole point: a housemate must never learn what is in someone
      // else's wallet (PDR-012).
      expect(onMate.received).toEqual([]);
    });

  it('keeps budget updates private too', async () => {
    const owner = await createTestUser(app);
    const household = await createTestHousehold(app, owner);
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    const ownerClient = await connectAs(owner);
    const mateClient = await connectAs(mate);
    await settle();

    const onOwner = collect(ownerClient, 'economy:budget_updated');
    const onMate = collect(mateClient, 'economy:budget_updated');

    emitToUser(owner.id, 'economy:budget_updated', {
      weekKey: '2026-W35',
      remaining: 28,
      dailyReleased: 33,
    });
    await settle();

    expect(onOwner.received).toHaveLength(1);
    expect(onMate.received).toEqual([]);
  });
});

describe('emitToHousehold still reaches the whole household', () => {
  it('delivers household XP to every member', async () => {
    // The counterpart check: splitting the channels must not accidentally
    // make the SHARED events private too.
    const owner = await createTestUser(app);
    const household = await createTestHousehold(app, owner);
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    const ownerClient = await connectAs(owner);
    const mateClient = await connectAs(mate);
    await settle();

    const onOwner = collect(ownerClient, 'household:xp_updated');
    const onMate = collect(mateClient, 'household:xp_updated');

    emitToHousehold(household.id, 'household:xp_updated', { householdXp: 20, level: 1 });
    await settle();

    expect(onOwner.received).toEqual([{ householdXp: 20, level: 1 }]);
    expect(onMate.received).toEqual([{ householdXp: 20, level: 1 }]);
  });

  it('does not leak a household event to someone outside it', async () => {
    const owner = await createTestUser(app);
    const household = await createTestHousehold(app, owner);
    const stranger = await createTestUser(app);
    await createTestHousehold(app, stranger, 'Otra casa');

    const ownerClient = await connectAs(owner);
    const strangerClient = await connectAs(stranger);
    await settle();

    const onOwner = collect(ownerClient, 'household:xp_updated');
    const onStranger = collect(strangerClient, 'household:xp_updated');

    emitToHousehold(household.id, 'household:xp_updated', { householdXp: 20, level: 1 });
    await settle();

    expect(onOwner.received).toHaveLength(1);
    expect(onStranger.received).toEqual([]);
  });
});

describe('authentication', () => {
  it('refuses a connection with no token', async () => {
    const client = ioClient(`http://localhost:${port}`, {
      transports: ['websocket'],
      reconnection: false,
    });
    clients.push(client);

    const error = await new Promise<Error>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('expected a connect_error')), 5000);
      client.on('connect_error', (err) => {
        clearTimeout(timer);
        resolve(err);
      });
    });

    expect(error.message).toMatch(/authentication/i);
  });
});

import { Server, createServer } from 'http';
import mongoose from 'mongoose';

import { createApp } from '../app';

// Redundant with jest.config.js (which sets this before any module loads) but
// kept so the intent is explicit when reading the setup file on its own.
process.env.NODE_ENV = 'test';

const openServers: Server[] = [];

/**
 * Build an HTTP server wrapping the real Express app for tests.
 *
 * It uses the same `createApp()` as production but connects to no Redis and no
 * Socket.io — `emitToHousehold` degrades to a logged no-op (see
 * config/socket.ts), so services under test never touch a broker.
 *
 * The server is started once per suite and reused by every request. Handing
 * supertest a bare Express app instead makes it spin up (and tear down) an
 * ephemeral server per request; across the hundreds of requests in this suite
 * that recycles ports fast enough that a client occasionally connects to a
 * socket left over from a closed server and fails with
 * "Parse Error: Expected HTTP/, RTSP/ or ICE/". One long-lived server per
 * suite removes that whole class of flakiness.
 */
export async function buildTestApp(): Promise<Server> {
  const server = createServer(createApp());
  await new Promise<void>((resolve) => {
    server.listen(0, resolve);
  });
  openServers.push(server);
  return server;
}

// Connects to the shared in-memory MongoDB started once in globalSetup.ts.
// No external MongoDB or Redis is ever contacted by this suite.
beforeAll(async () => {
  const uri = process.env.MONGO_TEST_URI;
  if (!uri) {
    throw new Error('MONGO_TEST_URI is not set — globalSetup did not run');
  }
  await mongoose.connect(uri);
});

// Every test starts from an empty database so suites and cases are independent.
afterEach(async () => {
  const { collections } = mongoose.connection;
  await Promise.all(Object.values(collections).map((collection) => collection.deleteMany({})));
});

afterAll(async () => {
  await Promise.all(
    openServers.splice(0).map(
      (server) =>
        new Promise<void>((resolve) => {
          server.close(() => resolve());
        })
    )
  );
  await mongoose.disconnect();
});

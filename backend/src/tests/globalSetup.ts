import { MongoMemoryServer } from 'mongodb-memory-server';

/**
 * The in-memory MongoDB is stored on globalThis so `globalTeardown` can stop
 * the very same instance (both hooks run in Jest's parent process).
 */
export interface GlobalWithMongo {
  __HOMESYNC_MONGOD__?: MongoMemoryServer;
}

/**
 * Start ONE in-memory MongoDB for the whole run and publish its URI.
 *
 * Booting a server per suite costs a mongod launch each time and made the
 * slowest suite exceed the default 10s launch timeout, so every suite instead
 * connects to this shared instance and isolates itself by wiping collections
 * after each test (see setup.ts).
 */
export default async function globalSetup(): Promise<void> {
  const mongod = await MongoMemoryServer.create({
    instance: { launchTimeout: 60_000 },
  });

  (globalThis as GlobalWithMongo).__HOMESYNC_MONGOD__ = mongod;
  process.env.MONGO_TEST_URI = mongod.getUri();
}

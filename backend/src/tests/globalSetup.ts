import { MongoMemoryReplSet } from 'mongodb-memory-server';

/**
 * The in-memory MongoDB is stored on globalThis so `globalTeardown` can stop
 * the very same instance (both hooks run in Jest's parent process).
 */
export interface GlobalWithMongo {
  __HOMESYNC_MONGOD__?: MongoMemoryReplSet;
}

/**
 * Start ONE in-memory MongoDB for the whole run and publish its URI.
 *
 * Booting a server per suite costs a mongod launch each time and made the
 * slowest suite exceed the default 10s launch timeout, so every suite instead
 * connects to this shared instance and isolates itself by wiping collections
 * after each test (see setup.ts).
 *
 * A single-node REPLICA SET rather than a standalone (TD-001): MongoDB
 * transactions are only available on a replica set or mongos, and
 * `removeMember` needs one to keep Hard Rule 9 — never delete a household's
 * last admin — atomic once membership lives in its own collection. Production
 * is unaffected either way: Atlas is always a replica set, even on the free
 * tier. One node is enough; the point is the transaction support, not
 * redundancy.
 */
export default async function globalSetup(): Promise<void> {
  const mongod = await MongoMemoryReplSet.create({
    replSet: { count: 1 },
    instanceOpts: [{ launchTimeout: 60_000 }],
  });

  (globalThis as GlobalWithMongo).__HOMESYNC_MONGOD__ = mongod;
  process.env.MONGO_TEST_URI = mongod.getUri();
}

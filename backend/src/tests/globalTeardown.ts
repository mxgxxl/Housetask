import { GlobalWithMongo } from './globalSetup';

/**
 * Stop the shared in-memory MongoDB started by `globalSetup`.
 */
export default async function globalTeardown(): Promise<void> {
  const mongod = (globalThis as GlobalWithMongo).__HOMESYNC_MONGOD__;
  if (mongod) {
    await mongod.stop();
  }
}

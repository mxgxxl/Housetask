import { Types } from 'mongoose';

import { RefreshTokenModel } from '../models/RefreshToken';
import { migrateRefreshTokens } from '../scripts/migrate-refresh-tokens';

async function seedTokens(count: number): Promise<void> {
  await RefreshTokenModel.create(
    Array.from({ length: count }, (_, i) => ({
      token: `token-${i}`,
      userId: new Types.ObjectId(),
      expiresAt: new Date(Date.now() + 60_000),
    }))
  );
}

describe('migrate-refresh-tokens script (TD-024)', () => {
  it('should count without deleting when not confirmed', async () => {
    await seedTokens(3);

    const deleted = await migrateRefreshTokens(false);

    // A mistyped command must never mass-log-out a production user base.
    expect(deleted).toBe(0);
    expect(await RefreshTokenModel.countDocuments({})).toBe(3);
  });

  it('should wipe the collection when confirmed', async () => {
    await seedTokens(3);

    const deleted = await migrateRefreshTokens(true);

    expect(deleted).toBe(3);
    expect(await RefreshTokenModel.countDocuments({})).toBe(0);
  });

  it('should be idempotent on an empty collection', async () => {
    expect(await migrateRefreshTokens(true)).toBe(0);
    expect(await migrateRefreshTokens(true)).toBe(0);
  });
});

import 'dotenv/config';
import { connectDatabase, disconnectDatabase } from '../config/database';
import { RefreshTokenModel } from '../models/RefreshToken';
import { logger } from '../utils/logger';

/**
 * One-time deploy action for TD-024.
 *
 * Commit b2c481e switched refresh tokens to SHA-256 storage. Rows written
 * before it hold raw JWTs, which no longer match a hashed lookup: every active
 * session would fail its next refresh, and — worse — land in the replay branch,
 * firing a family revocation and a security warning per user. Wiping the
 * collection converts that noisy failure into a clean re-login.
 *
 * Safe to run repeatedly: an empty collection deletes 0 and exits 0.
 *
 * Usage:
 *   npx ts-node src/scripts/migrate-refresh-tokens.ts        # dry run, counts only
 *   npx ts-node src/scripts/migrate-refresh-tokens.ts --yes  # performs the delete
 */
export async function migrateRefreshTokens(confirmed: boolean): Promise<number> {
  const total = await RefreshTokenModel.countDocuments({});
  logger.info(`refreshtokens documents found: ${total}`);

  if (!confirmed) {
    // Destructive by nature, so it never runs by accident: an operator who
    // mistypes the command gets a count, not a mass logout.
    logger.warn(
      'Dry run — nothing deleted. Re-run with --yes to wipe the collection ' +
        '(all users will need to log in again).',
    );
    return 0;
  }

  if (total === 0) {
    logger.info('Collection is already empty; nothing to do.');
    return 0;
  }

  const { deletedCount } = await RefreshTokenModel.deleteMany({});
  logger.info(`Deleted ${deletedCount} refresh token(s); all sessions now require a fresh login.`);
  return deletedCount;
}

async function main(): Promise<void> {
  const confirmed = process.argv.includes('--yes');

  try {
    await connectDatabase();
    await migrateRefreshTokens(confirmed);
  } catch (err) {
    logger.error('Refresh-token migration failed', (err as Error).message);
    process.exitCode = 1;
  } finally {
    await disconnectDatabase();
  }
}

// Only run when invoked directly, so tests can import the function.
if (require.main === module) {
  void main();
}

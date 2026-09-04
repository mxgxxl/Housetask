import 'dotenv/config';
import { connectDatabase, disconnectDatabase } from '../config/database';
import { destroyExpiredHouseholds } from '../services/household-destruction.service';
import { logger } from '../utils/logger';

/**
 * Scheduled job for PDR-022 D4: destroy every household whose 24-hour grace
 * period has expired.
 *
 * Run it on a schedule (a Railway cron, same as `purge-trash.ts` — see the
 * "Trash purge" section in backend/README.md for the pattern). It shares
 * `destroyExpiredHouseholds` → `confirmDestruction` → `destroyInTransaction`
 * with the creator-facing endpoint, so a household destroyed by the clock and
 * one destroyed by a tap cascade identically. That is the same arrangement
 * `purgeDeletedTasks` has with its endpoint (TD-048), and for the same reason:
 * two implementations of a destructive cascade WILL drift, and the one nobody
 * watches is the one that drifts.
 *
 * Idempotent and safe to run as often as you like: it selects only rows whose
 * deadline has passed, and destroying a household deletes its row. A run with
 * nothing due does nothing.
 *
 * The job is a safety net, not the primary path. The client confirms the
 * destruction itself when the user comes back after the deadline; this exists
 * for the household whose creator schedules a deletion and never opens the app
 * again, so a household is never left permanently half-deleted.
 *
 * Usage:
 *   npx ts-node src/scripts/destroy-scheduled-households.ts
 */
async function main(): Promise<void> {
  try {
    await connectDatabase();
    const destroyed = await destroyExpiredHouseholds();
    logger.info(`Destroyed ${destroyed} household(s) whose grace period had expired.`);
  } catch (err) {
    logger.error('Scheduled household destruction run failed', (err as Error).message);
    process.exitCode = 1;
  } finally {
    await disconnectDatabase();
  }
}

// Only run when invoked directly, so tests can import the service half.
if (require.main === module) {
  void main();
}

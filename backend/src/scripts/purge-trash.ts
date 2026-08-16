import 'dotenv/config';
import { connectDatabase, disconnectDatabase } from '../config/database';
import { DEFAULT_PURGE_DAYS, purgeDeletedTasks } from '../services/task.service';
import { logger } from '../utils/logger';

/**
 * Maintenance script for TD-048 (follow-up to TD-046): soft-deleted tasks
 * (`isDeleted: true`) are never automatically removed, so the `tasks`
 * collection accumulates trash forever. Run this on a schedule (see the
 * "Trash purge" section in backend/README.md for a Railway cron example) to
 * hard-delete anything older than `--days` (default 30).
 *
 * Global across every household — the endpoint counterpart,
 * `POST /households/:householdId/tasks/purge`, scopes the same query
 * (taskService.purgeDeletedTasks) to a single household for an admin
 * triggering it from the app.
 *
 * Usage:
 *   npx ts-node src/scripts/purge-trash.ts            # purge trash older than 30 days
 *   npx ts-node src/scripts/purge-trash.ts --days 60   # custom retention window
 */
function parseDaysArg(argv: string[]): number {
  const idx = argv.indexOf('--days');
  if (idx === -1) return DEFAULT_PURGE_DAYS;

  const raw = argv[idx + 1];
  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`Invalid --days value: ${raw ?? '(missing)'}`);
  }
  return parsed;
}

async function main(): Promise<void> {
  const days = parseDaysArg(process.argv.slice(2));

  try {
    await connectDatabase();
    const deleted = await purgeDeletedTasks(days);
    logger.info(`Purged ${deleted} soft-deleted task(s) older than ${days} day(s).`);
  } catch (err) {
    logger.error('Trash purge failed', (err as Error).message);
    process.exitCode = 1;
  } finally {
    await disconnectDatabase();
  }
}

// Only run when invoked directly, so tests can import parseDaysArg/purgeDeletedTasks.
if (require.main === module) {
  void main();
}

export { parseDaysArg };

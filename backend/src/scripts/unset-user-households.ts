import 'dotenv/config';
import { connectDatabase, disconnectDatabase } from '../config/database';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { UserModel } from '../models/User';
import { logger } from '../utils/logger';

/**
 * TD-001 closing cleanup: drop the legacy `User.households` array from every
 * user document.
 *
 * The field left the schema in commit 7 — nothing reads it, nothing writes it,
 * and `toPublicUser` now derives the same list from HouseholdMember. But
 * removing a path from a Mongoose schema does not delete stored data, so the
 * array survived in the documents. It was left there on purpose for one
 * window: while it existed it was an independent second opinion the validation
 * script could compare the collection against. That window is over.
 *
 * Leaving it would be worse than deleting it. A field that is never written
 * but still present reads, to anyone opening the collection later, like state
 * the system maintains — and the first person to trust it would be trusting a
 * snapshot frozen at commit 7.
 *
 * SAFETY GATE: refuses to unset a user whose legacy array names a household
 * they have NO membership row for. That would mean the collection is missing
 * something the legacy field still remembers, and the legacy field would be
 * the last record of it — exactly the evidence a recovery would need. The
 * check runs per user at the moment of writing rather than trusting an earlier
 * sweep.
 *
 * Prints a summary in the same shape as the phase-1 backfill and the
 * `Household.members` unset, for the same reason (the TD-024 lesson): a
 * migration that leaves no record of having run becomes an argument later.
 *
 * Usage:
 *   npx ts-node src/scripts/unset-user-households.ts        # dry run
 *   npx ts-node src/scripts/unset-user-households.ts --yes  # applies it
 */
export interface UnsetUserHouseholdsSummary {
  mode: 'DRY RUN' | 'APPLIED';
  at: string;
  scanned: number;
  withField: number;
  alreadyClean: number;
  wouldUnset: number;
  unset: number;
  skipped: { userId: string; missing: string[] }[];
}

export function formatSummary(s: UnsetUserHouseholdsSummary): string[] {
  return [
    `TD-001 $unset of User.households — ${s.mode} at ${s.at}`,
    `  users scanned:             ${s.scanned}`,
    `  with a households field:   ${s.withField}`,
    `  already clean:             ${s.alreadyClean}`,
    s.mode === 'DRY RUN'
      ? `  would be unset:            ${s.wouldUnset}`
      : `  unset:                     ${s.unset}`,
    `  skipped:                   ${s.skipped.length}`,
    ...s.skipped.map(
      (k) => `    ! ${k.userId} names households with no membership row: ${k.missing.join(', ')}`,
    ),
  ];
}

export async function unsetUserHouseholds(
  apply: boolean,
): Promise<UnsetUserHouseholdsSummary> {
  const summary: UnsetUserHouseholdsSummary = {
    mode: apply ? 'APPLIED' : 'DRY RUN',
    at: new Date().toISOString(),
    scanned: 0,
    withField: 0,
    alreadyClean: 0,
    wouldUnset: 0,
    unset: 0,
    skipped: [],
  };

  // `households` is no longer on the schema, so only the raw collection can
  // still see it.
  const raw = UserModel.collection;
  const users = await raw.find({}, { projection: { _id: 1, households: 1 } }).toArray();

  for (const user of users) {
    summary.scanned += 1;

    if (!('households' in user)) {
      summary.alreadyClean += 1;
      continue;
    }
    summary.withField += 1;

    const legacy = ((user.households ?? []) as unknown[]).map((id) => String(id));
    const rows = await HouseholdMemberModel.find({ userId: user._id })
      .select('householdId')
      .lean();
    const owned = new Set(rows.map((r) => r.householdId.toString()));
    const missing = legacy.filter((id) => !owned.has(id));

    if (missing.length > 0) {
      summary.skipped.push({ userId: user._id.toString(), missing });
      continue;
    }

    if (!apply) {
      summary.wouldUnset += 1;
      continue;
    }

    await raw.updateOne({ _id: user._id }, { $unset: { households: '' } });
    summary.unset += 1;
  }

  return summary;
}

async function main(): Promise<void> {
  const apply = process.argv.includes('--yes');

  await connectDatabase();
  try {
    if (!apply) {
      logger.warn('DRY RUN — nothing will be written. Re-run with --yes to apply.');
    }
    const summary = await unsetUserHouseholds(apply);
    logger.info('');
    for (const line of formatSummary(summary)) logger.info(line);

    if (summary.skipped.length > 0) {
      logger.warn('');
      logger.warn('Users were skipped: their legacy array names a household the collection');
      logger.warn('does not have. Investigate BEFORE re-running — that array is the only');
      logger.warn('surviving record of those memberships.');
      process.exitCode = 1;
    }
  } catch (err) {
    logger.error('$unset run failed', (err as Error).message);
    process.exitCode = 1;
  } finally {
    await disconnectDatabase();
  }
}

if (require.main === module) {
  void main();
}

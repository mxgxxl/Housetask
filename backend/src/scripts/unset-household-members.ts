import 'dotenv/config';
import { connectDatabase, disconnectDatabase } from '../config/database';
import { HouseholdModel } from '../models/Household';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { logger } from '../utils/logger';

/**
 * TD-001 commit 7: drop the embedded `Household.members` array from every
 * document.
 *
 * THIS IS THE ONLY IRREVERSIBLE STEP OF THE WHOLE MIGRATION. Every phase up to
 * here could be undone by deploying the previous commit; after this there is no
 * copy of the embedded array left, and going back to it would need a reverse
 * backfill that does not exist plus a window of lost writes.
 *
 * It is safe to run because nothing has read the array since commit 5 and
 * nothing has written it since commit 6 — it has been dead weight, and stale
 * dead weight at that. What it removes is not data, it is a fossil.
 *
 * SAFETY GATE, deliberately not optional: the script refuses to unset a
 * household that has no rows in HouseholdMember. Such a household would be
 * orphaned (unreadable, undeletable) and its embedded array would be the last
 * surviving record of who belonged to it — precisely the evidence a recovery
 * would need. `td001-validate-fase4.ts --check-orphan-households` reports zero
 * today; this re-checks at the moment of the write rather than trusting that
 * an earlier run still holds.
 *
 * Prints a summary in the same shape as the phase-1 backfill, for the same
 * reason (the TD-024 lesson): a migration whose execution left no record turns
 * into an argument later about whether it ran at all.
 *
 * Usage:
 *   npx ts-node src/scripts/unset-household-members.ts        # dry run
 *   npx ts-node src/scripts/unset-household-members.ts --yes  # applies it
 */
export interface UnsetSummary {
  mode: 'DRY RUN' | 'APPLIED';
  at: string;
  scanned: number;
  withEmbeddedArray: number;
  wouldUnset: number;
  unset: number;
  skippedOrphans: string[];
  alreadyClean: number;
}

export function formatSummary(s: UnsetSummary): string[] {
  return [
    `TD-001 $unset of Household.members — ${s.mode} at ${s.at}`,
    `  households scanned:        ${s.scanned}`,
    `  with an embedded array:    ${s.withEmbeddedArray}`,
    `  already clean:             ${s.alreadyClean}`,
    s.mode === 'DRY RUN'
      ? `  would be unset:            ${s.wouldUnset}`
      : `  unset:                     ${s.unset}`,
    `  skipped (orphans):         ${s.skippedOrphans.length}`,
    ...s.skippedOrphans.map((id) => `    ! ${id} has no HouseholdMember rows — NOT touched`),
  ];
}

export async function unsetEmbeddedMembers(apply: boolean): Promise<UnsetSummary> {
  const summary: UnsetSummary = {
    mode: apply ? 'APPLIED' : 'DRY RUN',
    at: new Date().toISOString(),
    scanned: 0,
    withEmbeddedArray: 0,
    wouldUnset: 0,
    unset: 0,
    skippedOrphans: [],
    alreadyClean: 0,
  };

  // `members` is already gone from the schema, so a typed query cannot see it.
  // Go through the raw collection, which is the only thing that still can.
  const raw = HouseholdModel.collection;
  const households = await raw.find({}, { projection: { _id: 1, members: 1 } }).toArray();

  for (const household of households) {
    summary.scanned += 1;

    if (!('members' in household)) {
      summary.alreadyClean += 1;
      continue;
    }
    summary.withEmbeddedArray += 1;

    const memberships = await HouseholdMemberModel.countDocuments({
      householdId: household._id,
    });
    if (memberships === 0) {
      summary.skippedOrphans.push(household._id.toString());
      continue;
    }

    if (!apply) {
      summary.wouldUnset += 1;
      continue;
    }

    await raw.updateOne({ _id: household._id }, { $unset: { members: '' } });
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
      logger.warn('This step is IRREVERSIBLE: no copy of the embedded array survives it.');
    }
    const summary = await unsetEmbeddedMembers(apply);
    logger.info('');
    for (const line of formatSummary(summary)) logger.info(line);

    if (summary.skippedOrphans.length > 0) {
      logger.warn('');
      logger.warn('Orphan households were skipped. Investigate them BEFORE re-running:');
      logger.warn('their embedded array is the last record of who belonged to them.');
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

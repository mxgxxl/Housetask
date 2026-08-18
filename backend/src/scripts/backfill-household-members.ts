import 'dotenv/config';
import { connectDatabase, disconnectDatabase } from '../config/database';
import { HouseholdModel } from '../models/Household';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { logger } from '../utils/logger';

/**
 * Backfill for TD-001, phase 1: copy every embedded `Household.members` entry
 * into the HouseholdMember collection.
 *
 * Runs after the dual-write deploy (commit 047f078), which keeps NEW
 * memberships in step. This fills in everything that already existed.
 *
 * Non-destructive by construction: it only inserts missing rows. It never
 * deletes and never overwrites an existing one — a row whose role diverges is
 * reported, not corrected. That matters because at this point the embedded
 * array is still the authority: a divergence means the dual write has a hole,
 * and silently rewriting it would erase the only evidence of that.
 *
 * Safe to re-run: already-migrated households insert 0 and exit 0.
 *
 * Usage:
 *   npx ts-node src/scripts/backfill-household-members.ts        # dry run
 *   npx ts-node src/scripts/backfill-household-members.ts --yes  # writes
 */
export interface BackfillSummary {
  households: number;
  membershipsSeen: number;
  created: number;
  alreadyPresent: number;
  divergent: Array<{ householdId: string; userId: string; embedded: string; collection: string }>;
}

export async function backfillHouseholdMembers(confirmed: boolean): Promise<BackfillSummary> {
  const summary: BackfillSummary = {
    households: 0,
    membershipsSeen: 0,
    created: 0,
    alreadyPresent: 0,
    divergent: [],
  };

  // Cursor rather than find().toArray(): the collection is small today, but a
  // backfill that only works while the data is small is a backfill that fails
  // exactly when it matters.
  const cursor = HouseholdModel.find({}, { members: 1 }).lean().cursor();

  for await (const household of cursor) {
    summary.households += 1;

    for (const member of household.members ?? []) {
      summary.membershipsSeen += 1;

      const existing = await HouseholdMemberModel.findOne({
        householdId: household._id,
        userId: member.user,
      }).lean();

      if (existing) {
        summary.alreadyPresent += 1;
        if (existing.role !== member.role) {
          summary.divergent.push({
            householdId: household._id.toString(),
            userId: member.user.toString(),
            embedded: member.role,
            collection: existing.role,
          });
        }
        continue;
      }

      if (confirmed) {
        await HouseholdMemberModel.create({
          householdId: household._id,
          userId: member.user,
          role: member.role,
          // Carried over, not defaulted: a migrated membership must keep the
          // date the user actually joined.
          joinedAt: member.joinedAt,
        });
      }
      summary.created += 1;
    }
  }

  return summary;
}

/**
 * Print the summary in a shape meant to be pasted verbatim into the TD-001
 * entry of docs/TECH_DEBT.md.
 *
 * This exists because of TD-024: its migration script was left documented as
 * "run with --yes during the deploy window", and to this day nobody knows
 * whether it ever ran. A migration that leaves no trace is one somebody has to
 * re-reason about six months later.
 */
export function formatSummary(summary: BackfillSummary, confirmed: boolean): string {
  const lines = [
    `TD-001 backfill — ${confirmed ? 'APPLIED' : 'DRY RUN'} — ${new Date().toISOString()}`,
    `  households scanned:   ${summary.households}`,
    `  memberships seen:     ${summary.membershipsSeen}`,
    `  rows ${confirmed ? 'created' : 'that would be created'}: ${summary.created}`,
    `  already present:      ${summary.alreadyPresent}`,
    `  divergent roles:      ${summary.divergent.length}`,
  ];

  for (const d of summary.divergent) {
    lines.push(
      `    - household ${d.householdId} user ${d.userId}: ` +
        `embedded=${d.embedded} collection=${d.collection} (NOT overwritten)`,
    );
  }

  if (summary.divergent.length > 0) {
    lines.push(
      '  ^ A divergence means the dual write has a hole. Investigate before the',
      '    cutover; do not reconcile by hand until the cause is known.',
    );
  }

  return lines.join('\n');
}

async function main(): Promise<void> {
  const confirmed = process.argv.includes('--yes');

  try {
    await connectDatabase();
    const summary = await backfillHouseholdMembers(confirmed);
    logger.info(`\n${formatSummary(summary, confirmed)}`);

    if (!confirmed) {
      logger.warn('Dry run — nothing written. Re-run with --yes to apply.');
    }
  } catch (err) {
    logger.error('Household-member backfill failed', (err as Error).message);
    process.exitCode = 1;
  } finally {
    await disconnectDatabase();
  }
}

// Only run when invoked directly, so tests can import the functions.
if (require.main === module) {
  void main();
}

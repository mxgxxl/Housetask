import mongoose, { Types } from 'mongoose';

import { EconomyLedgerModel } from '../models/EconomyLedger';
import { HouseholdEconomyMigrationModel } from '../models/HouseholdEconomyMigration';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { HouseholdModel } from '../models/Household';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { logger } from '../utils/logger';

/**
 * Activate the P1 economy for ONE household (TD-066 B11, design §6).
 *
 * ── Why activation is manual, per household, and needs a named person ────
 * The Fase A ledger records `householdId` and never `userId`: the balance
 * belongs to the HOUSEHOLD. P1 wallets are personal, so carrying that balance
 * over requires naming a person, and no query can name them — splitting it
 * evenly would invent a distribution nobody agreed to, and crediting every
 * member the full amount would multiply the household's money by its size.
 *
 * So `legacyWalletUserId` is a required input, recorded before the credit is
 * written. That is what turns an irreversible guess into an auditable
 * decision (design §6.3 and its closing dependency list).
 *
 * ── What this does NOT do ────────────────────────────────────────────────
 * Nothing is destroyed. `EconomyLedger`, `GET /economy`, the pet and its
 * cosmetics all stay exactly as they were (design §6.5): the two economies
 * coexist, and turning the flag back off returns the household to Fase A
 * reads with every P1 row still on disk for reconciliation.
 *
 * Usage:
 *   npx ts-node src/scripts/activate-p1-economy.ts \
 *     --household=<householdId> --legacy-wallet=<userId>          # dry run
 *   npx ts-node src/scripts/activate-p1-economy.ts \
 *     --household=<householdId> --legacy-wallet=<userId> --yes    # applies
 *
 * See docs/TD-066-RUNBOOK.md before running this against production.
 */

export interface ActivationSummary {
  mode: 'DRY RUN' | 'APPLIED';
  householdId: string;
  householdName: string;
  legacyWalletUserId: string;
  legacyBalanceSnapshot: number;
  legacyLedgerWatermark: string | null;
  memberCount: number;
  /** True when a migration row already existed, so nothing was written. */
  alreadyMigrated: boolean;
  /** True when the legacy credit was written (or would be) by this run. */
  creditWritten: boolean;
}

export function formatSummary(s: ActivationSummary): string {
  return [
    `[${s.mode}] P1 activation for "${s.householdName}" (${s.householdId})`,
    `  already migrated:   ${s.alreadyMigrated}`,
    `  members:            ${s.memberCount}`,
    `  legacy wallet:      ${s.legacyWalletUserId}`,
    `  legacy balance:     ${s.legacyBalanceSnapshot}`,
    `  ledger watermark:   ${s.legacyLedgerWatermark ?? '(no entries)'}`,
    `  legacy credit:      ${s.creditWritten ? 'written' : 'not written'}`,
  ].join('\n');
}

export interface ActivateOptions {
  householdId: string;
  legacyWalletUserId: string;
  apply: boolean;
}

/**
 * The whole activation, as one callable function so it can be tested without
 * spawning a process.
 *
 * Idempotent by two independent mechanisms, deliberately not one: the
 * migration row's unique `householdId` stops a second activation, and the
 * personal ledger's unique `(userId, reason, refType, refId)` stops a second
 * credit even if the row were somehow removed and the script re-run.
 */
export async function activateP1Economy(options: ActivateOptions): Promise<ActivationSummary> {
  const { householdId, legacyWalletUserId, apply } = options;

  // Checked before anything is read, not just documented: an empty value here
  // would mean crediting the household's whole balance to nobody, and the
  // failure would be silent.
  if (!legacyWalletUserId || !Types.ObjectId.isValid(legacyWalletUserId)) {
    throw new Error('legacyWalletUserId is required and must be a valid user id');
  }
  if (!householdId || !Types.ObjectId.isValid(householdId)) {
    throw new Error('householdId is required and must be a valid household id');
  }

  const household = await HouseholdModel.findById(householdId).lean();
  if (!household) {
    throw new Error(`Household ${householdId} does not exist`);
  }

  const householdObjectId = new Types.ObjectId(householdId);

  // The named wallet must belong to the household. Crediting a stranger would
  // move the household's money out of it entirely, and the mistake would be
  // invisible until someone went looking for coins that were never there.
  const membership = await HouseholdMemberModel.findOne({
    householdId: householdObjectId,
    userId: new Types.ObjectId(legacyWalletUserId),
  }).lean();
  if (!membership) {
    throw new Error(
      `User ${legacyWalletUserId} is not a member of household ${householdId} — refusing to credit the legacy balance to someone outside it`,
    );
  }

  const memberCount = await HouseholdMemberModel.countDocuments({
    householdId: householdObjectId,
  });

  const existing = await HouseholdEconomyMigrationModel.findOne({
    householdId: householdObjectId,
  }).lean();

  // The snapshot and the watermark are taken together and never recomputed.
  // `EconomyLedger` keeps moving after activation — the pet still spends from
  // it — so "what was the balance when we switched" stops being answerable
  // the moment anyone feeds the pet.
  const [balanceRow] = await EconomyLedgerModel.aggregate<{ total: number }>([
    { $match: { householdId: householdObjectId } },
    { $group: { _id: null, total: { $sum: '$amount' } } },
  ]);
  const legacyBalanceSnapshot = balanceRow?.total ?? 0;

  const newest = await EconomyLedgerModel.findOne({ householdId: householdObjectId })
    .sort({ createdAt: -1 })
    .select('createdAt')
    .lean();
  const legacyLedgerWatermark = newest?.createdAt ?? null;

  const summary: ActivationSummary = {
    mode: apply ? 'APPLIED' : 'DRY RUN',
    householdId,
    householdName: household.name,
    legacyWalletUserId,
    legacyBalanceSnapshot: existing?.legacyBalanceSnapshot ?? legacyBalanceSnapshot,
    legacyLedgerWatermark: (existing?.legacyLedgerWatermark ?? legacyLedgerWatermark)
      ? (existing?.legacyLedgerWatermark ?? legacyLedgerWatermark)!.toISOString()
      : null,
    memberCount,
    alreadyMigrated: !!existing,
    creditWritten: false,
  };

  if (existing) {
    // Already migrated: report the recorded figures and change nothing. Not an
    // error — re-running the script must be safe, which is what makes it
    // usable from a runbook someone is following under pressure.
    return summary;
  }

  if (!apply) {
    // A dry run reports what WOULD happen, including the credit, but touches
    // nothing.
    summary.creditWritten = legacyBalanceSnapshot > 0;
    return summary;
  }

  const session = await mongoose.startSession();
  try {
    await session.withTransaction(async () => {
      // The row goes in first. It is what `isP1Enabled` reads, so writing it
      // last would leave a window where the credit exists but the household
      // is still on Fase A — money in a wallet nothing yet reads.
      await HouseholdEconomyMigrationModel.create(
        [
          {
            householdId: householdObjectId,
            phase: 'active' as const,
            legacyBalanceSnapshot,
            ...(legacyLedgerWatermark ? { legacyLedgerWatermark } : {}),
            legacyWalletUserId: new Types.ObjectId(legacyWalletUserId),
            activatedAt: new Date(),
          },
        ],
        { session },
      );

      if (legacyBalanceSnapshot > 0) {
        await PersonalCoinLedgerModel.create(
          [
            {
              userId: new Types.ObjectId(legacyWalletUserId),
              householdId: householdObjectId,
              amount: legacyBalanceSnapshot,
              reason: 'legacy_balance' as const,
              refType: 'legacy_migration' as const,
              // Keyed on the household, so the ledger's own unique index makes
              // a second legacy credit for this household impossible — an
              // independent guarantee from the migration row above.
              refId: householdId,
              effectiveAt: new Date(),
            },
          ],
          { session },
        );
        summary.creditWritten = true;
      }
    });
  } finally {
    await session.endSession();
  }

  return summary;
}

function readArg(name: string): string | undefined {
  const prefix = `--${name}=`;
  const found = process.argv.find((a) => a.startsWith(prefix));
  return found?.slice(prefix.length);
}

async function main(): Promise<void> {
  const uri = process.env.MONGODB_URI;
  if (!uri) {
    logger.error('MONGODB_URI is not set');
    process.exit(1);
  }

  const householdId = readArg('household');
  const legacyWalletUserId = readArg('legacy-wallet');
  const apply = process.argv.includes('--yes');

  if (!householdId || !legacyWalletUserId) {
    logger.error(
      'Usage: activate-p1-economy.ts --household=<id> --legacy-wallet=<userId> [--yes]',
    );
    process.exit(1);
  }

  await mongoose.connect(uri);
  try {
    if (!apply) {
      logger.warn('DRY RUN — nothing will be written. Re-run with --yes to apply.');
    }
    const summary = await activateP1Economy({ householdId, legacyWalletUserId, apply });
    logger.info(`\n${formatSummary(summary)}`);
    if (summary.alreadyMigrated) {
      logger.warn('This household was already migrated; nothing was written.');
    }
  } finally {
    await mongoose.disconnect();
  }
}

// Only run when invoked directly, so the suite can import the function above.
if (require.main === module) {
  main().catch((err: Error) => {
    logger.error('P1 activation failed', err.message);
    process.exit(1);
  });
}

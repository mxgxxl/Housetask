import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { EconomyLedgerModel } from '../models/EconomyLedger';
import { HouseholdEconomyMigrationModel } from '../models/HouseholdEconomyMigration';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { PetModel } from '../models/Pet';
import { activateP1Economy, formatSummary } from '../scripts/activate-p1-economy';
import {
  isP1Enabled,
  migrationBackedResolver,
  resetP1EnabledResolver,
  setP1EnabledResolver,
  useMigrationBackedFlag,
} from '../services/feature-flag.service';
import { buildTestApp } from './setup';
import {
  TestHousehold,
  TestUser,
  authHeader,
  createTestHousehold,
  createTestUser,
  joinTestHousehold,
} from './helpers';

/**
 * Per-household activation of the P1 economy (TD-066 B11, design §6).
 *
 * This is the commit that makes every earlier one reachable, so the tests are
 * about the two properties an operator has to be able to trust while following
 * a runbook under pressure:
 *
 *  1. A dry run writes NOTHING. It is the only way to look before leaping, and
 *     an operator who cannot trust it will skip it.
 *  2. Running twice is safe. Idempotence is guaranteed twice over, by two
 *     independent indexes, precisely because a script that credits a
 *     household's whole balance is the wrong place for a single point of
 *     failure.
 *
 * They also pin the thing the whole migration promises: nothing of Fase A is
 * destroyed (design §6.5).
 */
let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

afterEach(() => {
  resetP1EnabledResolver();
});

async function setup(): Promise<{ user: TestUser; household: TestHousehold }> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  return { user, household };
}

/** Put coins in the household's Fase A ledger. */
async function fundLegacy(householdId: string, amount: number, refId: string): Promise<void> {
  await EconomyLedgerModel.create({
    householdId: new Types.ObjectId(householdId),
    amount,
    reason: 'task_complete',
    refId,
  });
}

describe('argument validation', () => {
  it('refuses an empty legacyWalletUserId', async () => {
    // The whole point of the manual step: crediting the household's balance to
    // nobody would be a silent, irreversible loss.
    const { household } = await setup();

    await expect(
      activateP1Economy({
        householdId: household.id,
        legacyWalletUserId: '',
        apply: true,
      }),
    ).rejects.toThrow(/legacyWalletUserId is required/);
    await expect(HouseholdEconomyMigrationModel.countDocuments({})).resolves.toBe(0);
  });

  it('refuses a malformed legacyWalletUserId', async () => {
    const { household } = await setup();
    await expect(
      activateP1Economy({
        householdId: household.id,
        legacyWalletUserId: 'not-an-id',
        apply: true,
      }),
    ).rejects.toThrow(/legacyWalletUserId is required/);
  });

  it('refuses a household that does not exist', async () => {
    const user = await createTestUser(app);
    await expect(
      activateP1Economy({
        householdId: new Types.ObjectId().toString(),
        legacyWalletUserId: user.id,
        apply: true,
      }),
    ).rejects.toThrow(/does not exist/);
  });

  it('refuses to credit someone outside the household', async () => {
    // Crediting a stranger would move the household's money out of it
    // entirely, and the mistake would be invisible until someone went looking
    // for coins that were never there.
    const { household } = await setup();
    const stranger = await createTestUser(app);

    await expect(
      activateP1Economy({
        householdId: household.id,
        legacyWalletUserId: stranger.id,
        apply: true,
      }),
    ).rejects.toThrow(/not a member/);
    await expect(HouseholdEconomyMigrationModel.countDocuments({})).resolves.toBe(0);
  });
});

describe('dry run', () => {
  it('writes nothing at all', async () => {
    const { user, household } = await setup();
    await fundLegacy(household.id, 27, 'task-1');

    const summary = await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: false,
    });

    expect(summary.mode).toBe('DRY RUN');
    expect(summary.legacyBalanceSnapshot).toBe(27);
    // It reports what WOULD happen...
    expect(summary.creditWritten).toBe(true);
    // ...and touched nothing.
    await expect(HouseholdEconomyMigrationModel.countDocuments({})).resolves.toBe(0);
    await expect(PersonalCoinLedgerModel.countDocuments({})).resolves.toBe(0);
  });

  it('leaves the flag off', async () => {
    useMigrationBackedFlag();
    const { user, household } = await setup();
    await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: false,
    });

    await expect(isP1Enabled(household.id)).resolves.toBe(false);
  });

  it('produces a pasteable summary', async () => {
    const { user, household } = await setup();
    await fundLegacy(household.id, 27, 'task-1');

    const summary = await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: false,
    });
    const text = formatSummary(summary);

    expect(text).toContain('[DRY RUN]');
    expect(text).toContain('legacy balance:     27');
    expect(text).toContain('already migrated:   false');
  });
});

describe('applying', () => {
  it('records the snapshot, the watermark and the named wallet', async () => {
    const { user, household } = await setup();
    await fundLegacy(household.id, 20, 'task-1');
    await fundLegacy(household.id, 7, 'task-2');

    const summary = await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });

    expect(summary.mode).toBe('APPLIED');
    expect(summary.legacyBalanceSnapshot).toBe(27);
    expect(summary.creditWritten).toBe(true);

    const record = await HouseholdEconomyMigrationModel.findOne({
      householdId: new Types.ObjectId(household.id),
    });
    expect(record?.phase).toBe('active');
    expect(record?.legacyBalanceSnapshot).toBe(27);
    expect(record?.legacyWalletUserId?.toString()).toBe(user.id);
    expect(record?.activatedAt).toBeDefined();
    expect(record?.legacyLedgerWatermark).toBeDefined();
  });

  it('credits the legacy balance exactly once, to the named wallet', async () => {
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);
    await fundLegacy(household.id, 27, 'task-1');

    await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });

    const entries = await PersonalCoinLedgerModel.find({ reason: 'legacy_balance' });
    expect(entries).toHaveLength(1);
    expect(entries[0].amount).toBe(27);
    expect(entries[0].userId.toString()).toBe(user.id);
    // The other member got nothing: the balance was not multiplied by the
    // household's size, which is exactly what naming one wallet prevents.
    await expect(
      PersonalCoinLedgerModel.countDocuments({ userId: new Types.ObjectId(mate.id) }),
    ).resolves.toBe(0);
  });

  it('writes no credit for a household with no balance', async () => {
    const { user, household } = await setup();

    const summary = await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });

    expect(summary.legacyBalanceSnapshot).toBe(0);
    expect(summary.creditWritten).toBe(false);
    await expect(PersonalCoinLedgerModel.countDocuments({})).resolves.toBe(0);
    // The household is still activated — a zero balance is not a reason to
    // stay on Fase A.
    const record = await HouseholdEconomyMigrationModel.findOne({});
    expect(record?.phase).toBe('active');
  });

  it('turns the flag on for that household and no other', async () => {
    useMigrationBackedFlag();
    const { user, household } = await setup();
    const other = await createTestHousehold(app, user, 'Otra casa');

    await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });

    await expect(isP1Enabled(household.id)).resolves.toBe(true);
    await expect(isP1Enabled(other.id)).resolves.toBe(false);
  });
});

describe('idempotence', () => {
  it('does not credit twice when run again', async () => {
    // The property an operator following a runbook has to be able to rely on.
    const { user, household } = await setup();
    await fundLegacy(household.id, 27, 'task-1');

    const first = await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });
    const second = await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });

    expect(first.alreadyMigrated).toBe(false);
    expect(second.alreadyMigrated).toBe(true);
    expect(second.creditWritten).toBe(false);

    await expect(
      PersonalCoinLedgerModel.countDocuments({ reason: 'legacy_balance' }),
    ).resolves.toBe(1);
    await expect(HouseholdEconomyMigrationModel.countDocuments({})).resolves.toBe(1);
  });

  it('reports the ORIGINAL snapshot on a re-run, not a recomputed one', async () => {
    // The Fase A ledger keeps moving after activation — the pet still spends
    // from it — so recomputing would report a number that is no longer the
    // one the migration was based on.
    const { user, household } = await setup();
    await fundLegacy(household.id, 27, 'task-1');
    await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });

    // The household spends 20 on a cosmetic afterwards.
    await EconomyLedgerModel.create({
      householdId: new Types.ObjectId(household.id),
      amount: -20,
      reason: 'cosmetic_buy',
      refId: 'hat',
    });

    const again = await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: false,
    });

    expect(again.legacyBalanceSnapshot).toBe(27);
  });

  it('does not credit twice even if the migration row is removed', async () => {
    // Two independent guarantees, deliberately not one: the ledger's own
    // unique index still refuses a second legacy credit for this household.
    const { user, household } = await setup();
    await fundLegacy(household.id, 27, 'task-1');
    await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });

    await HouseholdEconomyMigrationModel.deleteMany({});

    await expect(
      activateP1Economy({
        householdId: household.id,
        legacyWalletUserId: user.id,
        apply: true,
      }),
    ).rejects.toThrow(/duplicate key/i);

    await expect(
      PersonalCoinLedgerModel.countDocuments({ reason: 'legacy_balance' }),
    ).resolves.toBe(1);
  });
});

describe('nothing of Fase A is destroyed (design §6.5)', () => {
  it('leaves EconomyLedger and the household balance untouched', async () => {
    const { user, household } = await setup();
    await fundLegacy(household.id, 20, 'task-1');
    await fundLegacy(household.id, 7, 'task-2');

    await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });

    await expect(
      EconomyLedgerModel.countDocuments({ householdId: new Types.ObjectId(household.id) }),
    ).resolves.toBe(2);

    // And the Fase A endpoint still answers its own shape with its own number.
    const res = await request(app)
      .get(`/api/households/${household.id}/economy`)
      .set(authHeader(user.accessToken));
    expect(res.status).toBe(200);
    expect(res.body.data.balance).toBe(27);
  });

  it('leaves the pet and its cosmetics alone', async () => {
    const { user, household } = await setup();
    await PetModel.create({
      householdId: new Types.ObjectId(household.id),
      species: 'cat',
      name: 'Michi',
      adoptedBy: new Types.ObjectId(user.id),
      adoptedAt: new Date(),
      cosmetics: ['hat'],
      activeCosmetic: 'hat',
    });

    await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });

    const pet = await PetModel.findOne({ householdId: new Types.ObjectId(household.id) });
    expect(pet?.cosmetics).toEqual(['hat']);
    expect(pet?.activeCosmetic).toBe('hat');
  });
});

describe('rolling back', () => {
  it('returns the household to Fase A without losing any P1 row', async () => {
    useMigrationBackedFlag();
    const { user, household } = await setup();
    await fundLegacy(household.id, 27, 'task-1');
    await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });
    await expect(isP1Enabled(household.id)).resolves.toBe(true);

    await HouseholdEconomyMigrationModel.updateOne(
      { householdId: new Types.ObjectId(household.id) },
      { $set: { phase: 'rolled_back', rolledBackAt: new Date() } },
    );

    await expect(isP1Enabled(household.id)).resolves.toBe(false);
    // Nothing was deleted: the credit is still on disk for reconciliation,
    // and re-activating restores the household with its history intact.
    await expect(
      PersonalCoinLedgerModel.countDocuments({ reason: 'legacy_balance' }),
    ).resolves.toBe(1);

    await HouseholdEconomyMigrationModel.updateOne(
      { householdId: new Types.ObjectId(household.id) },
      { $set: { phase: 'active' } },
    );
    await expect(isP1Enabled(household.id)).resolves.toBe(true);
  });

  it('is overridden instantly by the kill switch, without a restart', async () => {
    useMigrationBackedFlag();
    const original = process.env.P1_ECONOMY_KILL_SWITCH;
    const { user, household } = await setup();
    await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });
    await expect(isP1Enabled(household.id)).resolves.toBe(true);

    process.env.P1_ECONOMY_KILL_SWITCH = 'true';
    await expect(isP1Enabled(household.id)).resolves.toBe(false);

    if (original === undefined) {
      delete process.env.P1_ECONOMY_KILL_SWITCH;
    } else {
      process.env.P1_ECONOMY_KILL_SWITCH = original;
    }
  });
});

describe('the migration-backed resolver', () => {
  it('answers false for a household with no migration row', async () => {
    // The shipped state of every household in production today.
    const { household } = await setup();
    await expect(migrationBackedResolver(household.id)).resolves.toBe(false);
  });

  it('answers false for every phase other than active', async () => {
    const { user, household } = await setup();
    for (const phase of ['pending', 'snapshotted', 'rolled_back'] as const) {
      await HouseholdEconomyMigrationModel.deleteMany({});
      await HouseholdEconomyMigrationModel.create({
        householdId: new Types.ObjectId(household.id),
        phase,
        legacyWalletUserId: new Types.ObjectId(user.id),
      });
      await expect(migrationBackedResolver(household.id)).resolves.toBe(false);
    }
  });

  it('still fails closed if the lookup throws', async () => {
    setP1EnabledResolver(() => Promise.reject(new Error('mongo down')));
    await expect(isP1Enabled(new Types.ObjectId().toString())).resolves.toBe(false);
  });
});

describe('a completion in an activated household actually uses P1', () => {
  it('produces a receipt where before it produced none', async () => {
    useMigrationBackedFlag();
    const { user, household } = await setup();

    const created = await request(app)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Fregar' });

    // Before activation: Fase A, no receipt.
    const before = await request(app)
      .post(`/api/households/${household.id}/tasks/${created.body.data.id}/completions`)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-before')
      .send({ timeZone: 'UTC' });
    expect(before.body.data.reward).toBeNull();

    await activateP1Economy({
      householdId: household.id,
      legacyWalletUserId: user.id,
      apply: true,
    });

    const second = await request(app)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .send({ title: 'Barrer' });
    const after = await request(app)
      .post(`/api/households/${household.id}/tasks/${second.body.data.id}/completions`)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'op-after')
      .send({ timeZone: 'UTC' });

    expect(after.body.data.reward).not.toBeNull();
    expect(after.body.data.receiptId).toEqual(expect.any(String));
  });
});

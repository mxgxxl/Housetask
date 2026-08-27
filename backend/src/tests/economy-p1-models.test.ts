import { Types } from 'mongoose';

import { HouseholdEconomyMigrationModel } from '../models/HouseholdEconomyMigration';
import { HouseholdProgressModel } from '../models/HouseholdProgress';
import { HouseholdXpLedgerModel } from '../models/HouseholdXpLedger';
import { JointSavingsGoalModel } from '../models/JointSavingsGoal';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { PersonalStreakModel } from '../models/PersonalStreak';
import { PersonalXpLedgerModel } from '../models/PersonalXpLedger';
import { RewardGrantModel } from '../models/RewardGrant';
import { SavingsContributionModel } from '../models/SavingsContribution';
import { StreakDayModel } from '../models/StreakDay';
import { UserProgressModel } from '../models/UserProgress';
import { WeeklyPersonalBudgetModel } from '../models/WeeklyPersonalBudget';
import {
  HOUSEHOLD_LEVEL_CURVE_FACTOR,
  MAX_ICE_RESERVE,
  PERSONAL_LEVEL_CURVE_FACTOR,
  WEEKLY_CAP_COINS,
  levelForXp,
} from '../config/economy-p1';

/**
 * Schema and index guarantees of the twelve P1 economy collections (TD-066 B2).
 *
 * Nothing reads or writes these yet — B3 onwards does, behind a flag that is
 * off — so these tests fix the properties the later stops will lean on before
 * anything depends on them. Same approach as
 * `household-member-model.test.ts` took for TD-001, and for the same reason:
 * an index that turns out not to be unique is discovered here, not by two
 * people getting paid twice for one task.
 *
 * The unique indexes are not a performance detail. They ARE the anti-double
 * -reward mechanism (TD-066-DESIGN §9 risk 1) and the concurrency guard for
 * every racing write in the design, so each one is asserted by provoking the
 * collision rather than by reading the schema back.
 */
describe('P1 economy models', () => {
  // Indexes are created once; setup.ts's afterEach only deletes documents.
  beforeAll(async () => {
    await Promise.all([
      PersonalCoinLedgerModel.syncIndexes(),
      PersonalXpLedgerModel.syncIndexes(),
      HouseholdXpLedgerModel.syncIndexes(),
      UserProgressModel.syncIndexes(),
      HouseholdProgressModel.syncIndexes(),
      WeeklyPersonalBudgetModel.syncIndexes(),
      RewardGrantModel.syncIndexes(),
      PersonalStreakModel.syncIndexes(),
      StreakDayModel.syncIndexes(),
      JointSavingsGoalModel.syncIndexes(),
      SavingsContributionModel.syncIndexes(),
      HouseholdEconomyMigrationModel.syncIndexes(),
    ]);
  });

  const userId = new Types.ObjectId();
  const otherUserId = new Types.ObjectId();
  const householdId = new Types.ObjectId();
  const otherHouseholdId = new Types.ObjectId();
  const taskId = new Types.ObjectId();

  describe('PersonalCoinLedger', () => {
    const entry = {
      userId,
      householdId,
      amount: 5,
      reason: 'task_first_completion' as const,
      refType: 'task' as const,
      refId: taskId.toString(),
      effectiveAt: new Date('2026-08-26T10:00:00Z'),
    };

    it('rejects a duplicate (userId, reason, refType, refId)', async () => {
      await PersonalCoinLedgerModel.create(entry);
      // A retried completion, a replayed offline operation, or two devices
      // racing: the second write must be a duplicate-key error, not a payout.
      await expect(PersonalCoinLedgerModel.create(entry)).rejects.toThrow(/duplicate key/i);
    });

    it('lets two members earn from the same task', async () => {
      // The wallet is personal (PDR-012), so the index is keyed on the user.
      // Two people completing tasks that share a refId must not collide.
      await PersonalCoinLedgerModel.create(entry);
      await expect(
        PersonalCoinLedgerModel.create({ ...entry, userId: otherUserId }),
      ).resolves.toBeDefined();
    });

    it('distinguishes entries that differ only by reason or refType', async () => {
      await PersonalCoinLedgerModel.create(entry);
      await expect(
        PersonalCoinLedgerModel.create({ ...entry, reason: 'legacy_balance', amount: 100 }),
      ).resolves.toBeDefined();
      await expect(
        PersonalCoinLedgerModel.create({ ...entry, refType: 'ice_purchase' }),
      ).resolves.toBeDefined();
    });

    it('requires refType and refId (R7)', async () => {
      // Fase A's EconomyLedger left refId optional, which makes two entries
      // sharing a reason and no refId collide — capping such grants at one
      // per household forever. P1 has no missing-reference case at all.
      const { refType, refId, ...base } = entry;
      await expect(PersonalCoinLedgerModel.create(base)).rejects.toThrow(/refType/);
      await expect(PersonalCoinLedgerModel.create({ ...base, refType })).rejects.toThrow(/refId/);
      // ...and the same entry with both present is accepted, so the two
      // rejections above are about the missing fields and nothing else.
      await expect(
        PersonalCoinLedgerModel.create({ ...base, refType, refId }),
      ).resolves.toBeDefined();
    });

    it('accepts a negative amount, because a spend is a ledger entry too', async () => {
      const spend = await PersonalCoinLedgerModel.create({
        ...entry,
        amount: -20,
        reason: 'ice_purchase',
        refType: 'ice_purchase',
        refId: 'op-ice-1',
      });
      expect(spend.amount).toBe(-20);
    });

    it('leaves weekKey unset for a movement no weekly cap governs', async () => {
      const credit = await PersonalCoinLedgerModel.create({
        ...entry,
        reason: 'legacy_balance',
        refType: 'legacy_migration',
        refId: new Types.ObjectId().toString(),
      });
      expect(credit.weekKey).toBeUndefined();
    });
  });

  describe('PersonalXpLedger', () => {
    const entry = {
      userId,
      amount: 10,
      reason: 'task_first_completion' as const,
      refType: 'task' as const,
      refId: taskId.toString(),
    };

    it('rejects a duplicate (userId, reason, refType, refId)', async () => {
      await PersonalXpLedgerModel.create(entry);
      await expect(PersonalXpLedgerModel.create(entry)).rejects.toThrow(/duplicate key/i);
    });

    it('requires refType and refId (R7)', async () => {
      const { refType, ...base } = entry;
      await expect(PersonalXpLedgerModel.create(base)).rejects.toThrow(/refType/);
      await expect(PersonalXpLedgerModel.create({ ...base, refType })).resolves.toBeDefined();
    });

    it('carries no householdId, so XP cannot be scoped by household (PDR-017)', () => {
      // "Tu nivel viaja contigo": a household reference here would invite a
      // future query to scope XP by it, which is the portability PDR-017
      // exists to protect.
      expect(PersonalXpLedgerModel.schema.path('householdId')).toBeUndefined();
    });
  });

  describe('HouseholdXpLedger', () => {
    const entry = {
      householdId,
      amount: 10,
      reason: 'task_first_completion' as const,
      refType: 'task' as const,
      refId: taskId.toString(),
    };

    it('rejects a duplicate (householdId, reason, refType, refId)', async () => {
      await HouseholdXpLedgerModel.create(entry);
      await expect(HouseholdXpLedgerModel.create(entry)).rejects.toThrow(/duplicate key/i);
    });

    it('is keyed on the household, not on who completed the task', async () => {
      // One task pays household XP once regardless of the completer, and a
      // different household with a same-named ref must not collide.
      await HouseholdXpLedgerModel.create(entry);
      await expect(
        HouseholdXpLedgerModel.create({ ...entry, householdId: otherHouseholdId }),
      ).resolves.toBeDefined();
    });
  });

  describe('UserProgress', () => {
    it('allows only one progress document per user', async () => {
      await UserProgressModel.create({ userId, xp: 0, level: 1 });
      await expect(UserProgressModel.create({ userId, xp: 0, level: 1 })).rejects.toThrow(
        /duplicate key/i,
      );
    });

    it('starts at level 1 with zero XP', async () => {
      const progress = await UserProgressModel.create({ userId });
      expect(progress.xp).toBe(0);
      expect(progress.level).toBe(1);
    });

    it('refuses a level below 1 or negative XP', async () => {
      await expect(UserProgressModel.create({ userId, level: 0 })).rejects.toThrow(/level/);
      await expect(UserProgressModel.create({ userId: otherUserId, xp: -1 })).rejects.toThrow(
        /xp/,
      );
    });
  });

  describe('HouseholdProgress', () => {
    it('allows only one progress document per household', async () => {
      await HouseholdProgressModel.create({ householdId });
      await expect(HouseholdProgressModel.create({ householdId })).rejects.toThrow(
        /duplicate key/i,
      );
    });
  });

  describe('projections are reconstructible from their ledgers', () => {
    /**
     * The property that makes keeping a projection safe at all
     * (TD-066-DESIGN §3): `UserProgress`/`HouseholdProgress` accelerate reads,
     * but the ledger is the authority and can always rebuild them. Asserted
     * directly rather than assumed, because the day the two disagree is the
     * day this test is the difference between "recompute it" and "the
     * balance is whatever the counter says".
     */
    it('rebuilds personal xp and level by summing PersonalXpLedger', async () => {
      const amounts = [10, 10, 10, 25, 45];
      await PersonalXpLedgerModel.create(
        amounts.map((amount, i) => ({
          userId,
          amount,
          reason: 'task_first_completion' as const,
          refType: 'task' as const,
          refId: `task-${i}`,
        })),
      );

      const [aggregated] = await PersonalXpLedgerModel.aggregate<{ total: number }>([
        { $match: { userId } },
        { $group: { _id: null, total: { $sum: '$amount' } } },
      ]);

      const expectedXp = amounts.reduce((a, b) => a + b, 0);
      expect(aggregated.total).toBe(expectedXp);

      // What the projection would hold, derived the same way the writer will.
      const projection = await UserProgressModel.create({
        userId,
        xp: aggregated.total,
        level: levelForXp(aggregated.total, PERSONAL_LEVEL_CURVE_FACTOR),
      });
      expect(projection.xp).toBe(expectedXp);
      expect(projection.level).toBe(levelForXp(expectedXp, PERSONAL_LEVEL_CURVE_FACTOR));
    });

    it('rebuilds household xp and level by summing HouseholdXpLedger', async () => {
      const amounts = [10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10];
      await HouseholdXpLedgerModel.create(
        amounts.map((amount, i) => ({
          householdId,
          amount,
          reason: 'task_first_completion' as const,
          refType: 'task' as const,
          refId: `task-${i}`,
        })),
      );

      const [aggregated] = await HouseholdXpLedgerModel.aggregate<{ total: number }>([
        { $match: { householdId } },
        { $group: { _id: null, total: { $sum: '$amount' } } },
      ]);

      expect(aggregated.total).toBe(200);
      // 200 XP on the household curve (factor 100) is exactly level 2.
      expect(levelForXp(aggregated.total, HOUSEHOLD_LEVEL_CURVE_FACTOR)).toBe(2);
    });

    it('rebuilds a personal wallet balance by summing PersonalCoinLedger', async () => {
      // Earn 100, spend 20 on an ice, contribute 30 to a goal: 50 left.
      await PersonalCoinLedgerModel.create([
        {
          userId,
          householdId,
          amount: 100,
          reason: 'legacy_balance' as const,
          refType: 'legacy_migration' as const,
          refId: 'migration-1',
          effectiveAt: new Date(),
        },
        {
          userId,
          householdId,
          amount: -20,
          reason: 'ice_purchase' as const,
          refType: 'ice_purchase' as const,
          refId: 'op-ice-1',
          effectiveAt: new Date(),
        },
        {
          userId,
          householdId,
          amount: -30,
          reason: 'savings_contribution' as const,
          refType: 'savings_contribution' as const,
          refId: 'contribution-1',
          effectiveAt: new Date(),
        },
      ]);

      const [balance] = await PersonalCoinLedgerModel.aggregate<{ total: number }>([
        { $match: { userId } },
        { $group: { _id: null, total: { $sum: '$amount' } } },
      ]);
      expect(balance.total).toBe(50);
    });
  });

  describe('WeeklyPersonalBudget', () => {
    const budget = {
      userId,
      householdId,
      weekKey: '2026-W35',
      periodTimeZone: 'Europe/Madrid',
      weeklyCap: WEEKLY_CAP_COINS,
    };

    it('rejects a duplicate (userId, householdId, weekKey)', async () => {
      await WeeklyPersonalBudgetModel.create(budget);
      // Two first-completions racing at the start of a fresh week both try to
      // create it; exactly one may win, or the cap is granted twice.
      await expect(WeeklyPersonalBudgetModel.create(budget)).rejects.toThrow(/duplicate key/i);
    });

    it('gives the same member a separate budget per household', async () => {
      // The wallet is shared across households; the CAP is not, or one
      // household's activity would consume the other's allowance.
      await WeeklyPersonalBudgetModel.create(budget);
      await expect(
        WeeklyPersonalBudgetModel.create({ ...budget, householdId: otherHouseholdId }),
      ).resolves.toBeDefined();
    });

    it('stores allocations without their own _id and defaults to automatic', async () => {
      const created = await WeeklyPersonalBudgetModel.create({
        ...budget,
        allocations: [
          { allocationKey: 'rule:dishes', expectedFrequency: 7, coinAmount: 4 },
          {
            allocationKey: 'common:unassigned',
            expectedFrequency: 5,
            coinAmount: 8,
            mode: 'manual' as const,
          },
        ],
      });

      expect(created.allocations).toHaveLength(2);
      expect(created.allocations[0].mode).toBe('automatic');
      expect(created.allocations[1].mode).toBe('manual');
      // A recurring series makes a new Task per occurrence, so a plan line
      // keyed on a document id would expire weekly; allocationKey is what
      // survives, and the common tranche has no document to point at at all.
      expect(created.allocations[1].taskOrRuleId).toBeUndefined();
      expect((created.allocations[0] as unknown as { _id?: unknown })._id).toBeUndefined();
    });

    it('starts released and granted at zero and planVersion at one', async () => {
      const created = await WeeklyPersonalBudgetModel.create(budget);
      expect(created.releasedCoins).toBe(0);
      expect(created.grantedCoins).toBe(0);
      expect(created.planVersion).toBe(1);
    });

    it('requires the timezone snapshot', async () => {
      // It is what makes a settled week reproducible after the member moves,
      // so a budget without it must not be storable at all.
      const { periodTimeZone, ...base } = budget;
      await expect(WeeklyPersonalBudgetModel.create(base)).rejects.toThrow(/periodTimeZone/);
      await expect(
        WeeklyPersonalBudgetModel.create({ ...base, periodTimeZone }),
      ).resolves.toBeDefined();
    });
  });

  describe('RewardGrant', () => {
    const grant = {
      householdId,
      userId,
      taskId,
      kind: 'task_first_completion' as const,
      completionOperationId: 'op-1',
      effectiveAt: new Date('2026-08-26T10:00:00Z'),
      effectiveDayKey: '2026-08-26',
      coinAwarded: 5,
      personalXpAwarded: 10,
      householdXpAwarded: 10,
    };

    it('rejects a second reward for the same (householdId, taskId, kind)', async () => {
      await RewardGrantModel.create(grant);
      // The keystone guarantee: whichever of the three completion paths
      // arrives second finds the claim taken (TD-066-DESIGN §9 risk 1).
      await expect(
        RewardGrantModel.create({ ...grant, completionOperationId: 'op-2' }),
      ).rejects.toThrow(/duplicate key/i);
    });

    it('rejects a replayed completionOperationId within a household', async () => {
      await RewardGrantModel.create(grant);
      await expect(
        RewardGrantModel.create({ ...grant, taskId: new Types.ObjectId() }),
      ).rejects.toThrow(/duplicate key/i);
    });

    it('allows the same operation id in a different household', async () => {
      // The id comes from an uncoordinated device: a cross-household
      // collision must not be an error, while a replay into the same
      // household must be.
      await RewardGrantModel.create(grant);
      await expect(
        RewardGrantModel.create({ ...grant, householdId: otherHouseholdId }),
      ).resolves.toBeDefined();
    });

    it('records a zero payout distinctly from an absent one', async () => {
      // A completion on an exhausted budget pays 0 coins and still grants XP.
      const created = await RewardGrantModel.create({
        ...grant,
        coinAwarded: 0,
        personalXpAwarded: 10,
        householdXpAwarded: 10,
      });
      expect(created.coinAwarded).toBe(0);
      expect(created.personalXpAwarded).toBe(10);
      expect(created.status).toBe('granted');
    });

    it('rejects a negative award', async () => {
      await expect(
        RewardGrantModel.create({ ...grant, coinAwarded: -1 }),
      ).rejects.toThrow(/coinAwarded/);
    });
  });

  describe('PersonalStreak', () => {
    it('allows only one account-scoped streak per user', async () => {
      await PersonalStreakModel.create({ userId, scope: 'account' });
      await expect(PersonalStreakModel.create({ userId, scope: 'account' })).rejects.toThrow(
        /duplicate key/i,
      );
    });

    it('defaults to account scope with a null scopeId (owner decision P4)', async () => {
      const streak = await PersonalStreakModel.create({ userId });
      expect(streak.scope).toBe('account');
      expect(streak.scopeId).toBeNull();
      expect(streak.currentCount).toBe(0);
      expect(streak.iceReserve).toBe(0);
    });

    it('leaves room for a household-scoped streak without a migration', async () => {
      await PersonalStreakModel.create({ userId, scope: 'account' });
      await expect(
        PersonalStreakModel.create({ userId, scope: 'household', scopeId: householdId }),
      ).resolves.toBeDefined();
    });

    it('bounds iceReserve to [0, MAX_ICE_RESERVE] in the schema', async () => {
      // PDR-019's cap is a correctness rule, not just a product rule:
      // approved decision 5 discards a late refund when the reserve is full,
      // so an off-by-one in a future refund path must fail the write rather
      // than quietly inflate everyone's protection.
      expect(MAX_ICE_RESERVE).toBe(2);
      await expect(
        PersonalStreakModel.create({ userId, iceReserve: MAX_ICE_RESERVE + 1 }),
      ).rejects.toThrow(/iceReserve/);
      await expect(
        PersonalStreakModel.create({ userId: otherUserId, iceReserve: -1 }),
      ).rejects.toThrow(/iceReserve/);
    });

    it('accepts the reserve at exactly the cap', async () => {
      const streak = await PersonalStreakModel.create({ userId, iceReserve: MAX_ICE_RESERVE });
      expect(streak.iceReserve).toBe(2);
    });

    it('leaves lastClosedDayKey unset until a day is closed', async () => {
      const streak = await PersonalStreakModel.create({ userId });
      expect(streak.lastClosedDayKey).toBeUndefined();
    });
  });

  describe('StreakDay', () => {
    const streakId = new Types.ObjectId();

    it('rejects a duplicate (streakId, dayKey)', async () => {
      await StreakDayModel.create({ streakId, dayKey: '2026-08-26' });
      // Two morning requests both noticing yesterday is unresolved must not
      // each consume an ice for it.
      await expect(StreakDayModel.create({ streakId, dayKey: '2026-08-26' })).rejects.toThrow(
        /duplicate key/i,
      );
    });

    it('opens with no activity and no verdict', async () => {
      const day = await StreakDayModel.create({ streakId, dayKey: '2026-08-26' });
      expect(day.closeState).toBe('open');
      expect(day.usefulActivityCount).toBe(0);
      expect(day.iceConsumed).toBe(false);
      expect(day.iceRefunded).toBe(false);
    });

    it('keeps consumed-and-refunded as a real state, not an erasure', async () => {
      // The day WAS covered; clearing iceConsumed on refund would lose the
      // audit trail for a refund that approved decision 5 makes conditional.
      const day = await StreakDayModel.create({
        streakId,
        dayKey: '2026-08-25',
        iceConsumed: true,
        iceRefunded: true,
        usefulActivityCount: 1,
        closeState: 'active',
      });
      expect(day.iceConsumed).toBe(true);
      expect(day.iceRefunded).toBe(true);
    });

    it('rejects a close state outside the union', async () => {
      await expect(
        StreakDayModel.create({ streakId, dayKey: '2026-08-24', closeState: 'frozen' }),
      ).rejects.toThrow(/closeState/);
    });
  });

  describe('JointSavingsGoal', () => {
    const goal = {
      householdId,
      itemType: 'cosmetic',
      itemId: 'dragon-skin',
      targetCoins: 100,
      createdBy: userId,
    };

    it('allows only one ACTIVE goal per household (PDR-018)', async () => {
      await JointSavingsGoalModel.create(goal);
      await expect(JointSavingsGoalModel.create(goal)).rejects.toThrow(/duplicate key/i);
    });

    it('still allows a new goal after the previous one was cancelled', async () => {
      // The whole reason the index is PARTIAL. A plain unique index on
      // householdId would forbid a second cancelled goal too, so a household
      // could never save for anything again after abandoning one attempt.
      await JointSavingsGoalModel.create({
        ...goal,
        status: 'cancelled',
        cancelledAt: new Date(),
      });
      await expect(JointSavingsGoalModel.create(goal)).resolves.toBeDefined();
    });

    it('allows any number of finished goals in history', async () => {
      await JointSavingsGoalModel.create({ ...goal, status: 'cancelled' });
      await JointSavingsGoalModel.create({ ...goal, status: 'cancelled' });
      await JointSavingsGoalModel.create({ ...goal, status: 'unlocked', unlockedAt: new Date() });
      await expect(
        JointSavingsGoalModel.countDocuments({ householdId }),
      ).resolves.toBe(3);
    });

    it('does not constrain a different household', async () => {
      await JointSavingsGoalModel.create(goal);
      await expect(
        JointSavingsGoalModel.create({ ...goal, householdId: otherHouseholdId }),
      ).resolves.toBeDefined();
    });

    it('starts active with nothing contributed', async () => {
      const created = await JointSavingsGoalModel.create(goal);
      expect(created.status).toBe('active');
      expect(created.contributedCoins).toBe(0);
      expect(created.unlockedAt).toBeUndefined();
    });

    it('refuses a target of zero coins', async () => {
      await expect(
        JointSavingsGoalModel.create({ ...goal, targetCoins: 0 }),
      ).rejects.toThrow(/targetCoins/);
    });
  });

  describe('SavingsContribution', () => {
    const goalId = new Types.ObjectId();
    const contribution = {
      goalId,
      householdId,
      userId,
      amount: 40,
      operationId: 'contrib-op-1',
    };

    it('rejects a duplicate (goalId, operationId)', async () => {
      await SavingsContributionModel.create(contribution);
      // A contribution is a real debit; paying twice for one tap is the
      // failure that matters most here.
      await expect(SavingsContributionModel.create(contribution)).rejects.toThrow(
        /duplicate key/i,
      );
    });

    it('allows the same operation id against a different goal', async () => {
      await SavingsContributionModel.create(contribution);
      await expect(
        SavingsContributionModel.create({ ...contribution, goalId: new Types.ObjectId() }),
      ).resolves.toBeDefined();
    });

    it('starts active, with the amount positive and no refund mark', async () => {
      const created = await SavingsContributionModel.create(contribution);
      expect(created.status).toBe('active');
      expect(created.amount).toBe(40);
      expect(created.refundedAt).toBeUndefined();
    });

    it('refuses a zero or negative contribution', async () => {
      await expect(
        SavingsContributionModel.create({ ...contribution, amount: 0 }),
      ).rejects.toThrow(/amount/);
    });

    it('keeps each member attributable so a departure refunds only their own', async () => {
      await SavingsContributionModel.create(contribution);
      await SavingsContributionModel.create({
        ...contribution,
        userId: otherUserId,
        amount: 28,
        operationId: 'contrib-op-2',
      });

      const mine = await SavingsContributionModel.find({ goalId, userId }).lean();
      expect(mine).toHaveLength(1);
      expect(mine[0].amount).toBe(40);
    });
  });

  describe('HouseholdEconomyMigration', () => {
    it('allows only one migration record per household', async () => {
      await HouseholdEconomyMigrationModel.create({ householdId });
      await expect(HouseholdEconomyMigrationModel.create({ householdId })).rejects.toThrow(
        /duplicate key/i,
      );
    });

    it('starts pending, with nothing measured and P1 off', async () => {
      // There is no implicit progression: a household is migrated because
      // someone ran the script, never as a side effect.
      const record = await HouseholdEconomyMigrationModel.create({ householdId });
      expect(record.phase).toBe('pending');
      expect(record.legacyBalanceSnapshot).toBeUndefined();
      expect(record.legacyWalletUserId).toBeUndefined();
      expect(record.activatedAt).toBeUndefined();
    });

    it('records the snapshot, the watermark and the named legacy wallet', async () => {
      // The Fase A ledger has no userId, so crediting its balance requires
      // naming a person. Recording who turns an irreversible guess into an
      // auditable decision (§6.3).
      const watermark = new Date('2026-08-26T09:00:00Z');
      const record = await HouseholdEconomyMigrationModel.create({
        householdId,
        phase: 'snapshotted',
        legacyBalanceSnapshot: 137,
        legacyLedgerWatermark: watermark,
        legacyWalletUserId: userId,
      });

      expect(record.legacyBalanceSnapshot).toBe(137);
      expect(record.legacyLedgerWatermark?.toISOString()).toBe(watermark.toISOString());
      expect(record.legacyWalletUserId?.toString()).toBe(userId.toString());
    });

    it('rejects a phase outside the union', async () => {
      await expect(
        HouseholdEconomyMigrationModel.create({ householdId, phase: 'halfway' }),
      ).rejects.toThrow(/phase/);
    });

    it('supports a rollback that destroys nothing', async () => {
      const record = await HouseholdEconomyMigrationModel.create({
        householdId,
        phase: 'active',
        activatedAt: new Date(),
      });
      record.phase = 'rolled_back';
      record.rolledBackAt = new Date();
      await expect(record.save()).resolves.toBeDefined();
    });
  });
});

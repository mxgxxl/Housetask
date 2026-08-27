import { Types } from 'mongoose';

import { HouseholdMemberModel } from '../models/HouseholdMember';
import { HouseholdProgressModel } from '../models/HouseholdProgress';
import { JointSavingsGoalModel } from '../models/JointSavingsGoal';
import { PersonalCoinLedgerModel } from '../models/PersonalCoinLedger';
import { PersonalStreakModel } from '../models/PersonalStreak';
import { SavingsContributionModel } from '../models/SavingsContribution';
import { UserModel } from '../models/User';
import { UserProgressModel } from '../models/UserProgress';
import { WeeklyPersonalBudgetModel } from '../models/WeeklyPersonalBudget';
import {
  HOUSEHOLD_LEVEL_CURVE_FACTOR,
  PERSONAL_LEVEL_CURVE_FACTOR,
  STREAK_ICE_MILESTONES,
  WEEKLY_CAP_COINS,
  levelForXp,
  xpRequiredForLevel,
} from '../config/economy-p1';
import {
  availableCoins,
  dayIndexIn,
  releasedOnDay,
  releasedThroughDay,
  resolveTimeZone,
  weekKey,
} from '../utils/economy-period';
import { isP1Enabled } from './feature-flag.service';

/**
 * The P1 read side (TD-066 B6, design §5).
 *
 * Two rules shape everything here.
 *
 * FIRST: with the flag off — every household today — these endpoints answer a
 * complete, zeroed structure rather than 404 or an error. A client that ships
 * before its household is migrated must render an empty wallet, not a crash
 * or an error state; `enabled: false` is what tells it to hide the UI rather
 * than to show zeros as if they were real.
 *
 * SECOND: the personal endpoint is the ONLY place a member's money appears.
 * The household endpoint deliberately exposes shared progress and nothing
 * else — see `getHouseholdEconomy` for exactly where that line is drawn and
 * why.
 */

/** Level plus how far into it, for either XP track. */
export interface ProgressView {
  xp: number;
  level: number;
  /** XP accumulated since reaching `level`. */
  xpIntoLevel: number;
  /** XP the whole of `level` is worth, i.e. what reaching `level + 1` costs. */
  xpForNextLevel: number;
  /** XP still needed to reach `level + 1`. */
  xpToNextLevel: number;
}

export interface WalletView {
  /** All-time personal balance: `sum(PersonalCoinLedger.amount)`. */
  balance: number;
  /** Coins today's allocation released on its own; 0 on Sunday (PDR-013). */
  dailyReleased: number;
  /** Coins still claimable this week — today's release plus what is unspent. */
  remaining: number;
}

export interface StreakView {
  current: number;
  longest: number;
  iceReserve: number;
  /** Which of PDR-019's 7/14/30/50/100 milestones this streak has passed. */
  iceMilestonesReached: number[];
}

export interface BudgetAllocationView {
  allocationKey: string;
  taskOrRuleId: string | null;
  expectedFrequency: number;
  coinAmount: number;
  mode: 'automatic' | 'manual';
}

export interface WeeklyBudgetView {
  weekKey: string;
  periodTimeZone: string;
  weeklyCap: number;
  releasedCoins: number;
  grantedCoins: number;
  planVersion: number;
  allocations: BudgetAllocationView[];
}

export interface PersonalEconomyView {
  enabled: boolean;
  wallet: WalletView;
  personalProgress: ProgressView;
  streak: StreakView;
  weeklyBudget: WeeklyBudgetView;
}

/** Compute level and the distance to the next one from a raw XP total. */
export function toProgressView(xp: number, factor: number): ProgressView {
  const level = levelForXp(xp, factor);
  const floor = xpRequiredForLevel(level, factor);
  const ceiling = xpRequiredForLevel(level + 1, factor);
  return {
    xp,
    level,
    xpIntoLevel: xp - floor,
    xpForNextLevel: ceiling - floor,
    xpToNextLevel: ceiling - xp,
  };
}

function emptyProgress(factor: number): ProgressView {
  return toProgressView(0, factor);
}

/**
 * The zeroed personal view, used when P1 is off.
 *
 * Built from the same helpers as the populated one rather than hand-written
 * zeroes, so the two can never drift into different shapes — the client
 * parses one structure, not two.
 */
function emptyPersonalView(timeZone: string, at: Date): PersonalEconomyView {
  return {
    enabled: false,
    wallet: { balance: 0, dailyReleased: 0, remaining: 0 },
    personalProgress: emptyProgress(PERSONAL_LEVEL_CURVE_FACTOR),
    streak: { current: 0, longest: 0, iceReserve: 0, iceMilestonesReached: [] },
    weeklyBudget: {
      weekKey: weekKey(at, timeZone),
      periodTimeZone: timeZone,
      weeklyCap: 0,
      releasedCoins: 0,
      grantedCoins: 0,
      planVersion: 0,
      allocations: [],
    },
  };
}

export interface ReadOptions {
  /**
   * The member's IANA zone. Same provenance problem as the write path: no
   * schema persists it yet, so it arrives per request (`?timeZone=`) and
   * falls back to UTC. When a budget row already exists, ITS snapshotted zone
   * wins — a device that changed zone mid-week must not re-slice a week that
   * is already being settled.
   */
  timeZone?: string;
  /** Injected so tests can pin a day; production always passes `now`. */
  at?: Date;
}

/**
 * Everything a member needs to render their own economy.
 *
 * Reads the wallet balance by summing the ledger rather than trusting a
 * counter, exactly as `getBalance` does for Fase A: the ledger is the source
 * of truth (TD-066-DESIGN §3), and a balance that can drift is the one bug
 * users never forgive.
 */
export async function getPersonalEconomy(
  householdId: string,
  userId: string,
  options: ReadOptions = {},
): Promise<PersonalEconomyView> {
  const at = options.at ?? new Date();
  const requestedZone = resolveTimeZone(options.timeZone);

  if (!(await isP1Enabled(householdId))) {
    return emptyPersonalView(requestedZone, at);
  }

  const userObjectId = new Types.ObjectId(userId);
  const provisionalWeek = weekKey(at, requestedZone);

  const [balanceRow, progress, streak, budget] = await Promise.all([
    PersonalCoinLedgerModel.aggregate<{ total: number }>([
      // Deliberately NOT scoped by household: the wallet is personal and
      // portable (PDR-012), so a member of two households has one balance.
      { $match: { userId: userObjectId } },
      { $group: { _id: null, total: { $sum: '$amount' } } },
    ]),
    UserProgressModel.findOne({ userId: userObjectId }).lean(),
    PersonalStreakModel.findOne({ userId: userObjectId, scope: 'account' }).lean(),
    WeeklyPersonalBudgetModel.findOne({
      userId: userObjectId,
      householdId: new Types.ObjectId(householdId),
      weekKey: provisionalWeek,
    }).lean(),
  ]);

  const effectiveZone = budget?.periodTimeZone ?? requestedZone;
  const dayIndex = dayIndexIn(at, effectiveZone);

  // Before the week's first completion there is no budget row yet, so the
  // figures are computed from the standing cap. Showing "33 available today"
  // before you have completed anything is the point of UX-P1-SPEC §4's
  // "línea de hoy" — answering 0 until the first task would invert its
  // meaning.
  const weeklyCap = budget?.weeklyCap ?? WEEKLY_CAP_COINS;
  const grantedCoins = budget?.grantedCoins ?? 0;

  const longest = streak?.longestCount ?? 0;

  return {
    enabled: true,
    wallet: {
      balance: balanceRow[0]?.total ?? 0,
      dailyReleased: releasedOnDay(weeklyCap, dayIndex),
      remaining: availableCoins(weeklyCap, dayIndex, grantedCoins),
    },
    personalProgress: toProgressView(progress?.xp ?? 0, PERSONAL_LEVEL_CURVE_FACTOR),
    streak: {
      current: streak?.currentCount ?? 0,
      longest,
      iceReserve: streak?.iceReserve ?? 0,
      // Derived from the LONGEST streak, not the current one: a milestone
      // already earned must not disappear when a streak breaks (PDR-019's
      // "nivel, XP y monedas permanecen intactos" tone). B9 will record the
      // grants themselves; until then this is the honest read of what has
      // been reached.
      iceMilestonesReached: STREAK_ICE_MILESTONES.filter((m) => longest >= m),
    },
    weeklyBudget: {
      weekKey: budget?.weekKey ?? weekKey(at, effectiveZone),
      periodTimeZone: effectiveZone,
      weeklyCap,
      // Computed for TODAY, deliberately not read back from the stored
      // document. The stored `releasedCoins` is a checkpoint the write path
      // last updated when a completion happened, so on any later day it is
      // stale — a completion on Monday leaves it at Monday's figure even when
      // read on Thursday. Returning that would break the one invariant a
      // client should be able to rely on, `remaining === releasedCoins -
      // grantedCoins`, and a UI computing "available today" from it would
      // under-report for the rest of the week.
      releasedCoins: releasedThroughDay(weeklyCap, dayIndex),
      grantedCoins,
      planVersion: budget?.planVersion ?? 1,
      allocations: (budget?.allocations ?? []).map((a) => ({
        allocationKey: a.allocationKey,
        taskOrRuleId: a.taskOrRuleId ? a.taskOrRuleId.toString() : null,
        expectedFrequency: a.expectedFrequency,
        coinAmount: a.coinAmount,
        mode: a.mode,
      })),
    },
  };
}

export interface MemberProgressView {
  userId: string;
  name: string;
  avatarUrl: string | null;
  /** Shared-progress signal only. Never a wallet, budget or streak. */
  level: number;
  xp: number;
}

export interface SavingsContributionView {
  userId: string;
  name: string;
  amount: number;
}

export interface SavingsGoalView {
  id: string;
  itemType: string;
  itemId: string;
  targetCoins: number;
  contributedCoins: number;
  createdBy: string;
  contributions: SavingsContributionView[];
}

export interface HouseholdEconomyView {
  enabled: boolean;
  householdProgress: ProgressView;
  activeSavingsGoal: SavingsGoalView | null;
  members: MemberProgressView[];
}

/**
 * What the household as a whole may see.
 *
 * ── Where the privacy line falls, and why ────────────────────────────────
 * Included: household XP and level (shared by definition, PDR-017), the
 * active savings goal, and its per-member contribution breakdown — the last
 * of these is explicitly public, since UX-P1-SPEC §6 renders it as
 * «Skin dragón — 68/100 🪙 · Tú: 40 · Ana: 28».
 *
 * Also included, by owner decision (2026-08-27): each member's personal XP
 * and level. No PDR authorizes this — PDR-017 only says the completion chip
 * shows your own — so it is a product call rather than something the design
 * implies, and it is recorded here as such.
 *
 * NEVER included: any member's wallet balance, weekly budget or streak.
 * PDR-012 makes the wallet personal precisely so there is nothing shared to
 * dispute, and a housemate's remaining budget or missed days are the two
 * things most likely to turn a cooperative feature into a way of keeping
 * score — which UX-P1-SPEC §0 rules out in as many words.
 *
 * Members come back in join order, NOT sorted by XP. UX-P1-SPEC §8 requires
 * contributions be shown "nunca ordenadas ni comparadas como ranking"; the
 * same reasoning applies here, and a stable order is what stops the client
 * from accidentally rendering a leaderboard.
 */
export async function getHouseholdEconomy(householdId: string): Promise<HouseholdEconomyView> {
  const householdObjectId = new Types.ObjectId(householdId);

  const memberships = await HouseholdMemberModel.find({ householdId: householdObjectId })
    .select('userId joinedAt')
    .sort({ joinedAt: 1 })
    .lean();
  const memberIds = memberships.map((m) => m.userId);

  const users = await UserModel.find({ _id: { $in: memberIds } })
    .select('name avatarUrl')
    .lean();
  const userById = new Map(users.map((u) => [u._id.toString(), u]));

  if (!(await isP1Enabled(householdId))) {
    return {
      enabled: false,
      householdProgress: emptyProgress(HOUSEHOLD_LEVEL_CURVE_FACTOR),
      activeSavingsGoal: null,
      // The roster is still real with the flag off — it is not economy data,
      // and returning an empty list would make the client show an empty
      // household rather than one whose economy is simply not on yet.
      members: memberships.map((m) => {
        const user = userById.get(m.userId.toString());
        return {
          userId: m.userId.toString(),
          name: user?.name ?? '',
          avatarUrl: user?.avatarUrl ?? null,
          level: 1,
          xp: 0,
        };
      }),
    };
  }

  const [householdProgress, goal, progresses] = await Promise.all([
    HouseholdProgressModel.findOne({ householdId: householdObjectId }).lean(),
    JointSavingsGoalModel.findOne({ householdId: householdObjectId, status: 'active' }).lean(),
    UserProgressModel.find({ userId: { $in: memberIds } }).lean(),
  ]);

  const progressByUser = new Map(progresses.map((p) => [p.userId.toString(), p]));

  let activeSavingsGoal: SavingsGoalView | null = null;
  if (goal) {
    const contributions = await SavingsContributionModel.find({
      goalId: goal._id,
      status: 'active',
    }).lean();

    // Summed per member rather than listed one row per contribution: the UI
    // shows "Tú: 40 · Ana: 28", one figure per person, and several small
    // contributions from the same member are one number to a reader.
    const byUser = new Map<string, number>();
    for (const c of contributions) {
      const key = c.userId.toString();
      byUser.set(key, (byUser.get(key) ?? 0) + c.amount);
    }

    activeSavingsGoal = {
      id: goal._id.toString(),
      itemType: goal.itemType,
      itemId: goal.itemId,
      targetCoins: goal.targetCoins,
      contributedCoins: goal.contributedCoins,
      createdBy: goal.createdBy.toString(),
      contributions: [...byUser.entries()].map(([userId, amount]) => ({
        userId,
        name: userById.get(userId)?.name ?? '',
        amount,
      })),
    };
  }

  return {
    enabled: true,
    householdProgress: toProgressView(householdProgress?.xp ?? 0, HOUSEHOLD_LEVEL_CURVE_FACTOR),
    activeSavingsGoal,
    members: memberships.map((m) => {
      const key = m.userId.toString();
      const user = userById.get(key);
      const progress = progressByUser.get(key);
      return {
        userId: key,
        name: user?.name ?? '',
        avatarUrl: user?.avatarUrl ?? null,
        level: progress?.level ?? 1,
        xp: progress?.xp ?? 0,
      };
    }),
  };
}

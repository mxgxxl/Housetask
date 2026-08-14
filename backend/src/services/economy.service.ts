import { Types } from 'mongoose';
import { EconomyLedgerModel, EconomyReason, IEconomyLedgerEntry } from '../models/EconomyLedger';
import { IPet } from '../models/Pet';
import { DAILY_CAP, HUNGER_DECAY_PER_HOUR, MOOD_DECAY_PER_HOUR } from '../config/economy';
import { logger } from '../utils/logger';

function isDuplicateKeyError(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: number }).code === 11000;
}

function startOfUtcDay(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
}

/**
 * Coins a household has earned since the start of the current UTC day
 * (ADR-006: recurrence and time-window guards are computed in UTC; the same
 * convention applies here rather than inventing a second one).
 *
 * Only positive entries count as "earned" — a future spend (e.g.
 * `cosmetic_buy`, stored as a negative amount per the ledger's doc comment)
 * must not shrink today's earning headroom back open.
 */
export async function getDailyEarned(householdId: string): Promise<number> {
  const since = startOfUtcDay(new Date());
  const [result] = await EconomyLedgerModel.aggregate<{ total: number }>([
    {
      $match: {
        householdId: new Types.ObjectId(householdId),
        amount: { $gt: 0 },
        createdAt: { $gte: since },
      },
    },
    { $group: { _id: null, total: { $sum: '$amount' } } },
  ]);
  return result?.total ?? 0;
}

/** A household's all-time coin balance: the sum of every ledger entry. */
export async function getBalance(householdId: string): Promise<number> {
  const [result] = await EconomyLedgerModel.aggregate<{ total: number }>([
    { $match: { householdId: new Types.ObjectId(householdId) } },
    { $group: { _id: null, total: { $sum: '$amount' } } },
  ]);
  return result?.total ?? 0;
}

/**
 * Grant coins to a household's economy, server-authoritative (PDR-001).
 *
 * Anti-farm in two layers:
 *  1. Idempotency: the ledger's unique (householdId, refId, reason) index
 *     means a second grant for the same task/purchase and reason hits a
 *     duplicate-key error instead of a second row — safe under Dio retries
 *     or a client re-sending `complete`/`purchase`.
 *  2. Daily cap: a household cannot earn more than DAILY_CAP per UTC day.
 *     The check-then-insert here is not transactional, so two grants racing
 *     in the same instant can together overshoot the cap by up to one
 *     grant's `amount` — acceptable for a soft anti-farm cap at household
 *     size 2-6 (see PDR-001); a hard guarantee would need an atomic
 *     aggregate-and-insert, not worth the complexity at this scale.
 *
 * Deliberately never throws: coin-granting must never break the task/
 * purchase completion flow it rides on (Hard Rule "think in production" —
 * a reward is a bonus, not a dependency). Every failure path — duplicate
 * key, cap reached, unexpected error — returns 0.
 *
 * @param refId The task or purchase id this grant is tied to. Required in
 *   practice today: only `task_complete`/`purchase_complete` are granted
 *   (task.service.ts/shopping.service.ts), and both always pass one. A
 *   future `feed`/`play`/`cosmetic_buy`/`adoption_bonus` grant with no
 *   natural refId will need one synthesized (e.g. a UTC-day bucket key) —
 *   the unique index requires refId+reason together to be unique, not
 *   reason alone, so omitting it would let only one such grant ever happen
 *   per household.
 * @returns The amount actually granted (0 if capped, duplicate, or failed).
 */
export async function grantCoins(
  householdId: string,
  amount: number,
  reason: EconomyReason,
  refId?: string,
): Promise<number> {
  try {
    const dailyEarned = await getDailyEarned(householdId);
    if (dailyEarned >= DAILY_CAP) {
      return 0;
    }

    const entry: Partial<IEconomyLedgerEntry> = {
      householdId: new Types.ObjectId(householdId),
      amount,
      reason,
    };
    if (refId) {
      entry.refId = new Types.ObjectId(refId);
    }

    await EconomyLedgerModel.create(entry);
    return amount;
  } catch (err) {
    if (isDuplicateKeyError(err)) {
      return 0;
    }
    logger.error('grantCoins failed (best-effort, not rethrown)', (err as Error).message);
    return 0;
  }
}

export interface PetVitals {
  hunger: number;
  mood: number;
}

/** Apply one decay rate since an anchor time, clamped to [0, 100]. */
function decayFrom(current: number, since: Date, ratePerHour: number, now: Date): number {
  const hoursElapsed = Math.max(0, (now.getTime() - since.getTime()) / 3_600_000);
  return Math.max(0, Math.min(100, Math.round(current - hoursElapsed * ratePerHour)));
}

/**
 * Compute a pet's current hunger/mood by applying time-based decay to its
 * stored values — lazily, without writing anything back to the database.
 *
 * Reads are cheap and frequent (every GET /pets); a decay cron would add
 * infrastructure to keep values fresh that reads-with-computation don't
 * need. The stored `hunger`/`mood` only change on an actual write (feed,
 * play, adoption); everything in between is derived at read time from
 * `lastFedAt`/`lastPlayedAt` (falling back to `adoptedAt` if the pet has
 * never been fed/played with).
 */
export function computeDecay(pet: IPet, now: Date = new Date()): PetVitals {
  return {
    hunger: decayFrom(pet.hunger, pet.lastFedAt ?? pet.adoptedAt, HUNGER_DECAY_PER_HOUR, now),
    mood: decayFrom(pet.mood, pet.lastPlayedAt ?? pet.adoptedAt, MOOD_DECAY_PER_HOUR, now),
  };
}

export interface RecentTransaction {
  amount: number;
  reason: EconomyReason;
  refId: string | null;
  createdAt: Date;
}

const RECENT_TRANSACTIONS_LIMIT = 10;

/** The most recent ledger entries for a household, newest first. */
export async function getRecentTransactions(householdId: string): Promise<RecentTransaction[]> {
  const entries = await EconomyLedgerModel.find({ householdId: new Types.ObjectId(householdId) })
    .sort({ createdAt: -1 })
    .limit(RECENT_TRANSACTIONS_LIMIT)
    .lean();

  return entries.map((entry) => ({
    amount: entry.amount,
    reason: entry.reason,
    refId: entry.refId ? entry.refId.toString() : null,
    createdAt: entry.createdAt,
  }));
}

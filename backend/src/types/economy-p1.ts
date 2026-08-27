/**
 * Shared unions for the P1 economy's ledgers and receipts (TD-066 B2).
 *
 * Lifted out of the individual model files — unlike `EconomyLedger`, which
 * declares its own `EconomyReason` inline — because P1 has FOUR append-only
 * collections that must agree on what a reference is. `EconomyLedger` could
 * own its union because it is the only one of its kind; a per-model copy here
 * would let the coin ledger and the XP ledgers drift into describing the same
 * task completion two different ways, which is exactly the drift the receipt
 * (`RewardGrant`) exists to prevent.
 */

/**
 * What kind of thing a ledger entry points at.
 *
 * Every P1 ledger requires BOTH `refType` and `refId` (R7 of the TD-066
 * commit plan). Fase A's `EconomyLedger` left `refId` optional while its
 * unique index covered `(householdId, refId, reason)`, which means two
 * entries with the same reason and no refId collide — so at most ONE such
 * grant can ever exist per household. That is a trap the P1 ledgers avoid by
 * construction: with both fields required there is no "missing reference"
 * case for an index to collapse.
 */
export type P1RefType =
  /** A Task document; `refId` is its `_id`. */
  | 'task'
  /** A SavingsContribution document; `refId` is its `_id`. */
  | 'savings_contribution'
  /** The HouseholdEconomyMigration that credited a legacy balance. */
  | 'legacy_migration'
  /** One ice purchase; `refId` is the client's operation id for it. */
  | 'ice_purchase';

/**
 * Why coins moved in a member's personal wallet.
 *
 * Positive and negative amounts share the union: a contribution and its
 * refund are two reasons, not one reason with a sign, so the ledger reads as
 * a history rather than a set of arithmetic operations.
 */
export type PersonalCoinReason =
  /** Earned: the first completion of a task instance (PDR-011). */
  | 'task_first_completion'
  /** Credited once at migration, from the Fase A household balance (§6.3). */
  | 'legacy_balance'
  /** Spent: moved into an active joint savings goal (PDR-018). */
  | 'savings_contribution'
  /** Returned: the goal was cancelled, or the member left (PDR-018). */
  | 'savings_refund'
  /** Spent: one ice bought for the streak reserve (PDR-019). */
  | 'ice_purchase';

/**
 * Why XP was granted, on either track.
 *
 * A union of one today, and deliberately still a union: PDR-017 ties XP to
 * completing tasks and nothing else in P1, so a second member would be a
 * product decision, not a refactor. Naming it now means that decision changes
 * one line here instead of a string literal in three schemas.
 */
export type XpReason = 'task_first_completion';

/**
 * What a `RewardGrant` is a receipt for.
 *
 * Part of its unique index, so it is what makes "one reward per task per
 * kind" enforceable at the schema level while leaving room for a future
 * non-completion reward without weakening that guarantee.
 */
export type RewardGrantKind = 'task_first_completion';

/** Lifecycle of a reward receipt. */
export type RewardGrantStatus = 'granted' | 'reverted';

/** Lifecycle of a joint savings goal (PDR-018). */
export type SavingsGoalStatus = 'active' | 'unlocked' | 'cancelled';

/** Lifecycle of one member's contribution to a goal (PDR-018). */
export type SavingsContributionStatus = 'active' | 'applied' | 'refunded';

/**
 * What a streak is anchored to.
 *
 * Owner decision P4 (2026-08-26): v1 anchors streaks to the ACCOUNT, matching
 * the portability of personal XP (PDR-017) — leaving a household must not
 * reset a streak any more than it resets a level. `household` stays in the
 * union because TD-066-DESIGN §3 left the choice open and the model should
 * not have to change if product revisits it; nothing writes it in P1.
 */
export type StreakScope = 'account' | 'household';

/**
 * How a streak day was closed.
 *
 * `open` is the only value that is not a decision: it means the day has not
 * been closed yet, so a late offline sync can still change its outcome
 * (PDR-019).
 */
export type StreakDayCloseState =
  /** Not yet closed; still accepting activity. */
  | 'open'
  /** Closed with useful activity — the streak continued. */
  | 'active'
  /** Closed without activity, covered by an ice from the reserve. */
  | 'ice_covered'
  /** Closed without activity and without an ice — the streak reset. */
  | 'broken'
  /** Sunday: closed as rest, never consumes an ice (PDR-013, PDR-019). */
  | 'rest';

/**
 * How far a household has moved through the P1 migration (§6).
 *
 * `pending` is the state of every household until someone deliberately runs
 * the activation script; there is no implicit progression.
 */
export type EconomyMigrationPhase =
  /** Nothing recorded yet. P1 is off. */
  | 'pending'
  /** Legacy balance and ledger watermark captured; P1 still off (§6.2). */
  | 'snapshotted'
  /** Legacy balance credited and P1 serving this household (§6.4). */
  | 'active'
  /** Rolled back to Fase A reads without destroying any P1 ledger (§6.4). */
  | 'rolled_back';

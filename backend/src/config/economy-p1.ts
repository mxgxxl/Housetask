/**
 * Tunable constants for the P1 economy (TD-066).
 *
 * Deliberately separate from `config/economy.ts` rather than merged into it:
 * Fase A's household-wide coin economy stays alive and unchanged through the
 * whole P1 migration (TD-066-DESIGN §6.5), so the two sets of numbers govern
 * two coexisting systems. Merging them would make it impossible to read a
 * value and know which economy it belongs to.
 *
 * Same rationale as `config/economy.ts` for keeping these as plain numbers
 * instead of env vars: the target is game-balance tuning through code review,
 * not per-deployment configuration.
 *
 * ── Provenance of every number below ──────────────────────────────────────
 * Each constant is tagged with where it comes from:
 *
 *   [PDR]      Fixed by an accepted product decision or by UX-P1-SPEC.md.
 *              Changing it needs a product decision, not a code review.
 *   [APROBADA] No PDR fixes it: proposed here with the reasoning below and
 *              approved by the owner on the date each one carries (the budget
 *              and XP numbers on 2026-08-26, the unlock tables and milestones
 *              on 2026-08-27). Same standing as a [PDR] from here on — the tag
 *              records that the number came from a design proposal rather than
 *              a product decision, which is what tells a future reader where
 *              to go to revisit it.
 *
 * The XP constants and the two level curves are NOT independent: the curves
 * are calibrated against TASK_PERSONAL_XP = 10. Changing that value means
 * re-deriving both, not adjusting one of them.
 */

/* ────────────────────────────────────────────────────────────────────────
 * Weekly personal budget (PDR-011, PDR-012, PDR-013)
 * ──────────────────────────────────────────────────────────────────────── */

/**
 * [PDR] Every member's weekly coin ceiling, identical for all of them
 * (PDR-012: "Cada miembro tiene el mismo techo personal de monedas").
 *
 * The value comes from UX-P1-SPEC.md §4's exact copy for the "Ajustar
 * reparto" header — «Cada semana tienes 200 🪙» — so it is a product-fixed
 * number, not a proposal. Changing it means changing that copy too.
 */
export const WEEKLY_CAP_COINS = 200;

/**
 * [PDR] Days that receive a budget allocation, Monday through Saturday
 * (PDR-013). Sunday is deliberately absent: it grants XP, never breaks a
 * streak, and releases no coins.
 */
export const BUDGET_ALLOCATION_DAYS = 6;

/**
 * [APROBADA] Aprobada por el dueño el 2026-08-26.
 *
 * Fraction of each member's weekly cap held back for the "tramo común" that
 * funds unassigned tasks (owner decision P3, 2026-08-26: an unassigned task
 * is funded from a common tranche rather than attributed to one person's
 * allocation).
 *
 * Reasoning for 20%: the tranche has to be big enough that a household which
 * never assigns tasks still earns a meaningful share — otherwise the feature
 * silently punishes the least-configured households, which is exactly the
 * "cero configuración por defecto" promise of PDR-011 — but small enough that
 * it does not swallow the assigned plan it sits next to. A fifth leaves 160 🪙
 * of the 200 for named allocations and 40 🪙 for the shared pool.
 *
 * Note this is a fraction of EACH member's cap, not of a household total:
 * PDR-012 has no common purse, so the tranche is per-person by construction
 * and the household does not inflate as it grows.
 */
export const COMMON_TRANCHE_FRACTION = 0.2;

/**
 * [APROBADA] Aprobada por el dueño el 2026-08-26.
 *
 * Fallback coin value for one task completion when no weekly plan has been
 * built yet (a brand-new member, or the very first completion of a week
 * before the automatic plan runs).
 *
 * Reasoning for 5: it is exactly Fase A's `TASK_COINS`, so a household
 * crossing the flag on its first day sees no change in what a task is worth.
 * Continuity beats a fresh guess for a value that only ever applies in a gap.
 */
export const DEFAULT_TASK_COINS = 5;

/* ────────────────────────────────────────────────────────────────────────
 * XP (PDR-017) — dual, personal-portable and household-shared
 * ──────────────────────────────────────────────────────────────────────── */

/**
 * [APROBADA] Aprobada por el dueño el 2026-08-26.
 *
 * Personal XP granted for the first completion of a task instance.
 *
 * Reasoning for 10: XP is explicitly NOT capped by the weekly budget
 * (TD-066-DESIGN §3: "XP no se reduce cuando la moneda llega a cero"), so it
 * is the signal that keeps working after the coins run out. A round 10 makes
 * the level thresholds below readable as "number of tasks" at a glance —
 * level 2 is 10 tasks — which matters more for tuning than any particular
 * magnitude, since only the ratio to the curve is meaningful.
 */
export const TASK_PERSONAL_XP = 10;

/**
 * [APROBADA] Aprobada por el dueño el 2026-08-26.
 *
 * Household XP granted for the same completion, on top of the personal grant.
 *
 * Reasoning for 10: equal to the personal grant, so one completion reads as
 * "worth the same to you and to the house". The asymmetry that keeps
 * household levels from racing ahead lives in the CURVE (a household of H
 * members accrues H times faster), not in the per-event amount — see
 * HOUSEHOLD_LEVEL_CURVE_FACTOR.
 */
export const TASK_HOUSEHOLD_XP = 10;

/**
 * [APROBADA] Aprobada por el dueño el 2026-08-26.
 *
 * Cumulative personal XP required to REACH level N: `50 * N * (N - 1)`.
 *
 *   L1 → 0     L2 → 100    L3 → 300    L4 → 600
 *   L5 → 1000  L6 → 1500   L10 → 4500  L20 → 19000
 *
 * The step between consecutive levels grows linearly (100, 200, 300, …), so
 * early levels arrive fast and later ones stretch — the standard shape for
 * progress that should feel generous at the start without becoming trivial.
 *
 * Calibration at TASK_PERSONAL_XP = 10 and a plausible ~20 tasks/week per
 * person (200 XP/week): level 2 lands in the first few days, level 5 at about
 * a month, level 10 at about five months. If either input changes, this is
 * the number to re-derive, not the one to keep.
 */
export const PERSONAL_LEVEL_CURVE_FACTOR = 50;

/**
 * [APROBADA] Aprobada por el dueño el 2026-08-26.
 *
 * Same curve shape for the household, with a factor of 100:
 * `100 * N * (N - 1)`.
 *
 *   L2 → 200   L3 → 600    L5 → 2000   L6 → 3000
 *
 * Double the personal factor because a household pool fills at H times the
 * personal rate; at the modal household size of 2 (PDR-001 assumes 2-6) the
 * two tracks then advance at roughly the same pace, which is what makes the
 * personal and household level numbers comparable to a user looking at both.
 * A 6-person household will still outrun its members — that is the intended
 * cooperative signal, not a bug.
 *
 * UX-P1-SPEC.md §4's «200 XP para nivel 6» is illustrative copy, not a
 * binding threshold: it shows the REMAINING amount in a sample state. This
 * formula is what governs.
 */
export const HOUSEHOLD_LEVEL_CURVE_FACTOR = 100;

/**
 * Cumulative XP needed to reach `level`, for either track.
 *
 * Exported as a function rather than a precomputed table because the curve
 * is unbounded — there is no maximum level — and a table would quietly cap
 * progression at whatever length someone picked.
 *
 * @param level 1-based. Level 1 is the starting level and costs 0.
 * @param factor PERSONAL_LEVEL_CURVE_FACTOR or HOUSEHOLD_LEVEL_CURVE_FACTOR.
 */
export function xpRequiredForLevel(level: number, factor: number): number {
  if (!Number.isInteger(level) || level < 1) {
    throw new RangeError(`level must be an integer >= 1, got ${level}`);
  }
  return factor * level * (level - 1);
}

/**
 * The level a given cumulative XP total has reached, inverting
 * `xpRequiredForLevel`.
 *
 * Solves `factor * N * (N - 1) <= xp` for the largest integer N, then walks
 * one step in each direction to correct for floating-point error at the
 * boundary. The walk matters: an exact-threshold XP total (say 100 with
 * factor 50) is precisely where a naive `Math.floor` of the quadratic
 * formula lands on the wrong side, and hitting a level boundary exactly is
 * the common case, not the rare one — every grant is a round number.
 */
export function levelForXp(xp: number, factor: number): number {
  if (xp < 0) {
    throw new RangeError(`xp must be >= 0, got ${xp}`);
  }
  if (factor <= 0) {
    throw new RangeError(`factor must be > 0, got ${factor}`);
  }

  // N = (1 + sqrt(1 + 4*xp/factor)) / 2
  let level = Math.floor((1 + Math.sqrt(1 + (4 * xp) / factor)) / 2);
  if (level < 1) {
    level = 1;
  }
  while (level > 1 && xpRequiredForLevel(level, factor) > xp) {
    level--;
  }
  while (xpRequiredForLevel(level + 1, factor) <= xp) {
    level++;
  }
  return level;
}

/* ────────────────────────────────────────────────────────────────────────
 * Level unlocks and milestones (TD-066 B7)
 * ──────────────────────────────────────────────────────────────────────── */

/**
 * What reaching a personal level grants.
 *
 * [APROBADA] Aprobada por el dueño el 2026-08-27. The shape is settled by PDR-017
 * ("títulos y badges" for the personal track), but no PDR names a single one
 * of them, so every string below is a placeholder chosen to be renameable.
 *
 * Ids, not display strings: the UI is Spanish (see CLAUDE.md's Frontend
 * Theme) and a label baked into an unlock record would be untranslatable and
 * unchangeable after it has been granted. The client maps id → label.
 *
 * Sparse on purpose. A level with no entry grants nothing, which is what
 * makes an unlock feel like an event; rewarding every single level turns the
 * unlock into the level number itself.
 */
export const PERSONAL_LEVEL_UNLOCKS: Readonly<Record<number, readonly string[]>> = {
  2: ['title:aprendiz'],
  3: ['badge:constante'],
  5: ['title:veterano'],
  8: ['badge:incansable'],
  10: ['title:maestro-del-hogar'],
  15: ['badge:leyenda'],
};

/**
 * What reaching a household level grants.
 *
 * [APROBADA] Aprobada por el dueño el 2026-08-27. PDR-017 assigns "cosméticos
 * compartidos, incluida la mascota" to this track, and the three ids below
 * deliberately reuse the Fase A catalog already in `COSMETICS` rather than
 * inventing assets the art track has not produced (PDR-015). Anything beyond
 * those three needs art before it can be a real unlock.
 */
export const HOUSEHOLD_LEVEL_UNLOCKS: Readonly<Record<number, readonly string[]>> = {
  2: ['cosmetic:hat'],
  3: ['cosmetic:scarf'],
  5: ['cosmetic:glasses'],
};

/**
 * Personal task-count milestones, celebrated once each.
 *
 * [APROBADA] Aprobada por el dueño el 2026-08-27. Distinct from levels on purpose:
 * a level is a function of XP, which the weekly budget never caps, whereas
 * these count actual completions. They are the "hito" tier of UX-P1-SPEC §3's
 * celebration hierarchy — rarer than a level, hence a stronger celebration.
 *
 * Reasoning for 10/50/100/365: the first arrives within days so the mechanic
 * announces itself early; 365 reads as "a year's worth" without requiring a
 * year. They are NOT ice milestones — those are PDR-019's 7/14/30/50/100 and
 * count consecutive DAYS, not completions.
 */
export const PERSONAL_TASK_MILESTONES: readonly number[] = [10, 50, 100, 365];

/**
 * Household task-count milestones, celebrated once each by the whole home.
 *
 * [APROBADA] Aprobada por el dueño el 2026-08-27. Roughly the personal thresholds
 * doubled, because a household pools every member's completions and the modal
 * home has two people (PDR-001): the intent is that a household hits these at
 * about the pace one person hits theirs, so the two tracks feel comparable
 * rather than one drowning the other.
 *
 * NOT a coins-saved milestone, though that is the more evocative example: a
 * joint savings goal does not exist until B10, so a threshold on it could not
 * be measured today and would ship as dead code.
 */
export const HOUSEHOLD_TASK_MILESTONES: readonly number[] = [25, 100, 250, 750];

/**
 * The unlocks a given level grants, or an empty array for a level that grants
 * nothing.
 *
 * Frozen empty array rather than a fresh `[]` per miss: this runs on the
 * reward path, most levels grant nothing, and a shared immutable is both
 * cheaper and impossible to mutate by accident.
 */
const NO_UNLOCKS: readonly string[] = Object.freeze([]);

export function unlocksForLevel(
  level: number,
  table: Readonly<Record<number, readonly string[]>>,
): readonly string[] {
  return table[level] ?? NO_UNLOCKS;
}

/**
 * Every unlock earned up to and including `level`.
 *
 * The read side needs this, not just the level-up event: an unlock announced
 * only over a socket is forgotten on the next app launch. Computed from the
 * level rather than stored, so the two can never disagree and a retuned table
 * applies retroactively instead of leaving old accounts holding ids that no
 * longer exist.
 */
export function unlocksUpToLevel(
  level: number,
  table: Readonly<Record<number, readonly string[]>>,
): string[] {
  const earned: string[] = [];
  for (const key of Object.keys(table)) {
    const at = Number(key);
    if (at <= level) {
      earned.push(...table[at]);
    }
  }
  return earned;
}

/**
 * The milestone a counter just crossed, or `null` if it crossed none.
 *
 * Takes the value BEFORE and AFTER so crossing is detected exactly once,
 * without storing which milestones have already fired: the counter only ever
 * increases, and the reward transaction increments it a single time per task
 * (the `RewardGrant` claim guarantees that), so "was below, is now at or
 * above" happens once per threshold by construction.
 */
export function milestoneCrossed(
  previous: number,
  current: number,
  milestones: readonly number[],
): number | null {
  for (const milestone of milestones) {
    if (previous < milestone && current >= milestone) {
      return milestone;
    }
  }
  return null;
}

/* ────────────────────────────────────────────────────────────────────────
 * Streaks and ice (PDR-019)
 * ──────────────────────────────────────────────────────────────────────── */

/** [PDR] Streak lengths that grant one ice each (PDR-019). */
export const STREAK_ICE_MILESTONES: readonly number[] = [7, 14, 30, 50, 100];

/** [PDR] Coin price of one ice bought from the shop (PDR-019). */
export const ICE_PRICE_COINS = 20;

/**
 * [PDR] Maximum ices held in reserve (PDR-019).
 *
 * Also the cap that makes a late-sync refund conditional: approved decision 5
 * of TD-066-DESIGN reads PDR-019 as "refund if there is capacity", so a
 * refund that would push the reserve past this is discarded rather than
 * overflowing.
 */
export const MAX_ICE_RESERVE = 2;

/* ────────────────────────────────────────────────────────────────────────
 * Offline completion window (TD-066-DESIGN §4, §9)
 * ──────────────────────────────────────────────────────────────────────── */

/**
 * [APROBADA] Aprobada por el dueño el 2026-08-26.
 *
 * How far in the past a client-supplied `occurredAt` may sit before the
 * server refuses to honour it. TD-066-DESIGN §4 requires "una ventana
 * permitida" but does not fix its size; §9 lists a manipulated or
 * too-old offline timestamp as a named risk.
 *
 * Reasoning for 7 days: it matches the refresh-token lifetime, so it is
 * already the longest a client can stay away and come back without
 * re-authenticating — a completion older than that arrives on a session that
 * could not have survived anyway. It also spans a full week, so no single
 * offline stretch can silently reach back into a `weekKey` that has already
 * been closed and settled.
 */
export const OCCURRED_AT_MAX_PAST_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * [APROBADA] Aprobada por el dueño el 2026-08-26.
 *
 * How far ahead of server time an `occurredAt` may sit. Not zero, because a
 * device clock a little fast is ordinary and must not have its completions
 * rejected; small, because a future timestamp is otherwise the cheapest way
 * to claim tomorrow's budget today.
 *
 * Reasoning for 5 minutes: comfortably above realistic unsynchronised-clock
 * drift, far below the day boundary that would let it cross into another
 * `effectiveDayKey`.
 */
export const OCCURRED_AT_MAX_FUTURE_MS = 5 * 60 * 1000;

/* ────────────────────────────────────────────────────────────────────────
 * Timezone (approved decision 1, owner decision P8)
 * ──────────────────────────────────────────────────────────────────────── */

/**
 * [PDR] The zone used when a household has no valid IANA timezone recorded.
 *
 * Approved decision 1 allows UTC as an explicitly documented fallback. Owner
 * decision P8 (2026-08-26) chose IANA from B1 onward, so this is the
 * degraded path only — never the default the code aims for. It is stored in
 * `WeeklyPersonalBudget.periodTimeZone` like any other zone, so a budget
 * computed under the fallback stays reproducible after the household's real
 * zone is known.
 */
export const FALLBACK_TIME_ZONE = 'UTC';

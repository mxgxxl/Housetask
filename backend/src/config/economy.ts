/**
 * Tunable constants for the PDR-001 Fase A economy. Kept as plain numbers
 * (not env-driven) because the target is game-balance tuning through code
 * review, not per-deployment configuration — the same reasoning as
 * task.service.ts's MAX_TITLE_LENGTH.
 */

/** Coins granted the first time a task is completed. */
export const TASK_COINS = 5;

/** Coins granted the first time a shopping item is purchased. */
export const PURCHASE_COINS = 2;

/** Maximum coins a household can earn per UTC calendar day (anti-farm). */
export const DAILY_CAP = 50;

/** Hunger points lost per hour since the pet was last fed. */
export const HUNGER_DECAY_PER_HOUR = 2;

/** Mood points lost per hour since the pet was last played with. */
export const MOOD_DECAY_PER_HOUR = 2;

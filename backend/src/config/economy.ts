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

/** Hunger points restored by one feed action, clamped to [0, 100]. */
export const FEED_AMOUNT = 30;

/** Mood points restored by one play action, clamped to [0, 100]. */
export const PLAY_AMOUNT = 30;

/** Minimum time between two feed actions on the same pet (anti-farm). */
export const FEED_COOLDOWN_HOURS = 1;

/** Minimum time between two play actions on the same pet (anti-farm). */
export const PLAY_COOLDOWN_HOURS = 1;

/**
 * One-time bonus granted when a household's adoption is confirmed
 * (PDR-001 A2). Not specified in the original PDR; picked as more than a
 * single task/purchase grant but less than any cosmetic, so it feels like
 * an event without trivializing the shop.
 */
export const ADOPTION_BONUS_COINS = 20;

export interface Cosmetic {
  id: string;
  name: string;
  price: number;
}

/**
 * Cosmetics shop catalog (PDR-001 Fase A). Static for now — no admin UI or
 * DB-backed catalog exists to manage it, and Fase A's scope is "una tienda
 * pequeña de cosméticos por moneda" (docs/PRODUCT_DECISIONS.md).
 */
export const COSMETICS: Cosmetic[] = [
  { id: 'hat', name: 'Sombrero', price: 20 },
  { id: 'scarf', name: 'Bufanda', price: 30 },
  { id: 'glasses', name: 'Gafas', price: 40 },
];

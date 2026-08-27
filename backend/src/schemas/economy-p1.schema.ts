import { z } from 'zod';

import { isValidTimeZone } from '../utils/economy-period';

/**
 * Request validation for the P1 economy endpoints (TD-066 B3, TD-028).
 *
 * Applied at the edge via `validate()` before `idempotency`, so a malformed
 * body fails fast without ever claiming — and burning — the client's
 * Idempotency-Key.
 */

/**
 * Body of `POST /households/:householdId/tasks/:taskId/completions`.
 *
 * Every field is OPTIONAL, which is the point: an empty body must be a valid
 * "I completed this now, in UTC". That is what lets the legacy PATCH paths
 * route through the same service in B4 without inventing an offline timestamp
 * they never had (owner decision P7), and it keeps the endpoint usable from a
 * client that has not adopted the offline queue yet.
 */
export const completeTaskP1Schema = z.object({
  /**
   * When the completion actually happened, for an operation that was queued
   * offline. Bounded server-side against OCCURRED_AT_MAX_PAST_MS /
   * OCCURRED_AT_MAX_FUTURE_MS — the shape check here only rejects input that
   * is not a date at all.
   *
   * `z.coerce.date()` accepts an ISO string and hands the service a real
   * Date, matching how task.schema.ts coerces its own date fields.
   */
  occurredAt: z.coerce.date({ error: 'occurredAt must be a valid ISO date' }).optional(),

  /**
   * The member's IANA timezone, e.g. `Europe/Madrid`.
   *
   * Validated against the runtime's own tz database rather than a regex: an
   * unknown zone silently falling back to UTC would move a member's week
   * boundary by hours without anyone noticing, and the whole reason B1
   * derives days in IANA is that such a shift is a task that goes unpaid
   * (PDR-013). Better to reject the request than to pay the wrong day.
   */
  timeZone: z
    .string()
    .trim()
    .min(1)
    .refine(isValidTimeZone, { error: 'timeZone must be a valid IANA timezone' })
    .optional(),
});

export type CompleteTaskP1Body = z.infer<typeof completeTaskP1Schema>;

/**
 * Query of `GET /households/:householdId/economy/p1/me` (B6).
 *
 * The read side has the same timezone problem as the write side and solves it
 * the same way: nothing persists a member's zone yet, so it travels per
 * request. It matters here because the endpoint reports what today released
 * and what is left — both of which depend on which day "today" is, and a
 * member in Madrid asking at 00:30 on Monday must not be told about Sunday.
 *
 * Applied with `validateQuery`, not `validate`: Express 5 makes `req.query` a
 * getter, so the parsed result lands on `res.locals.query`.
 */
export const personalEconomyQuerySchema = z.object({
  timeZone: z
    .string()
    .trim()
    .min(1)
    .refine(isValidTimeZone, { error: 'timeZone must be a valid IANA timezone' })
    .optional(),
});

export type PersonalEconomyQuery = z.infer<typeof personalEconomyQuerySchema>;

/**
 * Body of `PATCH /households/:householdId/economy/p1/budget` (B8).
 *
 * One endpoint covers both directions of PDR-011's "ajustar reparto" and
 * "volver a automático", because they are one button in the UI and two
 * endpoints for one toggle would let a client end up in neither state. `mode`
 * is what distinguishes them.
 *
 * `allocations` carries only `coinAmount`. `expectedFrequency` is an
 * observation about the household's work, not a preference: letting a member
 * edit it would let them raise their own ceiling by claiming a chore happens
 * ten times a week, which is precisely the inflation PDR-011 bounds.
 */
export const updateBudgetSchema = z.object({
  /**
   * Which week to rewrite. Absent means the current one, derived server-side
   * — a client should not have to compute an ISO week to save a slider.
   */
  weekKey: z
    .string()
    .trim()
    .regex(/^\d{4}-W\d{2}$/, { error: 'weekKey must look like 2026-W35' })
    .optional(),
  timeZone: z
    .string()
    .trim()
    .min(1)
    .refine(isValidTimeZone, { error: 'timeZone must be a valid IANA timezone' })
    .optional(),
  mode: z.enum(['automatic', 'manual'], { error: 'mode must be automatic or manual' }),
  allocations: z
    .array(
      z.object({
        allocationKey: z.string().trim().min(1, 'allocationKey is required'),
        coinAmount: z.coerce
          .number()
          .int('coinAmount must be a whole number of coins')
          .min(0, 'coinAmount cannot be negative'),
      }),
    )
    .optional(),
});

export type UpdateBudgetBody = z.infer<typeof updateBudgetSchema>;

/**
 * Body of `POST /households/:householdId/economy/p1/ice` (B9).
 *
 * Empty by design: what an ice costs and how many may be held are
 * server-authoritative (PDR-019), so there is nothing for the client to
 * propose. The schema exists anyway to reject a body that tries.
 */
export const buyIceSchema = z.object({}).strict();

export type BuyIceBody = z.infer<typeof buyIceSchema>;

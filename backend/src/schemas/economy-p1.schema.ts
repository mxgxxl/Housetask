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

import { Request, Response, NextFunction, RequestHandler } from 'express';
import { ZodType, z } from 'zod';

/**
 * Validates `req.body` against a Zod schema before the route handler runs
 * (TD-028). On success, `req.body` is REPLACED with the schema's
 * parsed/coerced output — e.g. ISO date strings become `Date` objects — so
 * controllers and services downstream receive typed, normalized data instead
 * of the raw wire payload.
 *
 * On failure, this responds 400 directly rather than throwing an `AppError`
 * (whose shape only carries a single message string): a validation failure
 * needs one extra field, `details` (the full per-field error map from
 * `z.flattenError`), alongside the standard `{ success, error }` envelope.
 * This is additive, not a break of the response envelope (Hard Rule 7):
 * `success` and `error` are exactly what every other error response has —
 * `error` is the FIRST failing field's own message (matching every other
 * hand-written 400 in this codebase, e.g. 'Task title is required'), not a
 * generic "Validation failed" string, so existing single-violation error
 * assertions keep working unchanged. `details` is new information alongside
 * `error`, not a replacement for it, for callers that want the full
 * breakdown when more than one field fails at once.
 */
export function validate<T>(schema: ZodType<T>): RequestHandler {
  return (req: Request, res: Response, next: NextFunction): void => {
    const result = schema.safeParse(req.body);

    if (!result.success) {
      res.status(400).json({
        success: false,
        error: result.error.issues[0]?.message ?? 'Validation failed',
        details: z.flattenError(result.error),
      });
      return;
    }

    req.body = result.data;
    next();
  };
}

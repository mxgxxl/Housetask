import { AppError } from '../middleware/error.middleware';

/**
 * Trim and length-check a user-supplied string.
 *
 * The value is stored RAW (ADR-009): HTML escaping is a rendering concern, and
 * escaping at storage time made Flutter — whose Text() never interprets markup
 * — display "Tom &amp; Jerry" to the user. NoSQL injection is blocked at the
 * edge by express-mongo-sanitize, not here.
 *
 * @param input Raw value from the request body.
 * @param maxLength Maximum accepted length after trimming.
 * @param field Field name, used in the error message.
 * @throws AppError 400 when the trimmed value exceeds `maxLength`.
 */
export function sanitizeString(input: string, maxLength: number, field = 'value'): string {
  const trimmed = input.trim();

  if (trimmed.length > maxLength) {
    throw new AppError(`${field} must be at most ${maxLength} characters`, 400);
  }

  return trimmed;
}

/** Earliest date the API accepts — anything older is a client bug or an attack. */
const MIN_DATE = new Date('2020-01-01T00:00:00.000Z');

/** Furthest future date accepted, to keep recurrence horizons sane. */
const MAX_YEARS_AHEAD = 10;

/**
 * Parse and range-check a user-supplied date.
 *
 * Unbounded dates let a client push a task to year 9999, which then sorts ahead
 * of everything forever, or to 1970, which pollutes every "overdue" view.
 *
 * @throws AppError 400 when unparseable or outside [2020-01-01, now + 10y].
 */
export function sanitizeDate(input: string | Date, field = 'date'): Date {
  const parsed = input instanceof Date ? input : new Date(input);

  if (Number.isNaN(parsed.getTime())) {
    throw new AppError(`${field} is not a valid date`, 400);
  }

  const maxDate = new Date();
  maxDate.setUTCFullYear(maxDate.getUTCFullYear() + MAX_YEARS_AHEAD);

  if (parsed < MIN_DATE || parsed > maxDate) {
    throw new AppError(
      `${field} must be between ${MIN_DATE.toISOString().slice(0, 10)} and ${MAX_YEARS_AHEAD} years from now`,
      400,
    );
  }

  return parsed;
}

import { AppError } from '../middleware/error.middleware';

/**
 * Escape the five HTML-significant characters.
 *
 * `&` MUST be replaced first: doing it later would re-escape the ampersands
 * introduced by the other rules, turning `<` into `&amp;lt;`.
 *
 * This is defence in depth, not the primary control — the Flutter client
 * renders text, not HTML. It matters the day this data reaches a web view, an
 * email or an export, where stored markup would execute.
 */
export function escapeHtml(input: string): string {
  return input
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/**
 * Trim, length-check and escape a user-supplied string.
 *
 * The length is measured on the trimmed input, before escaping: escaping can
 * multiply a string's length sixfold, so checking afterwards would reject
 * legitimate text for containing quotes.
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

  return escapeHtml(trimmed);
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
      400
    );
  }

  return parsed;
}

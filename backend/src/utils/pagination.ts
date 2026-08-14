import { AppError } from '../middleware/error.middleware';

export const DEFAULT_PAGE_LIMIT = 50;
export const MIN_PAGE_LIMIT = 1;
export const MAX_PAGE_LIMIT = 100;

/**
 * One page of a cursor-paginated list.
 *
 * `total` counts every row matching the filter and is returned ONLY on the
 * first page (no cursor), so a client can show "23 tasks" while holding one
 * page. Paged requests get `null` instead of paying for an identical
 * countDocuments on every scroll step (ADR-008).
 */
export interface Page<T> {
  items: T[];
  nextCursor: string | null;
  hasMore: boolean;
  total: number | null;
}

/**
 * Parse and validate the `limit` query parameter.
 *
 * @param raw The raw `req.query.limit` value.
 * @returns A limit within [MIN_PAGE_LIMIT, MAX_PAGE_LIMIT].
 * @throws AppError 400 when present but not an integer in range.
 */
export function parseLimit(raw: unknown): number {
  if (raw === undefined) {
    return DEFAULT_PAGE_LIMIT;
  }
  if (typeof raw !== 'string') {
    throw new AppError('Invalid limit', 400);
  }

  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < MIN_PAGE_LIMIT || parsed > MAX_PAGE_LIMIT) {
    throw new AppError(
      `limit must be an integer between ${MIN_PAGE_LIMIT} and ${MAX_PAGE_LIMIT}`,
      400,
    );
  }
  return parsed;
}

/**
 * Read the optional `cursor` query parameter.
 *
 * @throws AppError 400 when present but not a single string (e.g. repeated).
 */
export function parseCursorParam(raw: unknown): string | undefined {
  if (raw === undefined) {
    return undefined;
  }
  if (typeof raw !== 'string' || raw.length === 0) {
    throw new AppError('Invalid cursor', 400);
  }
  return raw;
}

/**
 * Read an optional ISO-timestamp query parameter (e.g. `from`/`to` for the
 * PDR-003 timeline window, docs/PRODUCT_DECISIONS.md). The client computes
 * these as absolute instants from its own local calendar boundaries — the
 * server treats them as opaque UTC instants, never as server-local days.
 *
 * @throws AppError 400 when present but not a single, parseable date string.
 */
export function parseDateParam(raw: unknown, field: string): Date | undefined {
  if (raw === undefined) {
    return undefined;
  }
  if (typeof raw !== 'string' || raw.length === 0) {
    throw new AppError(`Invalid ${field}`, 400);
  }
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) {
    throw new AppError(`Invalid ${field}`, 400);
  }
  return parsed;
}

/**
 * Encode a sort position as an opaque base64 cursor.
 *
 * The payload carries the FULL sort position, not just the id: under a
 * compound sort an id-only cursor silently skips or repeats rows whenever the
 * leading keys tie (see ADR-008).
 */
export function encodeCursor(position: Record<string, unknown>): string {
  return Buffer.from(JSON.stringify(position), 'utf8').toString('base64');
}

/**
 * Decode and validate an opaque cursor.
 *
 * @param raw The base64 cursor from the client.
 * @param isValid Type guard asserting the decoded payload's shape.
 * @throws AppError 400 for anything that is not a well-formed cursor — the
 *   value is opaque to clients, so a malformed one is always a client error.
 */
export function decodeCursor<T>(raw: string, isValid: (value: unknown) => value is T): T {
  let decoded: unknown;
  try {
    decoded = JSON.parse(Buffer.from(raw, 'base64').toString('utf8'));
  } catch {
    throw new AppError('Invalid cursor', 400);
  }

  if (!isValid(decoded)) {
    throw new AppError('Invalid cursor', 400);
  }
  return decoded;
}

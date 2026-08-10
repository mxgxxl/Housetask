import { Response, NextFunction } from 'express';
import { IdempotencyStore } from '../services/idempotency.store';
import { AppError } from './error.middleware';
import { asyncHandler } from '../utils/asyncHandler';
import { AuthenticatedRequest } from '../types';

export const IDEMPOTENCY_HEADER = 'idempotency-key';

/** How long a key stays claimed and its result replayable. */
const RESULT_TTL_MS = 24 * 60 * 60 * 1000;

/** How long a duplicate waits for the in-flight original before giving up. */
const WAIT_FOR_RESULT_MS = 2000;

/**
 * Express app setting holding the active store (null disables the feature).
 */
export const IDEMPOTENCY_STORE_KEY = 'idempotencyStore';

/**
 * Idempotency-Key handling for resource-creating POSTs, per ADR-007.
 *
 * The header is OPTIONAL: without it the route behaves exactly as before, which
 * is what lets the Flutter client adopt it later without a flag day.
 *
 * With it:
 *  - the key is reserved BEFORE the handler runs, so two racing requests cannot
 *    both create;
 *  - a repeat whose original finished replays the stored body with HTTP 200 and
 *    never re-runs the handler, so no socket event is emitted twice;
 *  - a repeat that arrives while the original is still running waits up to 2s
 *    and then answers 409 rather than guessing;
 *  - if the STORE itself is unavailable the request is processed without
 *    idempotency (fail-open), never blocked.
 *
 * Keys are scoped per user and route before hashing: an unscoped key would let
 * one account observe or poison another's response for the same key string.
 */
export const idempotency = asyncHandler(
  async (req: AuthenticatedRequest, res: Response, next: NextFunction): Promise<void> => {
    const store = req.app.get(IDEMPOTENCY_STORE_KEY) as IdempotencyStore | null;
    const clientKey = req.get(IDEMPOTENCY_HEADER);

    if (!store || !clientKey) {
      next();
      return;
    }

    const scopedKey = `${req.user?.userId ?? 'anonymous'}:${req.method}:${req.originalUrl.split('?')[0]}:${clientKey}`;

    const outcome = await store.acquire(scopedKey, RESULT_TTL_MS);

    // Fail-open: the store is down, so duplicate protection is unavailable.
    // Proceed exactly as a request without the header would — losing dedupe is
    // a correctness regression, refusing or hanging every write is an outage
    // (TD-031). The store already logged the reason.
    if (outcome === 'failed') {
      next();
      return;
    }

    if (outcome === 'exists') {
      const stored =
        (await store.getResult(scopedKey)) ??
        (await store.waitForResult(scopedKey, WAIT_FOR_RESULT_MS));

      if (!stored) {
        throw new AppError('A request with this Idempotency-Key is still in progress', 409);
      }

      // Replay is a 200, not the original 201: nothing was created this time.
      res.status(200).json(stored.body);
      return;
    }

    // We own the key: capture whatever the handler ends up sending.
    const sendJson = res.json.bind(res);
    res.json = (body: unknown): Response => {
      if (res.statusCode >= 200 && res.statusCode < 300) {
        void store.setResult(scopedKey, { status: res.statusCode, body }, RESULT_TTL_MS);
      } else {
        // A failed attempt must not lock the key for 24h.
        void store.release(scopedKey);
      }
      return sendJson(body);
    };

    next();
  }
);

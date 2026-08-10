import { getCommandClient } from '../config/redis';
import { sha256 } from '../utils/hash';
import { logger } from '../utils/logger';

/** A captured response, replayed verbatim for a repeated Idempotency-Key. */
export interface IdempotencyResult {
  status: number;
  body: unknown;
}

/**
 * Outcome of reserving a key.
 *
 * `failed` means the store itself is unavailable — not that the key is taken.
 * Callers MUST treat it as "proceed without idempotency" (fail-open): losing
 * duplicate protection is a correctness regression, hanging or refusing every
 * write is an outage (TD-031).
 */
export type AcquireOutcome = 'acquired' | 'exists' | 'failed';

/**
 * Marker stored while the original request is still running, so a concurrent
 * caller can tell "someone is working on it" from "nothing here".
 */
const IN_PROGRESS = '__in_progress__';

const POLL_INTERVAL_MS = 25;

/**
 * Storage backing Idempotency-Key handling (ADR-007).
 *
 * `acquire` must be atomic: it is the reservation that makes two simultaneous
 * requests resolve to a single creation.
 *
 * Every method is failure-tolerant: implementations MUST NOT propagate
 * exceptions to the request path. A broken store degrades the feature, never
 * the endpoint.
 */
export interface IdempotencyStore {
  /** Reserve a key. 'acquired' means this caller owns the operation. */
  acquire(key: string, ttlMs: number): Promise<AcquireOutcome>;
  /** Publish the finished response for replay. */
  setResult(key: string, result: IdempotencyResult, ttlMs: number): Promise<void>;
  /** Finished response, or null when unknown, in progress, or unavailable. */
  getResult(key: string): Promise<IdempotencyResult | null>;
  /** Poll `getResult` until it resolves or `timeoutMs` elapses. */
  waitForResult(key: string, timeoutMs: number): Promise<IdempotencyResult | null>;
  /**
   * Drop a reservation whose operation failed, so the client can retry.
   * Not part of ADR-007's sketch but required in practice: without it a failed
   * request would keep its key locked until the TTL and every retry would hit
   * the 2s wait and then 409.
   */
  release(key: string): Promise<void>;
}

/** Namespaced, hashed storage key — raw client keys are never persisted. */
export function storageKey(scope: string): string {
  return `idem:${sha256(scope)}`;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function parseResult(raw: string | null): IdempotencyResult | null {
  if (raw === null || raw === IN_PROGRESS) {
    return null;
  }
  try {
    return JSON.parse(raw) as IdempotencyResult;
  } catch {
    return null;
  }
}

/**
 * Log a store failure once per occurrence. Security-grade: losing idempotency
 * silently is how duplicate writes reach production unnoticed.
 */
function reportUnavailable(operation: string, error: unknown): void {
  logger.warn('idempotency-store unavailable, fail-open', {
    operation,
    error: (error as Error)?.message ?? String(error),
  });
}

/**
 * Production store. `SET key <marker> NX PX ttl` is the atomic reservation, so
 * exactly one of N racing requests proceeds even across server instances.
 *
 * Every call runs on the dedicated command client, whose `commandTimeout`
 * makes a Redis outage surface as a rejected promise within ~1s instead of an
 * indefinitely queued command.
 */
export class RedisIdempotencyStore implements IdempotencyStore {
  async acquire(key: string, ttlMs: number): Promise<AcquireOutcome> {
    try {
      const result = await getCommandClient().set(storageKey(key), IN_PROGRESS, 'PX', ttlMs, 'NX');
      return result === 'OK' ? 'acquired' : 'exists';
    } catch (err) {
      reportUnavailable('acquire', err);
      return 'failed';
    }
  }

  async setResult(key: string, result: IdempotencyResult, ttlMs: number): Promise<void> {
    try {
      await getCommandClient().set(storageKey(key), JSON.stringify(result), 'PX', ttlMs);
    } catch (err) {
      // The response was already produced; failing to record it only means a
      // later replay re-executes, which is the pre-ADR-007 behaviour.
      reportUnavailable('setResult', err);
    }
  }

  async getResult(key: string): Promise<IdempotencyResult | null> {
    try {
      return parseResult(await getCommandClient().get(storageKey(key)));
    } catch (err) {
      reportUnavailable('getResult', err);
      return null;
    }
  }

  async waitForResult(key: string, timeoutMs: number): Promise<IdempotencyResult | null> {
    return pollForResult(this, key, timeoutMs);
  }

  async release(key: string): Promise<void> {
    try {
      await getCommandClient().del(storageKey(key));
    } catch (err) {
      reportUnavailable('release', err);
    }
  }
}

/**
 * Single-process store used by tests and by any environment without Redis.
 *
 * Correct only within one process: two server instances would each reserve the
 * same key, which is exactly what the Redis store exists to prevent.
 */
export class InMemoryIdempotencyStore implements IdempotencyStore {
  private readonly entries = new Map<string, { value: string; expiresAt: number }>();

  private read(key: string): string | null {
    const entry = this.entries.get(storageKey(key));
    if (!entry) return null;
    if (entry.expiresAt <= Date.now()) {
      this.entries.delete(storageKey(key));
      return null;
    }
    return entry.value;
  }

  async acquire(key: string, ttlMs: number): Promise<AcquireOutcome> {
    try {
      if (this.read(key) !== null) {
        return 'exists';
      }
      this.entries.set(storageKey(key), { value: IN_PROGRESS, expiresAt: Date.now() + ttlMs });
      return 'acquired';
    } catch (err) {
      reportUnavailable('acquire', err);
      return 'failed';
    }
  }

  async setResult(key: string, result: IdempotencyResult, ttlMs: number): Promise<void> {
    try {
      this.entries.set(storageKey(key), {
        value: JSON.stringify(result),
        expiresAt: Date.now() + ttlMs,
      });
    } catch (err) {
      reportUnavailable('setResult', err);
    }
  }

  async getResult(key: string): Promise<IdempotencyResult | null> {
    try {
      return parseResult(this.read(key));
    } catch (err) {
      reportUnavailable('getResult', err);
      return null;
    }
  }

  async waitForResult(key: string, timeoutMs: number): Promise<IdempotencyResult | null> {
    return pollForResult(this, key, timeoutMs);
  }

  async release(key: string): Promise<void> {
    try {
      this.entries.delete(storageKey(key));
    } catch (err) {
      reportUnavailable('release', err);
    }
  }
}

/**
 * Shared polling loop: both stores wait the same way, only their reads differ.
 * `getResult` already absorbs its own failures, so this never throws either.
 */
async function pollForResult(
  store: IdempotencyStore,
  key: string,
  timeoutMs: number
): Promise<IdempotencyResult | null> {
  const deadline = Date.now() + timeoutMs;

  for (;;) {
    const result = await store.getResult(key);
    if (result) return result;
    if (Date.now() >= deadline) return null;
    await delay(POLL_INTERVAL_MS);
  }
}

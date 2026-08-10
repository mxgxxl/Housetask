import { getRedis } from '../config/redis';
import { sha256 } from '../utils/hash';

/** A captured response, replayed verbatim for a repeated Idempotency-Key. */
export interface IdempotencyResult {
  status: number;
  body: unknown;
}

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
 */
export interface IdempotencyStore {
  /** Reserve a key. 'acquired' means this caller owns the operation. */
  acquire(key: string, ttlMs: number): Promise<'acquired' | 'exists'>;
  /** Publish the finished response for replay. */
  setResult(key: string, result: IdempotencyResult, ttlMs: number): Promise<void>;
  /** Finished response, or null when unknown or still in progress. */
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
 * Production store. `SET key <marker> NX PX ttl` is the atomic reservation, so
 * exactly one of N racing requests proceeds even across server instances.
 */
export class RedisIdempotencyStore implements IdempotencyStore {
  async acquire(key: string, ttlMs: number): Promise<'acquired' | 'exists'> {
    const result = await getRedis().set(storageKey(key), IN_PROGRESS, 'PX', ttlMs, 'NX');
    return result === 'OK' ? 'acquired' : 'exists';
  }

  async setResult(key: string, result: IdempotencyResult, ttlMs: number): Promise<void> {
    await getRedis().set(storageKey(key), JSON.stringify(result), 'PX', ttlMs);
  }

  async getResult(key: string): Promise<IdempotencyResult | null> {
    return parseResult(await getRedis().get(storageKey(key)));
  }

  async waitForResult(key: string, timeoutMs: number): Promise<IdempotencyResult | null> {
    return pollForResult(this, key, timeoutMs);
  }

  async release(key: string): Promise<void> {
    await getRedis().del(storageKey(key));
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

  async acquire(key: string, ttlMs: number): Promise<'acquired' | 'exists'> {
    if (this.read(key) !== null) {
      return 'exists';
    }
    this.entries.set(storageKey(key), { value: IN_PROGRESS, expiresAt: Date.now() + ttlMs });
    return 'acquired';
  }

  async setResult(key: string, result: IdempotencyResult, ttlMs: number): Promise<void> {
    this.entries.set(storageKey(key), {
      value: JSON.stringify(result),
      expiresAt: Date.now() + ttlMs,
    });
  }

  async getResult(key: string): Promise<IdempotencyResult | null> {
    return parseResult(this.read(key));
  }

  async waitForResult(key: string, timeoutMs: number): Promise<IdempotencyResult | null> {
    return pollForResult(this, key, timeoutMs);
  }

  async release(key: string): Promise<void> {
    this.entries.delete(storageKey(key));
  }
}

/**
 * Shared polling loop: both stores wait the same way, only their reads differ.
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

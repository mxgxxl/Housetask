import { createHash } from 'node:crypto';

/**
 * Hash a value with SHA-256 and return it as lowercase hex.
 *
 * Intended for high-entropy secrets we must be able to look up by exact value
 * — refresh tokens, idempotency keys — where the goal is "a database leak
 * yields nothing usable", not "resist brute force". Passwords must keep using
 * bcrypt: they are low-entropy and need the key stretching that SHA-256
 * deliberately lacks.
 *
 * @param input The value to hash.
 * @returns 64-character lowercase hex digest.
 */
export function sha256(input: string): string {
  return createHash('sha256').update(input).digest('hex');
}

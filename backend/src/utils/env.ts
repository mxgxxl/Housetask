/**
 * Minimum length for the JWT signing secrets. Short secrets are brute-forceable
 * offline, and a leaked signing key means forged access tokens for every user.
 */
const MIN_SECRET_LENGTH = 32;

/**
 * Validate the environment required to run in production and fail fast.
 *
 * A misconfigured production boot is far more dangerous than a crashed one:
 * an empty `CORS_ORIGINS` silently degrades to `*` (Hard Rule 15), and a
 * default JWT secret makes every token forgeable. Crashing at startup turns
 * both into a visible deploy failure instead of a silent vulnerability.
 *
 * No-op unless `NODE_ENV === 'production'`, so development and tests keep
 * working with an empty environment.
 *
 * @throws Error listing every missing or invalid variable.
 */
export function validateProductionEnv(): void {
  if (process.env.NODE_ENV !== 'production') {
    return;
  }

  const problems: string[] = [];

  if (!process.env.CORS_ORIGINS?.trim()) {
    problems.push('CORS_ORIGINS must be set to a non-empty list of allowed origins');
  }

  if (!process.env.MONGODB_URI?.trim()) {
    problems.push('MONGODB_URI must be set');
  }

  for (const name of ['JWT_SECRET', 'JWT_REFRESH_SECRET'] as const) {
    const value = process.env[name]?.trim() ?? '';
    if (value.length < MIN_SECRET_LENGTH) {
      problems.push(`${name} must be set and at least ${MIN_SECRET_LENGTH} characters long`);
    }
  }

  // TD-052 (2026-08-17): each secret's length was validated independently,
  // but nothing asserted they DIFFER. If a deploy sets both to the same
  // value, a refresh token verifies fine as an access token too (both are
  // just HMAC-signed with the same key), and authMiddleware would populate
  // req.user from it — turning a 7-day refresh token into a 7-day bearer
  // credential for the whole API instead of the intended 15-minute access
  // token. Both secrets are already known non-empty by this point iff
  // neither pushed a length problem above.
  const jwtSecret = process.env.JWT_SECRET?.trim() ?? '';
  const jwtRefreshSecret = process.env.JWT_REFRESH_SECRET?.trim() ?? '';
  if (jwtSecret && jwtRefreshSecret && jwtSecret === jwtRefreshSecret) {
    problems.push('JWT_SECRET and JWT_REFRESH_SECRET must not be the same value');
  }

  if (problems.length > 0) {
    throw new Error(`Invalid production environment:\n  - ${problems.join('\n  - ')}`);
  }
}

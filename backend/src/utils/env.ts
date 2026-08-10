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

  if (problems.length > 0) {
    throw new Error(`Invalid production environment:\n  - ${problems.join('\n  - ')}`);
  }
}

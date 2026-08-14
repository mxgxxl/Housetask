import { z } from 'zod';

// Mirrors auth.controller.ts's EMAIL_REGEX exactly (not Zod's built-in
// z.email(), which uses a different, more restrictive pattern) — swapping
// regexes could reject or accept different edge-case strings than today,
// which this TD is not the place to relitigate.
const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Mirrors auth.service.ts's MAX_NAME_LENGTH.
const MAX_NAME_LENGTH = 100;

const email = z
  .string({ error: 'A valid email is required' })
  .regex(EMAIL_REGEX, 'A valid email is required');

const name = z
  .string({ error: 'Name is required' })
  .trim()
  .min(1, 'Name is required')
  .max(MAX_NAME_LENGTH, `Name must be at most ${MAX_NAME_LENGTH} characters`);

/**
 * POST /api/auth/register body. Fields are email/password/name — there is
 * no `username` anywhere in this codebase (the User model only has
 * `email`), and register does not create a household in the same call (no
 * `householdName`); household creation is the separate POST /api/households.
 */
export const registerSchema = z.object({
  email,
  password: z
    .string({ error: 'Password must be at least 6 characters' })
    .min(6, 'Password must be at least 6 characters'),
  name,
});

/**
 * POST /api/auth/login body. Deliberately does NOT reuse registerSchema's
 * password (min 6): login's password only needs to reach the bcrypt
 * compare and get a generic 401 either way (Hard Rule 2 — same message for
 * "wrong password" and "unknown email"), so enforcing a min-length here
 * would let a short-but-wrong guess be distinguished (400) from a
 * correctly-shaped-but-wrong one (401) — a real behavior change this TD
 * doesn't need. Email format IS validated (tightened from the current
 * `typeof === 'string'`-only check): it fails fast on malformed syntax
 * without ever confirming a specific account exists, so it doesn't weaken
 * Hard Rule 2's account-enumeration protection.
 */
export const loginSchema = z.object({
  email,
  password: z.string({ error: 'Password is required' }).min(1, 'Password is required'),
});

/**
 * POST /api/auth/refresh and POST /api/auth/logout both take { refreshToken
 * }. This only checks the field is a non-empty string — NOT that it looks
 * like a JWT — so a syntactically garbage token still reaches
 * authService.refresh/logout and gets that service's own 401, exactly as
 * today (see auth.test.ts's "should return 401 for a syntactically invalid
 * refresh token").
 */
export const refreshTokenSchema = z.object({
  refreshToken: z
    .string({ error: 'Refresh token is required' })
    .min(1, 'Refresh token is required'),
});

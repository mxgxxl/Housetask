import bcrypt from 'bcryptjs';
import { Types } from 'mongoose';
import { UserModel, IUser } from '../models/User';
import { RefreshTokenModel } from '../models/RefreshToken';
import { signAccessToken, signRefreshToken, verifyRefreshToken } from '../utils/jwt';
import { sha256 } from '../utils/hash';
import { sanitizeString } from '../utils/sanitize';
import { logger } from '../utils/logger';
import { captureSecurityWarning } from '../utils/sentry';
import { AppError } from '../middleware/error.middleware';

const BCRYPT_ROUNDS = 10;
const MAX_NAME_LENGTH = 100;
const REFRESH_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days

// TD-053 (2026-08-17): a fixed dummy hash `login` compares against when no
// user matches, so an unregistered email pays the same bcrypt.compare cost
// (~100ms at BCRYPT_ROUNDS) as a wrong password on a real account. Without
// this, `login` returned as soon as `findOne` missed, and the response-time
// gap alone let an attacker distinguish a registered email from an
// unregistered one even though the status code and message are identical
// (Hard Rule 2). Computed once at module load — the hash itself is not a
// secret, only used for timing parity, so a fixed plaintext is fine.
const DUMMY_PASSWORD_HASH = bcrypt.hashSync('td-053-timing-parity-dummy', BCRYPT_ROUNDS);

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
}

export interface PublicUser {
  id: string;
  email: string;
  name: string;
  avatarUrl?: string;
  households: string[];
}

/**
 * Strip a user document down to the fields safe to return to clients.
 */
export function toPublicUser(user: IUser): PublicUser {
  return {
    id: user._id.toString(),
    email: user.email,
    name: user.name,
    avatarUrl: user.avatarUrl,
    households: (user.households || []).map((h) => h.toString()),
  };
}

/**
 * Generate a fresh access/refresh token pair and persist the refresh token
 * so it can be verified and revoked later.
 */
async function generateTokens(userId: string, email: string): Promise<TokenPair> {
  const accessToken = signAccessToken({ userId, email });

  const tokenId = new Types.ObjectId();
  const refreshToken = signRefreshToken({ userId, tokenId: tokenId.toString() });

  await RefreshTokenModel.create({
    _id: tokenId,
    // Only the digest is persisted: a dump of this collection must not hand an
    // attacker working sessions (TD-023).
    token: sha256(refreshToken),
    userId: new Types.ObjectId(userId),
    expiresAt: new Date(Date.now() + REFRESH_TTL_MS),
  });

  return { accessToken, refreshToken };
}

/**
 * Register a new user. Hashes the password with bcrypt and returns the
 * public user plus a fresh token pair.
 */
export async function register(
  email: string,
  password: string,
  name: string,
): Promise<{ user: PublicUser; tokens: TokenPair }> {
  const normalizedEmail = email.toLowerCase().trim();

  const existing = await UserModel.findOne({ email: normalizedEmail }).lean();
  if (existing) {
    // Generic message: do not confirm whether the email is registered.
    throw new AppError('Unable to register with the provided details', 400);
  }

  const hashed = await bcrypt.hash(password, BCRYPT_ROUNDS);
  const user = await UserModel.create({
    email: normalizedEmail,
    password: hashed,
    name: sanitizeString(name, MAX_NAME_LENGTH, 'Name'),
  });

  const tokens = await generateTokens(user._id.toString(), user.email);
  return { user: toPublicUser(user), tokens };
}

/**
 * Authenticate a user. Uses a generic error for both "no such user" and
 * "wrong password" so the endpoint never reveals whether an email exists.
 */
export async function login(
  email: string,
  password: string,
): Promise<{ user: PublicUser; tokens: TokenPair }> {
  const normalizedEmail = email.toLowerCase().trim();

  // password has select:false, so request it explicitly here.
  const user = await UserModel.findOne({ email: normalizedEmail }).select('+password');
  if (!user) {
    // TD-053: pay the same bcrypt cost a real user's wrong-password branch
    // pays below, so response latency cannot reveal whether the email is
    // registered.
    await bcrypt.compare(password, DUMMY_PASSWORD_HASH);
    throw new AppError('Invalid credentials', 401);
  }

  const matches = await bcrypt.compare(password, user.password);
  if (!matches) {
    throw new AppError('Invalid credentials', 401);
  }

  const tokens = await generateTokens(user._id.toString(), user.email);
  return { user: toPublicUser(user), tokens };
}

/**
 * Revoke refresh tokens belonging to a user, ending their session(s). Used
 * when a replayed (already-rotated) token is detected.
 *
 * `createdBefore`, when given, scopes the revocation to tokens that already
 * existed when the triggering request started (TD-050, owner-approved
 * Option A, 2026-08-17): it excludes the brand-new row a concurrent,
 * legitimate rotation may have just created a few milliseconds earlier in
 * the same race, so an ordinary concurrent refresh (client retry, two
 * in-flight requests after a 401) no longer logs the user out. A genuine
 * replay — the stolen token used well after the legitimate rotation — still
 * predates the replaying request, so it is still caught. Omit it for
 * tampering (signature/userId mismatch, see `refresh`), which is not a race
 * and must still purge every token unconditionally.
 */
async function revokeAllUserTokens(userId: string, createdBefore?: Date): Promise<void> {
  await RefreshTokenModel.deleteMany({
    userId: new Types.ObjectId(userId),
    ...(createdBefore ? { createdAt: { $lt: createdBefore } } : {}),
  });
}

/**
 * Rotate tokens. Verifies the refresh JWT, confirms a matching DB record
 * exists, deletes it, and issues a new pair (rotation prevents reuse).
 *
 * Replay handling: a token with a valid signature but no DB row has already
 * been rotated, so every token in that user's family that predates this
 * request is revoked (TD-050 narrowed this from "entire family" to "family
 * as of when this request started", so a concurrent legitimate rotation's
 * brand-new token survives). A token whose signature does not verify is
 * simply rejected — an attacker must never be able to log a victim out by
 * posting garbage with their user id.
 */
export async function refresh(refreshToken: string): Promise<TokenPair> {
  // Captured before any async work (TD-050, 2026-08-17): the reference point
  // for the concurrency-safe revocation filter below — see
  // revokeAllUserTokens's doc comment for why this must be a "before this
  // request began" timestamp rather than, say, the time the missing-row
  // check runs.
  const requestStartedAt = new Date();

  let payload: { userId: string; tokenId: string };
  try {
    payload = verifyRefreshToken(refreshToken);
  } catch {
    throw new AppError('Invalid or expired refresh token', 401);
  }

  // Rotate atomically: the delete IS the claim. A separate find-then-delete
  // lets two concurrent requests carrying the same token both pass the check
  // and both mint new pairs; findOneAndDelete is a single atomic operation, so
  // exactly one caller receives the document and the loser gets a 401.
  const stored = await RefreshTokenModel.findOneAndDelete({ token: sha256(refreshToken) });

  // A correctly signed token with no matching row was already rotated away —
  // i.e. someone is replaying an old token. The legitimate holder cannot tell
  // us apart from the thief, so revoke the whole family and force everyone to
  // re-authenticate; otherwise a stolen token's session would outlive the
  // rotation that was supposed to invalidate it.
  if (!stored) {
    // logger.warn is the source of truth (always recorded, no DSN required);
    // Sentry is the alert channel on top of it — the two are not redundant,
    // one is searchable history and the other pages someone.
    logger.warn('refresh-token replay detected', {
      userId: payload.userId,
      trigger: 'missing_row',
    });
    captureSecurityWarning('refresh-token replay detected', {
      userId: payload.userId,
      trigger: 'missing_row',
    });
    await revokeAllUserTokens(payload.userId, requestStartedAt);
    throw new AppError('Invalid or expired refresh token', 401);
  }

  // Signature says one user, the stored row says another: tampering, not a
  // race — the mismatch is inherent in the token, not a timing artifact, so
  // this branch keeps the unconditional full-family revocation. Same
  // response, same revocation.
  if (stored.userId.toString() !== payload.userId) {
    logger.warn('refresh-token replay detected', {
      userId: payload.userId,
      trigger: 'user_mismatch',
    });
    captureSecurityWarning('refresh-token replay detected', {
      userId: payload.userId,
      trigger: 'user_mismatch',
    });
    await revokeAllUserTokens(payload.userId);
    throw new AppError('Invalid or expired refresh token', 401);
  }

  const user = await UserModel.findById(payload.userId).lean();
  if (!user) {
    throw new AppError('Invalid or expired refresh token', 401);
  }

  return generateTokens(user._id.toString(), user.email);
}

/**
 * Invalidate a refresh token (logout). Idempotent: succeeds even if the
 * token was already removed.
 */
export async function logout(refreshToken: string): Promise<void> {
  await RefreshTokenModel.deleteOne({ token: sha256(refreshToken) });
}

/**
 * Fetch the current user's public profile by id.
 */
export async function getMe(userId: string): Promise<PublicUser> {
  const user = await UserModel.findById(userId);
  if (!user) {
    throw new AppError('User not found', 404);
  }
  return toPublicUser(user);
}

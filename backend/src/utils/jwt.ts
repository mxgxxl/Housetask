import jwt, { SignOptions } from 'jsonwebtoken';
import { JwtAccessPayload, JwtRefreshPayload } from '../types';

const JWT_SECRET = process.env.JWT_SECRET || 'dev_access_secret_change_me_please_min_32_chars';
const JWT_REFRESH_SECRET =
  process.env.JWT_REFRESH_SECRET || 'dev_refresh_secret_change_me_please_min_32_chars';

const ACCESS_EXPIRES = process.env.JWT_ACCESS_EXPIRES || '15m';
const REFRESH_EXPIRES = process.env.JWT_REFRESH_EXPIRES || '7d';

/**
 * Sign a short-lived access token.
 * @param payload userId + email of the authenticated user.
 * @returns Signed JWT string (expires in 15 minutes by default).
 */
export function signAccessToken(payload: JwtAccessPayload): string {
  const options: SignOptions = { expiresIn: ACCESS_EXPIRES as SignOptions['expiresIn'] };
  return jwt.sign(payload, JWT_SECRET, options);
}

/**
 * Sign a long-lived refresh token. The `tokenId` links the JWT to a
 * RefreshToken document in the DB so it can be revoked.
 * @param payload userId + tokenId (the RefreshToken document id).
 * @returns Signed JWT string (expires in 7 days by default).
 */
export function signRefreshToken(payload: JwtRefreshPayload): string {
  const options: SignOptions = { expiresIn: REFRESH_EXPIRES as SignOptions['expiresIn'] };
  return jwt.sign(payload, JWT_REFRESH_SECRET, options);
}

/**
 * Verify and decode an access token. Throws if invalid/expired.
 */
export function verifyAccessToken(token: string): JwtAccessPayload {
  return jwt.verify(token, JWT_SECRET) as JwtAccessPayload;
}

/**
 * Verify and decode a refresh token. Throws if invalid/expired.
 */
export function verifyRefreshToken(token: string): JwtRefreshPayload {
  return jwt.verify(token, JWT_REFRESH_SECRET) as JwtRefreshPayload;
}

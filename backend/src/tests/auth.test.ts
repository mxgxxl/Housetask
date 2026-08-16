import { Server } from 'http';
import request from 'supertest';
import jwt from 'jsonwebtoken';
import bcrypt from 'bcryptjs';

import { RefreshTokenModel } from '../models/RefreshToken';
import { logger } from '../utils/logger';
import { buildTestApp } from './setup';
import { createTestUser } from './helpers';

let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

describe('POST /api/auth/register', () => {
  it('should return 201 with an access and refresh token pair when the payload is valid', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'new@test.com', password: 'password123', name: 'New User' });

    expect(res.status).toBe(201);
    expect(res.body.success).toBe(true);
    expect(typeof res.body.data.tokens.accessToken).toBe('string');
    expect(typeof res.body.data.tokens.refreshToken).toBe('string');
    expect(res.body.data.user.email).toBe('new@test.com');
  });

  it('should never return the password hash in the response', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'nopass@test.com', password: 'password123', name: 'No Pass' });

    expect(res.status).toBe(201);
    expect(JSON.stringify(res.body)).not.toContain('password123');
    expect(res.body.data.user.password).toBeUndefined();
  });

  it('should reject a duplicate email with a generic message that does not reveal the account exists', async () => {
    await createTestUser(app, { email: 'dup@test.com' });

    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'dup@test.com', password: 'password123', name: 'Duplicate' });

    // Hard Rule 2: the response must not confirm the email is registered, so
    // this is a generic 400 rather than a 409 Conflict.
    expect(res.status).toBe(400);
    expect(res.body.success).toBe(false);
    expect(res.body.error).toBe('Unable to register with the provided details');
    expect(res.body.error.toLowerCase()).not.toContain('exist');
  });

  it('should return 400 when the password is shorter than 6 characters', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'short@test.com', password: '12345', name: 'Short' });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Password must be at least 6 characters');
  });

  it('should persist the refresh token as a SHA-256 digest, never in the clear', async () => {
    const user = await createTestUser(app, { email: 'hashed@test.com' });

    const stored = await RefreshTokenModel.findOne({}).lean();

    expect(stored).not.toBeNull();
    // A dump of this collection must be worthless to an attacker (TD-023).
    expect(stored!.token).not.toBe(user.refreshToken);
    expect(stored!.token).toMatch(/^[a-f0-9]{64}$/);
  });

  it('should return 400 when the email is not a valid address', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'not-an-email', password: 'password123', name: 'Invalid' });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('A valid email is required');
  });
});

describe('Zod edge validation on auth endpoints (TD-028)', () => {
  it('should return 400 with a clear message when name is missing on register', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'noname@test.com', password: 'password123' });

    expect(res.status).toBe(400);
    expect(res.body.success).toBe(false);
    expect(res.body.error).toBe('Name is required');
  });

  it('should return 400 when the register name exceeds 100 characters', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'longname@test.com', password: 'password123', name: 'x'.repeat(101) });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Name must be at most 100 characters');
  });

  it('should return 400 (not a 500) when register email is not a string', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 12345, password: 'password123', name: 'Numeric email' });

    expect(res.status).toBe(400);
    expect(res.body.success).toBe(false);
  });

  it('should return 400 for a malformed email on login (tightened: was accepted and 401ed before)', async () => {
    // Deliberate tightening (TD-028): login previously only checked
    // `typeof email === 'string'`, so a syntactically invalid email reached
    // authService.login and came back 401 'Invalid credentials' (the same
    // generic path as an unknown-but-valid-looking email). Rejecting the
    // syntax up front with 400 is safe under Hard Rule 2: it never confirms
    // whether any SPECIFIC address is registered, it only checks shape.
    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'not-an-email', password: 'whatever' });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('A valid email is required');
  });

  it('should return 400 with a clear message when password is missing on login', async () => {
    const res = await request(app).post('/api/auth/login').send({ email: 'missing@test.com' });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Password is required');
  });

  it('should return 400 with a clear message when refreshToken is missing', async () => {
    const refreshRes = await request(app).post('/api/auth/refresh').send({});
    expect(refreshRes.status).toBe(400);
    expect(refreshRes.body.error).toBe('Refresh token is required');

    const logoutRes = await request(app).post('/api/auth/logout').send({});
    expect(logoutRes.status).toBe(400);
    expect(logoutRes.body.error).toBe('Refresh token is required');
  });
});

describe('malformed request bodies', () => {
  it('should answer 400 with the standard envelope for malformed JSON, never 500', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .set('Content-Type', 'application/json')
      .send('{invalid');

    expect(res.status).toBe(400);
    expect(res.body.success).toBe(false);
    expect(res.body.error).toBe('Invalid JSON payload');
  });
});

describe('POST /api/auth/login', () => {
  it('should return 200 with a fresh token pair for valid credentials', async () => {
    const user = await createTestUser(app, { email: 'login@test.com' });

    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: user.email, password: user.password });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(typeof res.body.data.tokens.accessToken).toBe('string');
    expect(res.body.data.user.id).toBe(user.id);
  });

  it('should return 401 for a wrong password and 401 with the EXACT same message for an unknown email', async () => {
    const user = await createTestUser(app, { email: 'known@test.com' });

    const wrongPassword = await request(app)
      .post('/api/auth/login')
      .send({ email: user.email, password: 'totally-wrong' });

    const unknownEmail = await request(app)
      .post('/api/auth/login')
      .send({ email: 'ghost@test.com', password: 'totally-wrong' });

    expect(wrongPassword.status).toBe(401);
    expect(unknownEmail.status).toBe(401);
    // Hard Rule 2: identical status AND identical message, otherwise the
    // endpoint becomes an account-enumeration oracle.
    expect(unknownEmail.body.error).toBe(wrongPassword.body.error);
    expect(wrongPassword.body.error).toBe('Invalid credentials');
  });

  it('should run a bcrypt.compare against a dummy hash on an unknown email, for timing parity (TD-053)', async () => {
    const compareSpy = jest.spyOn(bcrypt, 'compare');

    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: 'never-registered@test.com', password: 'whatever123' });

    expect(res.status).toBe(401);
    // Without this, the miss path returns immediately after the failed
    // findOne — no bcrypt.compare call at all — while a wrong-password hit
    // pays a full compare below. That gap is what let response latency
    // leak whether an email is registered, even though the status and
    // message are identical (Hard Rule 2, covered by the test above).
    expect(compareSpy).toHaveBeenCalledTimes(1);

    compareSpy.mockRestore();
  });
});

describe('POST /api/auth/refresh', () => {
  it('should rotate the refresh token so the previous one can never be used twice', async () => {
    const user = await createTestUser(app);

    const first = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: user.refreshToken });

    expect(first.status).toBe(200);
    expect(first.body.data.refreshToken).not.toBe(user.refreshToken);

    const replay = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: user.refreshToken });

    expect(replay.status).toBe(401);
    expect(replay.body.error).toBe('Invalid or expired refresh token');
  });

  it('should let exactly one of two concurrent refreshes with the same token succeed', async () => {
    const user = await createTestUser(app);

    const [a, b] = await Promise.all([
      request(app).post('/api/auth/refresh').send({ refreshToken: user.refreshToken }),
      request(app).post('/api/auth/refresh').send({ refreshToken: user.refreshToken }),
    ]);

    const statuses = [a.status, b.status].sort();
    // Rotation must be atomic: a find-then-delete would hand both callers a
    // valid new pair, silently doubling the session.
    expect(statuses).toEqual([200, 401]);

    const winner = a.status === 200 ? a : b;
    expect(typeof winner.body.data.accessToken).toBe('string');
  });

  it('should return 401 for a syntactically invalid refresh token', async () => {
    const res = await request(app).post('/api/auth/refresh').send({ refreshToken: 'garbage' });

    expect(res.status).toBe(401);
  });

  it('should emit a security log naming the user when it revokes a family', async () => {
    const user = await createTestUser(app);
    const warn = jest.spyOn(logger, 'warn').mockImplementation(() => undefined);

    try {
      await request(app).post('/api/auth/refresh').send({ refreshToken: user.refreshToken });
      await request(app).post('/api/auth/refresh').send({ refreshToken: user.refreshToken });

      // The audit hook Sentry will attach to (TD-009): a successful token theft
      // must not be invisible in the logs.
      expect(warn).toHaveBeenCalledWith('refresh-token replay detected', {
        userId: user.id,
        trigger: 'missing_row',
      });
    } finally {
      warn.mockRestore();
    }
  });

  it('should revoke the whole token family when an already-rotated token is replayed', async () => {
    const user = await createTestUser(app);

    // Legitimate rotation.
    const rotated = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: user.refreshToken });
    expect(rotated.status).toBe(200);
    const freshToken = rotated.body.data.refreshToken as string;

    // A thief replays the token that rotation already consumed. This is a
    // SEQUENTIAL replay (awaited after `rotated` fully completed), so
    // `freshToken`'s row was created before this replay request started —
    // TD-050's createdAt filter still catches it. This is deliberately
    // distinct from the concurrent-refresh case below, where the winner's
    // new token is created AFTER the losing requests started and must
    // survive.
    const replay = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: user.refreshToken });
    expect(replay.status).toBe(401);
    expect(replay.body.error).toBe('Invalid or expired refresh token');

    // The replay must also kill the token handed out by the legitimate
    // rotation — we cannot tell victim from thief, so every session dies and
    // the real user re-authenticates.
    const afterRevocation = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: freshToken });
    expect(afterRevocation.status).toBe(401);
  });

  it('should NOT log the user out when the same token is submitted by concurrent refresh requests (TD-050)', async () => {
    const user = await createTestUser(app);

    // Simulates a mobile client that retries a refresh after a slow/timed-out
    // response (the first attempt already succeeded server-side) or fires two
    // in-flight requests off the back of separate 401s: several requests
    // race with the SAME still-valid token. Exactly one wins the atomic
    // rotation; the rest see a "missing row" and, pre-TD-050, would have
    // nuked the winner's brand-new token too.
    const results = await Promise.all([
      request(app).post('/api/auth/refresh').send({ refreshToken: user.refreshToken }),
      request(app).post('/api/auth/refresh').send({ refreshToken: user.refreshToken }),
      request(app).post('/api/auth/refresh').send({ refreshToken: user.refreshToken }),
    ]);

    const winners = results.filter((r) => r.status === 200);
    const losers = results.filter((r) => r.status === 401);
    expect(winners.length).toBe(1);
    expect(losers.length).toBe(results.length - 1);

    // The winner's new refresh token must still be redeemable — no phantom
    // logout from the losing requests' replay-revocation branch.
    const winnerNewRefreshToken = winners[0].body.data.refreshToken as string;
    const followUp = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: winnerNewRefreshToken });
    expect(followUp.status).toBe(200);

    // DB-level assertion of the createdAt filter itself: only the winner's
    // token (created after every request in the race started) should be
    // left for this user — the old tokens the losers targeted are gone, but
    // nothing created during the race was swept up with them.
    const remaining = await RefreshTokenModel.countDocuments({ userId: user.id });
    expect(remaining).toBe(1);
  });

  it('should NOT revoke anything when the replayed token has an invalid signature', async () => {
    const user = await createTestUser(app);

    // Well-formed JWT shape but signed with the wrong key.
    const forged = `${user.refreshToken.split('.')[0]}.${user.refreshToken.split('.')[1]}.forged`;
    const res = await request(app).post('/api/auth/refresh').send({ refreshToken: forged });
    expect(res.status).toBe(401);

    // Otherwise anyone could log any user out by posting garbage on their behalf.
    const stillValid = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: user.refreshToken });
    expect(stillValid.status).toBe(200);
  });

  it('should reject a refresh token signed with a different algorithm, even with a valid HMAC key (TD-051)', async () => {
    const user = await createTestUser(app);

    // Same secret jwt.ts falls back to under NODE_ENV=test, same claims
    // shape, but signed HS384 instead of the pinned HS512... any algorithm
    // other than the pinned HS256 must be rejected outright, regardless of
    // whether the secret is otherwise correct.
    const wrongAlgToken = jwt.sign(
      { userId: user.id, tokenId: 'does-not-matter' },
      'test_refresh_secret_at_least_32_characters',
      { algorithm: 'HS384', expiresIn: '7d' },
    );

    const res = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: wrongAlgToken });
    expect(res.status).toBe(401);
  });
});

describe('GET /api/auth/me', () => {
  it('should reject an access token signed with a different algorithm, even with a valid HMAC key (TD-051)', async () => {
    const user = await createTestUser(app);

    const wrongAlgToken = jwt.sign(
      { userId: user.id, email: user.email },
      'test_access_secret_at_least_32_characters',
      { algorithm: 'HS384', expiresIn: '15m' },
    );

    const res = await request(app)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${wrongAlgToken}`);
    expect(res.status).toBe(401);

    // Sanity check the setup itself: a correctly signed (HS256, the pinned
    // default) token for the same user must still be accepted.
    const stillValid = await request(app)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${user.accessToken}`);
    expect(stillValid.status).toBe(200);
  });
});

describe('POST /api/auth/logout', () => {
  it('should invalidate the refresh token so it can no longer be redeemed', async () => {
    const user = await createTestUser(app);

    const logout = await request(app)
      .post('/api/auth/logout')
      .send({ refreshToken: user.refreshToken });
    expect(logout.status).toBe(200);

    const afterLogout = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: user.refreshToken });

    expect(afterLogout.status).toBe(401);
  });
});

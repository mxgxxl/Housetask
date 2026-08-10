import { Server } from 'http';
import request from 'supertest';

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

  it('should return 400 when the email is not a valid address', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ email: 'not-an-email', password: 'password123', name: 'Invalid' });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('A valid email is required');
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

  it('should revoke the whole token family when an already-rotated token is replayed', async () => {
    const user = await createTestUser(app);

    // Legitimate rotation.
    const rotated = await request(app)
      .post('/api/auth/refresh')
      .send({ refreshToken: user.refreshToken });
    expect(rotated.status).toBe(200);
    const freshToken = rotated.body.data.refreshToken as string;

    // A thief replays the token that rotation already consumed.
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

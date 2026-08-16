import { Server } from 'http';
import request from 'supertest';

import { buildTestApp } from './setup';

describe('Global API rate limiting (TD-006)', () => {
  let app: Server;

  beforeAll(async () => {
    // The rest of the suite runs with this limiter off (see CreateAppOptions);
    // this app opts back in so the limit itself is covered, same pattern as
    // rate-limit.test.ts does for the auth-specific limiter.
    app = await buildTestApp({ globalRateLimit: true });
  });

  it('should reject the 101st request within the window with a 429 envelope', async () => {
    // GET /api/households/:id without a token fails fast on authMiddleware
    // (no DB round-trip), so 100+ requests stay quick.
    const attempt = (): Promise<request.Response> => request(app).get('/api/households/anything');

    for (let i = 0; i < 100; i++) {
      const res = await attempt();
      expect(res.status).toBe(401);
    }

    const blocked = await attempt();

    expect(blocked.status).toBe(429);
    expect(blocked.body.success).toBe(false);
    expect(blocked.body.error).toBe('Too many requests from this IP');
  }, 30_000);

  it('should not count credential endpoints against the global limiter', async () => {
    // authRateLimit stays off by default (see CreateAppOptions), so this
    // exercises only the global limiter's `skip`, not the auth-specific one.
    const attempt = (): Promise<request.Response> =>
      request(app)
        .post('/api/auth/login')
        .send({ email: 'nobody@test.com', password: 'whatever' });

    for (let i = 0; i < 100; i++) {
      const res = await attempt();
      expect(res.status).toBe(401);
    }

    // A 101st /api/auth/login request is still answered on its own merits
    // (401, bad credentials) rather than 429 from the global limiter — it has
    // its own stricter 5/15min limiter instead (auth.routes.ts).
    const stillNotGlobalLimited = await attempt();
    expect(stillNotGlobalLimited.status).toBe(401);
  }, 30_000);
});

describe('Global rate limiting covers the auth endpoints that have no limiter of their own', () => {
  // Its own app (and therefore its own limiter counter) so the 100 requests
  // the describe above already spent against the shared 127.0.0.1 key cannot
  // make this pass for the wrong reason.
  let app: Server;

  beforeAll(async () => {
    app = await buildTestApp({ globalRateLimit: true });
  });

  it('should rate-limit POST /api/auth/refresh, which carries no limiter of its own', async () => {
    // A garbage token fails on signature verification before any DB access,
    // so these stay fast — and they exercise the limiter, not the DB.
    const attempt = (): Promise<request.Response> =>
      request(app).post('/api/auth/refresh').send({ refreshToken: 'garbage' });

    for (let i = 0; i < 100; i++) {
      const res = await attempt();
      expect(res.status).toBe(401);
    }

    // Before this was fixed the global limiter's `skip` exempted the whole
    // `/api/auth` prefix, leaving /refresh and /logout as the only entirely
    // unbounded routes in the API — this 101st request answered 401 forever.
    const blocked = await attempt();

    expect(blocked.status).toBe(429);
    expect(blocked.body.success).toBe(false);
    expect(blocked.body.error).toBe('Too many requests from this IP');
  }, 30_000);
});

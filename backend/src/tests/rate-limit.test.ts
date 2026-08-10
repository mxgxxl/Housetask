import { Server } from 'http';
import request from 'supertest';

import { buildTestApp } from './setup';

let app: Server;

beforeAll(async () => {
  // The rest of the suite runs with the limiter off (see CreateAppOptions);
  // this app opts back in so the limit itself is covered.
  app = await buildTestApp({ authRateLimit: true });
});

describe('auth rate limiting', () => {
  it('should reject the 6th credential attempt within the window with a 429 envelope', async () => {
    const attempt = (): Promise<request.Response> =>
      request(app).post('/api/auth/login').send({ email: 'nobody@test.com', password: 'whatever' });

    // The window allows 5; all of these are rejected on credentials (401).
    for (let i = 0; i < 5; i++) {
      const res = await attempt();
      expect(res.status).toBe(401);
    }

    const blocked = await attempt();

    expect(blocked.status).toBe(429);
    expect(blocked.body.success).toBe(false);
    expect(typeof blocked.body.error).toBe('string');
    expect(blocked.body.error).toBe('Too many attempts, please try again later');
  });
});

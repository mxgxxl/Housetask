import { Server } from 'http';
import request from 'supertest';

import {
  AcquireOutcome,
  IdempotencyResult,
  IdempotencyStore,
  RedisIdempotencyStore,
} from '../services/idempotency.store';
import { buildTestApp } from './setup';
import {
  TestHousehold,
  TestUser,
  authHeader,
  createTestHousehold,
  createTestUser,
} from './helpers';

let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

async function setupHousehold(): Promise<{ user: TestUser; household: TestHousehold }> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  return { user, household };
}

describe('Idempotency-Key on task creation', () => {
  it('should create once and replay the stored response with HTTP 200 on repeat', async () => {
    const { user, household } = await setupHousehold();
    const url = `/api/households/${household.id}/tasks`;
    const body = { title: 'Comprar pan', priority: 'high' };

    const first = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'key-abc')
      .send(body);

    const second = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'key-abc')
      .send(body);

    expect(first.status).toBe(201);
    // The replay reports 200: nothing was created this time (ADR-007).
    expect(second.status).toBe(200);
    expect(second.body).toEqual(first.body);

    const list = await request(app)
      .get(url)
      .query({ limit: 100 })
      .set(authHeader(user.accessToken));
    expect(list.body.data.items).toHaveLength(1);
  });

  it('should resolve two simultaneous requests to a single creation, without a 409', async () => {
    const { user, household } = await setupHousehold();
    const url = `/api/households/${household.id}/tasks`;
    const send = (): Promise<request.Response> =>
      request(app)
        .post(url)
        .set(authHeader(user.accessToken))
        .set('Idempotency-Key', 'race-key')
        .send({ title: 'Tarea en carrera' });

    const [a, b] = await Promise.all([send(), send()]);

    // The reservation is taken before the handler runs, so one caller creates
    // and the other waits for its result instead of creating a duplicate.
    expect([a.status, b.status].sort()).toEqual([200, 201]);
    const created = a.status === 201 ? a : b;
    const replayed = a.status === 201 ? b : a;
    expect(replayed.body.data.id).toBe(created.body.data.id);

    const list = await request(app)
      .get(url)
      .query({ limit: 100 })
      .set(authHeader(user.accessToken));
    expect(list.body.data.items).toHaveLength(1);
  });

  it('should create separate resources for different keys', async () => {
    const { user, household } = await setupHousehold();
    const url = `/api/households/${household.id}/tasks`;

    const first = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'key-one')
      .send({ title: 'Primera' });
    const second = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'key-two')
      .send({ title: 'Segunda' });

    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(second.body.data.id).not.toBe(first.body.data.id);

    const list = await request(app)
      .get(url)
      .query({ limit: 100 })
      .set(authHeader(user.accessToken));
    expect(list.body.data.items).toHaveLength(2);
  });

  it('should behave exactly as before when no Idempotency-Key is sent', async () => {
    const { user, household } = await setupHousehold();
    const url = `/api/households/${household.id}/tasks`;

    const first = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'Sin clave' });
    const second = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'Sin clave' });

    // The header is optional during the migration window: two identical posts
    // without it still create two tasks.
    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(second.body.data.id).not.toBe(first.body.data.id);
  });

  it('should not lock the key when the original request failed', async () => {
    const { user, household } = await setupHousehold();
    const url = `/api/households/${household.id}/tasks`;

    const invalid = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'retry-key')
      .send({ title: '   ' });
    expect(invalid.status).toBe(400);

    // A rejected attempt must leave the key reusable, otherwise the client is
    // stuck with 409s for 24h after one validation error.
    const retry = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'retry-key')
      .send({ title: 'Corregida' });
    expect(retry.status).toBe(201);
  });
});

describe('Idempotency-Key on household creation', () => {
  it('should not create a second household for a repeated key', async () => {
    const user = await createTestUser(app);

    const first = await request(app)
      .post('/api/households')
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'household-key')
      .send({ name: 'Casa idempotente' });
    const second = await request(app)
      .post('/api/households')
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'household-key')
      .send({ name: 'Casa idempotente' });

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect(second.body.data.id).toBe(first.body.data.id);

    const me = await request(app).get('/api/auth/me').set(authHeader(user.accessToken));
    expect(me.body.data.households).toHaveLength(1);
  });

  it('should scope keys per user so two accounts can reuse the same string', async () => {
    const alice = await createTestUser(app);
    const bob = await createTestUser(app);

    const first = await request(app)
      .post('/api/households')
      .set(authHeader(alice.accessToken))
      .set('Idempotency-Key', 'shared-string')
      .send({ name: 'Casa de Alice' });
    const second = await request(app)
      .post('/api/households')
      .set(authHeader(bob.accessToken))
      .set('Idempotency-Key', 'shared-string')
      .send({ name: 'Casa de Bob' });

    expect(first.status).toBe(201);
    // Bob must not receive Alice's household just because the key string matched.
    expect(second.status).toBe(201);
    expect(second.body.data.id).not.toBe(first.body.data.id);
    expect(second.body.data.name).toBe('Casa de Bob');
  });
});

describe('Idempotency-Key on shopping item creation', () => {
  it('should create once and replay on repeat', async () => {
    const { user, household } = await setupHousehold();
    const url = `/api/households/${household.id}/shopping`;

    const first = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'shopping-key')
      .send({ name: 'Leche' });
    const second = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'shopping-key')
      .send({ name: 'Leche' });

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect(second.body.data.id).toBe(first.body.data.id);

    const list = await request(app)
      .get(url)
      .query({ limit: 100 })
      .set(authHeader(user.accessToken));
    expect(list.body.data.items).toHaveLength(1);
  });
});


/**
 * A store that is always unavailable — models a Redis outage or a timeout
 * exceeding commandTimeout. Every method reports failure instead of throwing,
 * exactly as the real stores do once their try/catch absorbs the error.
 */
class FaultyStore implements IdempotencyStore {
  acquireCalls = 0;

  async acquire(): Promise<AcquireOutcome> {
    this.acquireCalls++;
    return 'failed';
  }

  async setResult(): Promise<void> {}

  async getResult(): Promise<IdempotencyResult | null> {
    return null;
  }

  async waitForResult(): Promise<IdempotencyResult | null> {
    return null;
  }

  async release(): Promise<void> {}
}

/** A store whose acquire never resolves in time, i.e. a hung Redis command. */
class SlowStore extends FaultyStore {

  async acquire(): Promise<AcquireOutcome> {
    this.acquireCalls++;
    // The real client rejects after commandTimeout; the store's catch turns
    // that into 'failed'. Simulated here so the test needs no Redis.
    await new Promise((resolve) => setTimeout(resolve, 30));
    return 'failed';
  }
}

describe('Idempotency-Key when the store is unavailable (TD-031)', () => {
  let faultyApp: Server;
  let faulty: FaultyStore;

  beforeAll(async () => {
    faulty = new FaultyStore();
    faultyApp = await buildTestApp({ idempotencyStore: faulty });
  });

  it('should still create the resource and answer 201 (fail-open)', async () => {
    const user = await createTestUser(faultyApp);
    const household = await createTestHousehold(faultyApp, user);
    const url = `/api/households/${household.id}/tasks`;

    const started = Date.now();
    const res = await request(faultyApp)
      .post(url)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'outage-key')
      .send({ title: 'Durante la caída' });

    expect(res.status).toBe(201);
    expect(res.body.data.title).toBe('Durante la caída');
    // The whole point of TD-031: an unavailable store must not stall the write.
    expect(Date.now() - started).toBeLessThan(3000);
    expect(faulty.acquireCalls).toBeGreaterThan(0);
  });

  it('should fall back to pre-ADR-007 behaviour: a repeated key creates again', async () => {
    const user = await createTestUser(faultyApp);
    const household = await createTestHousehold(faultyApp, user);
    const url = `/api/households/${household.id}/tasks`;
    const send = (): Promise<request.Response> =>
      request(faultyApp)
        .post(url)
        .set(authHeader(user.accessToken))
        .set('Idempotency-Key', 'same-key-twice')
        .send({ title: 'Sin dedupe' });

    const first = await send();
    const second = await send();

    // Without a store there is no dedupe. Losing that is the accepted trade —
    // duplicate protection is an improvement, not a correctness requirement.
    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(second.body.data.id).not.toBe(first.body.data.id);

    const list = await request(faultyApp)
      .get(url)
      .query({ limit: 100 })
      .set(authHeader(user.accessToken));
    expect(list.body.data.items).toHaveLength(2);
  });

  it('should not hang when acquire exceeds the command timeout', async () => {
    const slow = new SlowStore();
    const slowApp = await buildTestApp({ idempotencyStore: slow });
    const user = await createTestUser(slowApp);
    const household = await createTestHousehold(slowApp, user);

    const started = Date.now();
    const res = await request(slowApp)
      .post(`/api/households/${household.id}/tasks`)
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', 'slow-key')
      .send({ title: 'Store lento' });

    expect(res.status).toBe(201);
    expect(Date.now() - started).toBeLessThan(3000);
    expect(slow.acquireCalls).toBe(1);
  });
});


describe('RedisIdempotencyStore with an unavailable Redis', () => {
  // Redis is never initialized in this suite, so getRedis() throws — the same
  // shape of failure as an outage or a commandTimeout rejection.
  const store = new RedisIdempotencyStore();

  it('should report acquire as failed instead of throwing', async () => {
    await expect(store.acquire('k', 1000)).resolves.toBe('failed');
  });

  it('should return null from getResult instead of throwing', async () => {
    await expect(store.getResult('k')).resolves.toBeNull();
  });

  it('should swallow setResult and release failures', async () => {
    await expect(store.setResult('k', { status: 201, body: {} }, 1000)).resolves.toBeUndefined();
    await expect(store.release('k')).resolves.toBeUndefined();
  });

  it('should return null from waitForResult without hanging', async () => {
    const started = Date.now();
    await expect(store.waitForResult('k', 100)).resolves.toBeNull();
    expect(Date.now() - started).toBeLessThan(2000);
  });
});

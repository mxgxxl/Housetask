import { Server } from 'http';
import request from 'supertest';

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

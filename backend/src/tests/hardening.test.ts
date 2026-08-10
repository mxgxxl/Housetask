import { Server } from 'http';
import request from 'supertest';

import { TaskModel } from '../models/Task';
import { ShoppingItemModel } from '../models/ShoppingItem';
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

async function setupHousehold(): Promise<{ user: TestUser; household: TestHousehold; url: string }> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  return { user, household, url: `/api/households/${household.id}/tasks` };
}

describe('input sanitization', () => {
  it('should store text containing markup characters exactly as typed', async () => {
    const { user, url } = await setupHousehold();

    const res = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'Tom & Jerry <3' });

    expect(res.status).toBe(201);
    // ADR-009: escaping here would show the user "Tom &amp; Jerry" in a widget
    // that never interprets markup anyway.
    expect(res.body.data.title).toBe('Tom & Jerry <3');
  });

  it('should store a script-like title raw, leaving escaping to the renderer', async () => {
    const { user, url } = await setupHousehold();

    const res = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: '<script>alert(1)</script>' });

    expect(res.status).toBe(201);
    expect(res.body.data.title).toBe('<script>alert(1)</script>');
  });

  it('should reject a task title longer than 200 characters', async () => {
    const { user, url } = await setupHousehold();

    const res = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'x'.repeat(201) });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Task title must be at most 200 characters');
  });

  it('should accept a task title of exactly 200 characters', async () => {
    const { user, url } = await setupHousehold();

    const res = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'x'.repeat(200) });

    expect(res.status).toBe(201);
  });

  it('should reject a description longer than 2000 characters', async () => {
    const { user, url } = await setupHousehold();

    const res = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'Válida', description: 'x'.repeat(2001) });

    expect(res.status).toBe(400);
  });

  it('should reject a shopping item name longer than 200 characters', async () => {
    const { user, household } = await setupHousehold();

    const res = await request(app)
      .post(`/api/households/${household.id}/shopping`)
      .set(authHeader(user.accessToken))
      .send({ name: 'x'.repeat(201) });

    expect(res.status).toBe(400);
  });

  it('should reject a household name longer than 100 characters', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/households')
      .set(authHeader(user.accessToken))
      .send({ name: 'x'.repeat(101) });

    expect(res.status).toBe(400);
  });

  it('should neutralise operator injection in the login payload', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/auth/login')
      .send({ email: { $ne: null }, password: { $ne: null } });

    // With $-keys stripped the object is empty, so this can never authenticate.
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(res.body.success).toBe(false);
    expect(JSON.stringify(res.body)).not.toContain(user.email);
  });
});

describe('assignedTo validation', () => {
  it('should reject an assignee who belongs to another household', async () => {
    const { user, url } = await setupHousehold();
    const outsider = await createTestUser(app);
    await createTestHousehold(app, outsider, 'Otra casa');

    const res = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'Asignada mal', assignedTo: [outsider.id] });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Invalid assigned member');
  });

  it('should accept an assignee who is a member', async () => {
    const { user, url } = await setupHousehold();

    const res = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'Asignada bien', assignedTo: [user.id] });

    expect(res.status).toBe(201);
    expect(res.body.data.assignedTo[0].id).toBe(user.id);
  });

  it('should reject a non-member assignee on update too', async () => {
    const { user, url } = await setupHousehold();
    const outsider = await createTestUser(app);
    const created = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'Para reasignar' });

    const res = await request(app)
      .patch(`${url}/${created.body.data.id}`)
      .set(authHeader(user.accessToken))
      .send({ assignedTo: [outsider.id] });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Invalid assigned member');
  });
});

describe('dueDate range validation', () => {
  it('should reject a dueDate more than 10 years in the future', async () => {
    const { user, url } = await setupHousehold();

    const res = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'Muy lejana', dueDate: '2050-01-01T00:00:00.000Z' });

    expect(res.status).toBe(400);
  });

  it('should reject a dueDate before 2020', async () => {
    const { user, url } = await setupHousehold();

    const res = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'Muy antigua', dueDate: '2019-06-01T00:00:00.000Z' });

    expect(res.status).toBe(400);
  });

  it('should accept a dueDate inside the accepted window', async () => {
    const { user, url } = await setupHousehold();

    const res = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'Razonable', dueDate: '2026-12-01T00:00:00.000Z' });

    expect(res.status).toBe(201);
  });
});

describe('Content-Type enforcement', () => {
  it('should answer 415 for a non-JSON body', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .set('Content-Type', 'text/plain')
      .send('email=a@b.com&password=secret');

    expect(res.status).toBe(415);
    expect(res.body.success).toBe(false);
    expect(res.body.error).toBe('Content-Type must be application/json');
  });

  it('should answer 415 for a form-encoded body', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .type('form')
      .send({ email: 'a@b.com', password: 'secret' });

    expect(res.status).toBe(415);
  });

  it('should still allow body-less PATCH requests', async () => {
    const { user, url } = await setupHousehold();
    const created = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ title: 'Sin cuerpo' });

    // No Content-Type and no payload: RFC 9110 does not require the header,
    // and /complete legitimately carries nothing.
    const res = await request(app)
      .patch(`${url}/${created.body.data.id}/complete`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
  });
});

describe('list indexes match the listing sort', () => {
  /**
   * Asserted on the schema declaration rather than on listIndexes(): building
   * indexes needs 500MB of free disk, which makes a DB-level assertion fail for
   * reasons unrelated to the code. The declaration is what this repo controls;
   * Mongoose builds it on connect.
   */
  function declaredKeyPatterns(schema: { indexes(): Array<[Record<string, unknown>, unknown]> }) {
    return schema.indexes().map(([key]) => JSON.stringify(key));
  }

  it('should declare a Task index with exactly the listing sort key pattern', () => {
    const patterns = declaredKeyPatterns(TaskModel.schema);

    // Same fields AND same directions as { status: -1, dueDate: 1, _id: -1 },
    // otherwise MongoDB sorts in memory (32MB cap) on every page.
    expect(patterns).toContain(
      JSON.stringify({ householdId: 1, status: -1, dueDate: 1, _id: -1 })
    );
    expect(patterns).not.toContain(JSON.stringify({ householdId: 1, status: 1, dueDate: 1 }));
  });

  it('should declare a ShoppingItem index with exactly the listing sort key pattern', () => {
    const patterns = declaredKeyPatterns(ShoppingItemModel.schema);

    expect(patterns).toContain(JSON.stringify({ householdId: 1, isPurchased: 1, _id: -1 }));
    expect(patterns).not.toContain(
      JSON.stringify({ householdId: 1, isPurchased: 1, createdAt: -1 })
    );
  });
});

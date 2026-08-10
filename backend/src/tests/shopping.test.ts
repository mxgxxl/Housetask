import { Server } from 'http';
import { Types } from 'mongoose';
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

/**
 * Shape of the shopping-item payload returned by the API.
 */
interface ShoppingResponse {
  id: string;
  name: string;
  quantity: number;
  isPurchased: boolean;
  purchasedAt?: string;
  purchasedBy?: { id: string };
}

async function setupHousehold(): Promise<{
  user: TestUser;
  household: TestHousehold;
  url: string;
}> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  return { user, household, url: `/api/households/${household.id}/shopping` };
}

describe('POST /api/households/:householdId/shopping', () => {
  it('should create an item and return 201', async () => {
    const { user, url } = await setupHousehold();

    const res = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ name: 'Leche', quantity: 2, category: 'fridge' });

    expect(res.status).toBe(201);
    expect(res.body.data.name).toBe('Leche');
    expect(res.body.data.quantity).toBe(2);
    expect(res.body.data.isPurchased).toBe(false);
  });

  it('should return 400 when the name is empty', async () => {
    const { user, url } = await setupHousehold();

    const res = await request(app).post(url).set(authHeader(user.accessToken)).send({ name: '  ' });

    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Item name is required');
  });

  it('should return 403 when the caller is not a member of the household', async () => {
    const { url } = await setupHousehold();
    const outsider = await createTestUser(app);

    const res = await request(app)
      .post(url)
      .set(authHeader(outsider.accessToken))
      .send({ name: 'Pan' });

    expect(res.status).toBe(403);
  });
});

describe('GET /api/households/:householdId/shopping', () => {
  it('should list not-purchased items before purchased ones', async () => {
    const { user, url } = await setupHousehold();

    const first = await request(app).post(url).set(authHeader(user.accessToken)).send({
      name: 'Comprado',
    });
    await request(app).post(url).set(authHeader(user.accessToken)).send({ name: 'Pendiente' });

    await request(app)
      .patch(`${url}/${first.body.data.id}/purchase`)
      .set(authHeader(user.accessToken));

    const res = await request(app).get(url).set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    const items = res.body.data as ShoppingResponse[];
    expect(items).toHaveLength(2);
    expect(items[0].name).toBe('Pendiente');
    expect(items[0].isPurchased).toBe(false);
    expect(items[1].name).toBe('Comprado');
    expect(items[1].isPurchased).toBe(true);
  });
});

describe('PATCH /api/households/:householdId/shopping/:itemId/purchase', () => {
  it('should set purchasedAt and purchasedBy when an item is purchased', async () => {
    const { user, url } = await setupHousehold();
    const created = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ name: 'Huevos' });

    const res = await request(app)
      .patch(`${url}/${created.body.data.id}/purchase`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body.data.isPurchased).toBe(true);
    expect(res.body.data.purchasedAt).toBeDefined();
    expect(res.body.data.purchasedBy.id).toBe(user.id);
  });
});

describe('DELETE /api/households/:householdId/shopping/:itemId', () => {
  it('should return 404 for an item id that does not exist', async () => {
    const { user, url } = await setupHousehold();
    const missingId = new Types.ObjectId().toString();

    const res = await request(app).delete(`${url}/${missingId}`).set(authHeader(user.accessToken));

    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Shopping item not found');
  });

  it('should delete an existing item', async () => {
    const { user, url } = await setupHousehold();
    const created = await request(app)
      .post(url)
      .set(authHeader(user.accessToken))
      .send({ name: 'Arroz' });

    const res = await request(app)
      .delete(`${url}/${created.body.data.id}`)
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);

    const list = await request(app).get(url).set(authHeader(user.accessToken));
    expect(list.body.data).toEqual([]);
  });
});

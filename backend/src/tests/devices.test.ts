import { Server } from 'http';
import { randomUUID } from 'crypto';
import request from 'supertest';

import { buildTestApp } from './setup';
import { DeviceTokenModel } from '../models/DeviceToken';
import { authHeader, createTestUser } from './helpers';

let app: Server;

beforeAll(async () => {
  app = await buildTestApp();
});

describe('POST /api/devices/register', () => {
  it('should return 401 without an access token', async () => {
    const res = await request(app)
      .post('/api/devices/register')
      .send({ token: 'device-token', platform: 'android' });

    expect(res.status).toBe(401);
  });

  it('should return 400 when token is missing', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/devices/register')
      .set(authHeader(user.accessToken))
      .send({ platform: 'android' });

    expect(res.status).toBe(400);
  });

  it('should return 400 when platform is not ios/android', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/devices/register')
      .set(authHeader(user.accessToken))
      .send({ token: 'device-token', platform: 'web' });

    expect(res.status).toBe(400);
  });

  it('should register a device token for the authenticated user', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .post('/api/devices/register')
      .set(authHeader(user.accessToken))
      .send({ token: 'device-token-1', platform: 'ios' });

    expect(res.status).toBe(201);
    expect(res.body).toEqual({ success: true, data: { message: 'Device registered' } });

    const rows = await DeviceTokenModel.find({ userId: user.id });
    expect(rows).toHaveLength(1);
    expect(rows[0].token).toBe('device-token-1');
    expect(rows[0].platform).toBe('ios');
  });

  it('should transfer a token from its previous owner (e.g. a shared device)', async () => {
    const previousOwner = await createTestUser(app);
    const newOwner = await createTestUser(app);
    await request(app)
      .post('/api/devices/register')
      .set(authHeader(previousOwner.accessToken))
      .send({ token: 'shared-device', platform: 'android' });

    const res = await request(app)
      .post('/api/devices/register')
      .set(authHeader(newOwner.accessToken))
      .send({ token: 'shared-device', platform: 'android' });

    expect(res.status).toBe(201);
    expect(await DeviceTokenModel.find({ userId: previousOwner.id })).toHaveLength(0);
    expect(await DeviceTokenModel.find({ userId: newOwner.id })).toHaveLength(1);
  });

  it('should replay the stored response for a repeated Idempotency-Key without creating a duplicate row', async () => {
    const user = await createTestUser(app);
    const idempotencyKey = randomUUID();

    const first = await request(app)
      .post('/api/devices/register')
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', idempotencyKey)
      .send({ token: 'device-token-2', platform: 'android' });
    const second = await request(app)
      .post('/api/devices/register')
      .set(authHeader(user.accessToken))
      .set('Idempotency-Key', idempotencyKey)
      .send({ token: 'device-token-2', platform: 'android' });

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect(second.body).toEqual(first.body);
    expect(await DeviceTokenModel.find({ userId: user.id })).toHaveLength(1);
  });
});

describe('DELETE /api/devices/:token', () => {
  it('should return 401 without an access token', async () => {
    const res = await request(app).delete('/api/devices/some-token');

    expect(res.status).toBe(401);
  });

  it("should remove the caller's own device token", async () => {
    const user = await createTestUser(app);
    await request(app)
      .post('/api/devices/register')
      .set(authHeader(user.accessToken))
      .send({ token: 'device-token-3', platform: 'ios' });

    const res = await request(app)
      .delete('/api/devices/device-token-3')
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ success: true, data: { message: 'Device removed' } });
    expect(await DeviceTokenModel.find({ userId: user.id })).toHaveLength(0);
  });

  it("should not remove another user's device token", async () => {
    const owner = await createTestUser(app);
    const attacker = await createTestUser(app);
    await request(app)
      .post('/api/devices/register')
      .set(authHeader(owner.accessToken))
      .send({ token: 'device-token-4', platform: 'ios' });

    const res = await request(app)
      .delete('/api/devices/device-token-4')
      .set(authHeader(attacker.accessToken));

    expect(res.status).toBe(200); // idempotent no-op, not an error
    expect(await DeviceTokenModel.find({ userId: owner.id })).toHaveLength(1);
  });

  it('should be a safe no-op when the token does not exist', async () => {
    const user = await createTestUser(app);

    const res = await request(app)
      .delete('/api/devices/nonexistent-token')
      .set(authHeader(user.accessToken));

    expect(res.status).toBe(200);
  });
});

// These jest.mock() calls MUST be the very first statements in this file —
// ts-jest preserves source order (unlike babel-jest, it does NOT hoist
// jest.mock() above imports), and `import './setup'` below transitively
// requires notification.service.ts (via app.ts -> device.routes ->
// device.controller). If any import ran first, that chain would capture a
// binding to the REAL firebase-admin/app before these mocks ever registered
// — confirmed the hard way: it produced a real "Failed to parse private
// key." error from firebase-admin's own credential parser instead of using
// the mock.
jest.mock('firebase-admin/app', () => ({
  initializeApp: jest.fn(() => ({ name: 'mock-app' })),
  getApps: jest.fn(() => []),
  cert: jest.fn((serviceAccount: unknown) => serviceAccount),
}));

jest.mock('firebase-admin/messaging', () => ({
  getMessaging: jest.fn(),
}));

import { Types } from 'mongoose';

import './setup';
import { DeviceTokenModel } from '../models/DeviceToken';
import { logger } from '../utils/logger';
import { getApps, initializeApp } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';
import {
  registerDeviceToken,
  removeDeviceToken,
  resetFirebaseAppForTests,
  sendPushNotification,
} from '../services/notification.service';

const FAKE_SERVICE_ACCOUNT = JSON.stringify({
  project_id: 'homesync-test',
  client_email: 'firebase-adminsdk@homesync-test.iam.gserviceaccount.com',
  private_key: '-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----\n',
});

function userId(): string {
  return new Types.ObjectId().toString();
}

describe('notification.service (PDR-008)', () => {
  const originalEnv = process.env.FIREBASE_SERVICE_ACCOUNT;

  beforeEach(() => {
    resetFirebaseAppForTests();
    (getApps as jest.Mock).mockReturnValue([]);
  });

  afterEach(() => {
    if (originalEnv === undefined) delete process.env.FIREBASE_SERVICE_ACCOUNT;
    else process.env.FIREBASE_SERVICE_ACCOUNT = originalEnv;
  });

  describe('sendPushNotification', () => {
    it('should no-op when FIREBASE_SERVICE_ACCOUNT is not set', async () => {
      delete process.env.FIREBASE_SERVICE_ACCOUNT;
      const info = jest.spyOn(logger, 'info').mockImplementation(() => undefined);

      const result = await sendPushNotification(userId(), 'Title', 'Body');

      expect(result).toEqual({ sent: 0, failed: 0 });
      expect(info).toHaveBeenCalledWith('Push notifications disabled: no FIREBASE_SERVICE_ACCOUNT');
      expect(getMessaging).not.toHaveBeenCalled();
      info.mockRestore();
    });

    it('should no-op and log an error when FIREBASE_SERVICE_ACCOUNT is malformed JSON', async () => {
      process.env.FIREBASE_SERVICE_ACCOUNT = 'not-json';
      const error = jest.spyOn(logger, 'error').mockImplementation(() => undefined);

      const result = await sendPushNotification(userId(), 'Title', 'Body');

      expect(result).toEqual({ sent: 0, failed: 0 });
      expect(error).toHaveBeenCalledWith(
        'Failed to initialize Firebase Admin SDK',
        expect.any(String),
      );
      error.mockRestore();
    });

    it('should return zero counts without touching Firebase when the user has no registered devices', async () => {
      process.env.FIREBASE_SERVICE_ACCOUNT = FAKE_SERVICE_ACCOUNT;

      const result = await sendPushNotification(userId(), 'Title', 'Body');

      expect(result).toEqual({ sent: 0, failed: 0 });
      expect(getMessaging).not.toHaveBeenCalled();
    });

    it('should send a multicast to every device token registered for the user and report counts', async () => {
      process.env.FIREBASE_SERVICE_ACCOUNT = FAKE_SERVICE_ACCOUNT;
      const uid = userId();
      await DeviceTokenModel.create({ userId: uid, token: 'token-a', platform: 'android' });
      await DeviceTokenModel.create({ userId: uid, token: 'token-b', platform: 'ios' });

      const sendEachForMulticast = jest.fn().mockResolvedValue({
        successCount: 2,
        failureCount: 0,
        responses: [{ success: true }, { success: true }],
      });
      (getMessaging as jest.Mock).mockReturnValue({ sendEachForMulticast });

      const result = await sendPushNotification(
        uid,
        'Nueva tarea asignada',
        'Cristina te asignó: X',
        {
          type: 'task',
          taskId: 't1',
        },
      );

      expect(result).toEqual({ sent: 2, failed: 0 });
      expect(initializeApp).toHaveBeenCalledTimes(1);
      expect(sendEachForMulticast).toHaveBeenCalledWith({
        tokens: expect.arrayContaining(['token-a', 'token-b']),
        notification: { title: 'Nueva tarea asignada', body: 'Cristina te asignó: X' },
        data: { type: 'task', taskId: 't1' },
      });
    });

    it('should delete device tokens FCM reports as no longer registered', async () => {
      process.env.FIREBASE_SERVICE_ACCOUNT = FAKE_SERVICE_ACCOUNT;
      const uid = userId();
      await DeviceTokenModel.create({ userId: uid, token: 'stale-token', platform: 'android' });
      await DeviceTokenModel.create({ userId: uid, token: 'good-token', platform: 'ios' });

      // Built from the actual `tokens` order sendPushNotification passes in,
      // rather than a hardcoded array — DeviceTokenModel.find() does not
      // guarantee document order, so a positional fixture would be flaky.
      const sendEachForMulticast = jest.fn().mockImplementation((message: { tokens: string[] }) => {
        const responses = message.tokens.map((token) =>
          token === 'stale-token'
            ? { success: false, error: { code: 'messaging/registration-token-not-registered' } }
            : { success: true },
        );
        const failureCount = responses.filter((r) => !r.success).length;
        return Promise.resolve({
          successCount: responses.length - failureCount,
          failureCount,
          responses,
        });
      });
      (getMessaging as jest.Mock).mockReturnValue({ sendEachForMulticast });

      const result = await sendPushNotification(uid, 'Title', 'Body');

      expect(result).toEqual({ sent: 1, failed: 1 });
      const remaining = await DeviceTokenModel.find({ userId: uid });
      expect(remaining.map((d) => d.token)).toEqual(['good-token']);
    });

    it('should swallow a Firebase send error and report every device as failed', async () => {
      process.env.FIREBASE_SERVICE_ACCOUNT = FAKE_SERVICE_ACCOUNT;
      const uid = userId();
      await DeviceTokenModel.create({ userId: uid, token: 'token-a', platform: 'android' });
      const error = jest.spyOn(logger, 'error').mockImplementation(() => undefined);

      const sendEachForMulticast = jest.fn().mockRejectedValue(new Error('FCM unavailable'));
      (getMessaging as jest.Mock).mockReturnValue({ sendEachForMulticast });

      const result = await sendPushNotification(uid, 'Title', 'Body');

      expect(result).toEqual({ sent: 0, failed: 1 });
      error.mockRestore();
    });
  });

  describe('registerDeviceToken', () => {
    it('should create a new device token row', async () => {
      const uid = userId();

      await registerDeviceToken(uid, 'token-1', 'android');

      const rows = await DeviceTokenModel.find({ userId: uid });
      expect(rows).toHaveLength(1);
      expect(rows[0].token).toBe('token-1');
      expect(rows[0].platform).toBe('android');
    });

    it('should be idempotent when the same user re-registers the same token', async () => {
      const uid = userId();

      await registerDeviceToken(uid, 'token-1', 'android');
      await registerDeviceToken(uid, 'token-1', 'android');

      const rows = await DeviceTokenModel.find({ userId: uid });
      expect(rows).toHaveLength(1);
    });

    it('should steal a token from its previous owner when a different user registers it', async () => {
      const previousOwner = userId();
      const newOwner = userId();
      await DeviceTokenModel.create({
        userId: previousOwner,
        token: 'shared-token',
        platform: 'ios',
      });

      await registerDeviceToken(newOwner, 'shared-token', 'ios');

      expect(await DeviceTokenModel.find({ userId: previousOwner })).toHaveLength(0);
      const rows = await DeviceTokenModel.find({ userId: newOwner });
      expect(rows).toHaveLength(1);
      expect(rows[0].token).toBe('shared-token');
    });
  });

  describe('removeDeviceToken', () => {
    it("should delete the user's own device token", async () => {
      const uid = userId();
      await DeviceTokenModel.create({ userId: uid, token: 'token-1', platform: 'android' });

      await removeDeviceToken(uid, 'token-1');

      expect(await DeviceTokenModel.find({ userId: uid })).toHaveLength(0);
    });

    it('should be a safe no-op when the token does not exist', async () => {
      await expect(removeDeviceToken(userId(), 'nonexistent')).resolves.toBeUndefined();
    });
  });
});

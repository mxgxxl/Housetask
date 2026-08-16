import { Types } from 'mongoose';
import type { Messaging } from 'firebase-admin/messaging';

import './setup';
import { DeviceTokenModel } from '../models/DeviceToken';
import { logger } from '../utils/logger';
import {
  registerDeviceToken,
  removeDeviceToken,
  resetFirebaseAppForTests,
  sendPushNotification,
  setMessagingForTests,
} from '../services/notification.service';

// A real (but throwaway, unregistered with any Firebase project) RSA key —
// NOT a mock. `jest.mock('firebase-admin/app'/'firebase-admin/messaging',
// ...)` cannot work in this suite: every test file implicitly loads
// `setup.ts` via Jest's `setupFilesAfterEnv`, which imports `app.ts` (and
// transitively notification.service.ts) BEFORE this file's own jest.mock()
// calls ever run — the real SDK is already bound in notification.service.ts
// by the time a mock would register (confirmed the hard way: it produced a
// real "Failed to parse private key." error instead of using the mock).
// A syntactically valid key lets the real (harmless, no-network)
// cert()/initializeApp() succeed; setMessagingForTests (see
// notification.service.ts) is the seam that avoids ever making a real FCM
// network call for the send itself.
const FAKE_PRIVATE_KEY =
  '-----BEGIN PRIVATE KEY-----\n' +
  'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCl7L6QNNRQFO9D\n' +
  'X/lUiFOaTlpGO87eWC0GzVxGEWNLBKKaVSIkKsN6y4ymveZDkMzxU0CSvXr/f4sy\n' +
  'NG8SGYNk2bIVeOY1jTenX5nlxrINsJBv4nhVAKMhavSgEIjJYW2KSqGeKDlvXwkW\n' +
  'Vqr/LpiiNaBG1kqQWpmZPtWXpJ/bNDTTvHVKlxvzyOv3EmufZHXTmRlVck1tnXw0\n' +
  'swClxwgDlesyuipQtPQEevLx0Lut2Pe4W+Hd8OqqmbSdRL33L27uT7+3SAGoiEal\n' +
  'PtASPgfEyihIGM+ss0DfvXA+2ctdyRLiY7+i/Npbwg6XzU2vc7KBM4CVtPfjcuQ5\n' +
  'KG+EJhQlAgMBAAECggEACd5DdCysLuob09A+sjQccsozrMcsVcV9QhEPKpyooOLQ\n' +
  '7+hdzDRd5Wz7O8SCECUpxzWKGuAZk14Iz47WR0eMrMAUyxmiaW9xbqstKkEPwGgu\n' +
  'ovTfbsDHsvpbO7TYCdAZVXb8Vz1xswm+Lt2vNFeXXNhfJK9khmLZDUfzKJ5yInWH\n' +
  'JXSgMo/9FFruYCO5JTg3NMcyzlMHdrRfZmYWPOVksR6RYG8q7eovnGxHFDojjWF/\n' +
  'oaZKnomwbQUds988FSwmvcq7H4jG2HpNiFowkXJyRUPPjocajkQmm5o0Osdv808E\n' +
  'ql+MZD6Y6NxCvcU6Zt6Xvz9xEdzfkjBSQBLBteQtSQKBgQDQZyhfy243yHcJ5hOL\n' +
  'qBhLLjYSuJgO5C0Ct9TPPj6B2QB34tJysMQVqjMbwmOLNac6VNZmo+1JLJNSZB9M\n' +
  'B1L+sBESRclqwy02QHL0bo163UztRJNjKcCXKCdIsj1dHxldi6+d3QWzNVk97qSO\n' +
  'OfgSTWMWaxdEaYMzSID4xlz3CQKBgQDL0fw5aSUjZTtGPQ9GoDuanNJtnLcvh8JF\n' +
  'UiUI/yDHSUFVGYUkZmo904PJ812BriE4grUhUsmnt9HTcCPa9rFXojn0Ruy5dYtF\n' +
  'jPX2n9zm+BFZI11rgIVIckqNe+rrFZb/lFRJ+36W0sn6+O2gI9xc+V0pAmhoMBIt\n' +
  'NiRZnpQ/PQKBgQCdJu0fL7xxfE2nvUPH8H5BUxubim+/6vi2MAHeNcXVDNp5jSW9\n' +
  'Lubun2Xi7Pc7pr3wEsGKrNrmbyK44p9nKa7AN+znppB4Xa3eV0NYZ3VwzSiRU0EB\n' +
  'ah683Z6iByaW7jimfgt0M5N0zCn7tdWJGtWil5C8+wyUniw9o9L9xjecYQKBgFuq\n' +
  'Coc/VGaAxpGmMFKRCX1VfgWx72i+444NjX5oTzORLIK7QXfHX4yCrciLXMhPqb0i\n' +
  'e5eLBgoZz5IJ4vY88DD7UpkbtKcLyCD1bkEGUHDHq/Wsw/zvBgI49HKBAnvLb+dt\n' +
  'rCLBqoLmNdRbU3Mr7ZUayN0CqjYBOIuAyAROH1n5AoGAXz2SxynKEu97oIQMhZWR\n' +
  'pd5a85WTHM1k6mVo6btCoeZOmKWPqO+E7Eu2i2Hvu9LHPHN3TKUMityxxlvRtSZ+\n' +
  'VKfQ9NSCt2Z0O+WqikA2cObcj0I4VyklvfKY52MjUTijzmiIA2IZCcpLr5hueDIT\n' +
  'RVdCdf8xx/i5g7qgZjOxrqg=\n' +
  '-----END PRIVATE KEY-----\n';

const FAKE_SERVICE_ACCOUNT = JSON.stringify({
  project_id: 'homesync-test',
  client_email: 'firebase-adminsdk@homesync-test.iam.gserviceaccount.com',
  private_key: FAKE_PRIVATE_KEY,
});

function userId(): string {
  return new Types.ObjectId().toString();
}

/** A Messaging double: only sendEachForMulticast is ever called by the service. */
function fakeMessaging(sendEachForMulticast: jest.Mock): Messaging {
  return { sendEachForMulticast } as unknown as Messaging;
}

describe('notification.service (PDR-008)', () => {
  const originalEnv = process.env.FIREBASE_SERVICE_ACCOUNT;

  beforeEach(() => {
    resetFirebaseAppForTests();
  });

  afterEach(() => {
    setMessagingForTests(null);
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

    it('should return zero counts without ever calling Messaging when the user has no registered devices', async () => {
      process.env.FIREBASE_SERVICE_ACCOUNT = FAKE_SERVICE_ACCOUNT;
      const sendEachForMulticast = jest.fn();
      setMessagingForTests(fakeMessaging(sendEachForMulticast));

      const result = await sendPushNotification(userId(), 'Title', 'Body');

      expect(result).toEqual({ sent: 0, failed: 0 });
      expect(sendEachForMulticast).not.toHaveBeenCalled();
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
      setMessagingForTests(fakeMessaging(sendEachForMulticast));

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
      setMessagingForTests(fakeMessaging(sendEachForMulticast));

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
      setMessagingForTests(fakeMessaging(sendEachForMulticast));

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

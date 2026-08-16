import { Types } from 'mongoose';
import { initializeApp, getApps, cert, App } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';

import { DeviceTokenModel } from '../models/DeviceToken';
import { logger } from '../utils/logger';

/**
 * Firebase Admin init, lazy and cached (PDR-008).
 *
 * Mirrors utils/sentry.ts's no-op-when-unconfigured pattern: no
 * `FIREBASE_SERVICE_ACCOUNT` (or a malformed one) disables push
 * notifications entirely rather than crashing the process — every
 * environment without the var, including every test run, behaves exactly
 * as it did before this feature existed.
 *
 * `undefined` = not attempted yet, `null` = attempted and unavailable,
 * an `App` = ready. Distinguishing "not attempted" from "failed" lets a
 * failure be logged once instead of on every call.
 */
let firebaseApp: App | null | undefined;

function getFirebaseApp(): App | null {
  if (firebaseApp !== undefined) return firebaseApp;

  const raw = process.env.FIREBASE_SERVICE_ACCOUNT?.trim();
  if (!raw) {
    logger.info('Push notifications disabled: no FIREBASE_SERVICE_ACCOUNT');
    firebaseApp = null;
    return firebaseApp;
  }

  try {
    const serviceAccount = JSON.parse(raw);
    firebaseApp = getApps().length
      ? getApps()[0]
      : initializeApp({ credential: cert(serviceAccount) });
  } catch (err) {
    logger.error('Failed to initialize Firebase Admin SDK', (err as Error).message);
    firebaseApp = null;
  }

  return firebaseApp;
}

/** Test-only: forces the next call to re-attempt initialization. */
export function resetFirebaseAppForTests(): void {
  firebaseApp = undefined;
}

/**
 * Register (or re-register) a device token for push notifications.
 *
 * A physical device belongs to one user at a time, but the same FCM token
 * could theoretically still be sitting under a previous account (e.g. a
 * shared device where a different household member logged in later) — any
 * such row is deleted first so a stale registration never receives another
 * user's notifications. The upsert on (userId, token) then makes a repeat
 * registration by the same user a no-op rather than a duplicate row.
 */
export async function registerDeviceToken(
  userId: string,
  token: string,
  platform: 'ios' | 'android',
): Promise<void> {
  const userObjectId = new Types.ObjectId(userId);

  await DeviceTokenModel.deleteMany({ token, userId: { $ne: userObjectId } });

  await DeviceTokenModel.findOneAndUpdate(
    { userId: userObjectId, token },
    { userId: userObjectId, token, platform },
    { upsert: true, setDefaultsOnInsert: true },
  );
}

/** Remove one device token belonging to `userId` (e.g. on logout). Idempotent. */
export async function removeDeviceToken(userId: string, token: string): Promise<void> {
  await DeviceTokenModel.deleteOne({ userId: new Types.ObjectId(userId), token });
}

export interface PushResult {
  sent: number;
  failed: number;
}

const NO_OP_RESULT: PushResult = { sent: 0, failed: 0 };

/** FCM's code for a token that is no longer valid (app uninstalled, etc). */
const INVALID_TOKEN_ERROR_CODE = 'messaging/registration-token-not-registered';

/**
 * Send a push notification to every device registered for `userId`
 * (PDR-008). Best-effort by design — callers (task.service's create/complete
 * triggers) run this fire-and-forget in a try/catch, but the function itself
 * also never throws, so a bad call site can't accidentally skip that guard.
 *
 * A device whose token FCM reports as permanently invalid is deleted from
 * DeviceToken so it stops being retried on every future notification.
 */
export async function sendPushNotification(
  userId: string,
  title: string,
  body: string,
  data?: Record<string, string>,
): Promise<PushResult> {
  const app = getFirebaseApp();
  if (!app) {
    return NO_OP_RESULT;
  }

  const devices = await DeviceTokenModel.find({ userId: new Types.ObjectId(userId) });
  if (devices.length === 0) {
    return NO_OP_RESULT;
  }

  try {
    const response = await getMessaging(app).sendEachForMulticast({
      tokens: devices.map((device) => device.token),
      notification: { title, body },
      data,
    });

    const invalidTokens = response.responses
      .map((result, index) => ({ result, token: devices[index].token }))
      .filter(({ result }) => !result.success && result.error?.code === INVALID_TOKEN_ERROR_CODE)
      .map(({ token }) => token);

    if (invalidTokens.length > 0) {
      await DeviceTokenModel.deleteMany({
        userId: new Types.ObjectId(userId),
        token: { $in: invalidTokens },
      });
    }

    logger.info('Push notification sent', {
      userId,
      sent: response.successCount,
      failed: response.failureCount,
      invalidTokensRemoved: invalidTokens.length,
    });

    return { sent: response.successCount, failed: response.failureCount };
  } catch (err) {
    logger.error('Failed to send push notification', (err as Error).message);
    return { sent: 0, failed: devices.length };
  }
}

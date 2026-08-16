import { z } from 'zod';

/**
 * POST /api/devices/register body. `token` is opaque (FCM assigns its own
 * format and length) so only presence is validated, not shape.
 */
export const registerDeviceSchema = z.object({
  token: z.string({ error: 'Device token is required' }).trim().min(1, 'Device token is required'),
  platform: z.enum(['ios', 'android'], { error: 'platform must be "ios" or "android"' }),
});

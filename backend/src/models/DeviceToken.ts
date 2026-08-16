import { Schema, model, Document, Types } from 'mongoose';

/**
 * A registered FCM device token for push notifications (PDR-008).
 *
 * Does NOT apply `jsonSchemaOptions`: like RefreshToken, these documents are
 * internal bookkeeping and never serialized to clients — the device
 * endpoints only ever respond with `{ message }`.
 */
export interface IDeviceToken extends Document {
  _id: Types.ObjectId;
  userId: Types.ObjectId;
  token: string;
  platform: 'ios' | 'android';
  createdAt: Date;
}

const deviceTokenSchema = new Schema<IDeviceToken>(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    // Indexed on its own (in addition to the compound unique index below) so
    // registerDeviceToken's "does this token already belong to someone else"
    // lookup — keyed on token alone, not on userId+token — stays an index scan.
    token: { type: String, required: true, trim: true, index: true },
    platform: { type: String, enum: ['ios', 'android'], required: true },
  },
  { timestamps: { createdAt: true, updatedAt: false } },
);

// One device token maps to exactly one (userId, token) row — re-registering
// the same token for the same user is an upsert, not a duplicate.
deviceTokenSchema.index({ userId: 1, token: 1 }, { unique: true });

export const DeviceTokenModel = model<IDeviceToken>('DeviceToken', deviceTokenSchema);

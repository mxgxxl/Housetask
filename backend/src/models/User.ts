import { Schema, model, Document, Types } from 'mongoose';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * A registered user. Passwords are stored hashed (bcrypt) and excluded from
 * query results by default (`select: false`).
 */
export interface IUser extends Document {
  _id: Types.ObjectId;
  email: string;
  password: string;
  name: string;
  avatarUrl?: string;
  createdAt: Date;
  updatedAt: Date;
}

const userSchema = new Schema<IUser>(
  {
    email: {
      type: String,
      required: true,
      unique: true,
      lowercase: true,
      trim: true,
      index: true,
    },
    password: {
      type: String,
      required: true,
      minlength: 6,
      select: false,
    },
    name: {
      type: String,
      required: true,
      trim: true,
    },
    avatarUrl: {
      type: String,
    },
    // TD-001 commit 7: the denormalized `households` array is gone. It was the
    // second copy of the same edge HouseholdMember now owns (finding H1 of
    // docs/TD-001-DESIGN.md), and keeping it would have preserved exactly the
    // consistency problem this migration exists to remove — only on the other
    // side. "Which households does this user belong to" is now
    // `HouseholdMember.find({ userId })`, covered by its `{userId: 1}` index.
  },
  { timestamps: true, ...jsonSchemaOptions },
);

export const UserModel = model<IUser>('User', userSchema);

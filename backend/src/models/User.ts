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
  households: Types.ObjectId[];
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
    households: [
      {
        type: Schema.Types.ObjectId,
        ref: 'Household',
      },
    ],
  },
  { timestamps: true, ...jsonSchemaOptions },
);

export const UserModel = model<IUser>('User', userSchema);

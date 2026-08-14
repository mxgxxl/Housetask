import { Schema, model, Document, Types } from 'mongoose';
import { Role } from '../types';
import { jsonSchemaOptions } from '../utils/toJSON';

export interface IHouseholdMember {
  user: Types.ObjectId;
  role: Role;
  joinedAt: Date;
}

/**
 * A household groups users together and owns tasks + shopping items.
 * Membership is embedded so we can read members without a second query.
 */
export interface IHousehold extends Document {
  _id: Types.ObjectId;
  name: string;
  inviteCode: string;
  members: IHouseholdMember[];
  createdBy: Types.ObjectId;
  createdAt: Date;
  updatedAt: Date;
}

const memberSchema = new Schema<IHouseholdMember>(
  {
    user: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    role: { type: String, enum: ['admin', 'member'], default: 'member' },
    joinedAt: { type: Date, default: Date.now },
  },
  { _id: false },
);

const householdSchema = new Schema<IHousehold>(
  {
    name: { type: String, required: true, trim: true },
    inviteCode: {
      type: String,
      required: true,
      unique: true,
      uppercase: true,
      minlength: 8,
      maxlength: 8,
      index: true,
    },
    members: { type: [memberSchema], default: [] },
    createdBy: { type: Schema.Types.ObjectId, ref: 'User', required: true },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

export const HouseholdModel = model<IHousehold>('Household', householdSchema);

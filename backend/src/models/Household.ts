import { Schema, model, Document, Types } from 'mongoose';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * A household groups users together and owns tasks + shopping items.
 *
 * Membership used to live here as an embedded `members` array (ADR-005, filed
 * as "TO BE MIGRATED" from the start). TD-001 moved it to the HouseholdMember
 * collection across five phases; commit 7 removed the field from this schema
 * and `$unset` it from the stored documents
 * (`scripts/unset-household-members.ts`). A household no longer knows who
 * belongs to it — the memberships know which household they are for, which is
 * the direction that scales and the one that cannot go out of sync with
 * itself.
 *
 * Nothing here should ever grow a members field again. To list a household's
 * members: `HouseholdMemberModel.find({ householdId })`.
 */
export interface IHousehold extends Document {
  _id: Types.ObjectId;
  name: string;
  inviteCode: string;
  createdBy: Types.ObjectId;
  createdAt: Date;
  updatedAt: Date;
}

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
    createdBy: { type: Schema.Types.ObjectId, ref: 'User', required: true },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

export const HouseholdModel = model<IHousehold>('Household', householdSchema);

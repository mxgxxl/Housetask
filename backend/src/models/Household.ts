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
  /** Destroyed (PDR-022 D4). Soft delete: the document survives, access does not. */
  isDeleted: boolean;
  deletedAt?: Date;
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
    // PDR-022 D4: destruction is a soft delete, matching what PDR-006 already
    // does for tasks. The alternative — removing the document — would free the
    // unique invite code for reuse, so a code someone still has in a chat
    // would one day resolve to a stranger's household. A destroyed household
    // keeps its code precisely so that never happens.
    //
    // Indexed because every read of a household now filters on it, the same
    // reason Task indexes its own `isDeleted` (TD-046).
    isDeleted: { type: Boolean, default: false, index: true },
    deletedAt: { type: Date },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

export const HouseholdModel = model<IHousehold>('Household', householdSchema);

import { Schema, model, Document, Types } from 'mongoose';
import { Role } from '../types';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * A user's membership in a household (TD-001).
 *
 * Replaces the `members` array embedded in Household (ADR-005, filed as
 * "TO BE MIGRATED" from the start). The embedded form made a member list
 * unbounded inside its parent document and forced every membership write to
 * rewrite the whole household; it also duplicated the relationship, since
 * `User.households` tracks the same edge from the other side.
 *
 * Nothing reads this collection yet — see docs/TD-001-DESIGN.md for the
 * five-phase migration (dual write → backfill → dual read with verification →
 * cutover → cleanup). Until the cutover, the embedded array stays the
 * authority and this collection is its mirror.
 */
export interface IHouseholdMember extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  userId: Types.ObjectId;
  role: Role;
  joinedAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const householdMemberSchema = new Schema<IHouseholdMember>(
  {
    householdId: { type: Schema.Types.ObjectId, ref: 'Household', required: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    role: { type: String, enum: ['admin', 'member'], default: 'member' },
    // Carried over rather than derived from createdAt: a backfilled row must
    // keep the date the user actually joined, not the date it was migrated.
    joinedAt: { type: Date, default: Date.now },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

// The membership check `requireMembership` runs on every household-scoped
// request, so this is the hottest lookup in the app and must be an index hit.
//
// `unique` is doing a second job: it makes a duplicate membership impossible
// by construction, which is the guarantee joinByInviteCode currently
// approximates in application code with its `alreadyMember` check. A
// concurrent double join stops being a race and becomes a duplicate-key error.
householdMemberSchema.index({ householdId: 1, userId: 1 }, { unique: true });

// "Which households does this user belong to" — the query that will replace
// the denormalized `User.households` array in the cleanup phase, including the
// socket handshake's room resolution (config/socket.ts).
householdMemberSchema.index({ userId: 1 });

// Counting a household's admins (Hard Rule 9: never delete the last admin)
// and listing its members. Covered by this index rather than a collection scan.
householdMemberSchema.index({ householdId: 1, role: 1 });

export const HouseholdMemberModel = model<IHouseholdMember>(
  'HouseholdMember',
  householdMemberSchema,
);

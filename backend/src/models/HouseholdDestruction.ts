import { Schema, model, Document, Types } from 'mongoose';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * A household that its creator has scheduled for destruction (TD-067,
 * PDR-022 D4).
 *
 * The row IS the grace period. It exists between "the creator confirmed they
 * want this gone" and "it is gone", and its whole job is to make that interval
 * observable and reversible: cancelling deletes the row, and nothing else has
 * to be undone because nothing else has happened yet.
 *
 * Deliberately a separate collection rather than a `pendingDeletionAt` field
 * on Household. A field would be read on every household request that already
 * loads that document, for a state that is empty for essentially every
 * household that will ever exist; a collection is only touched by the four
 * endpoints and the job that care about it. It also keeps `scheduledBy` — who
 * asked — next to the deadline rather than bolting a second, unrelated user
 * reference onto Household beside `createdBy`.
 */
export interface IHouseholdDestruction extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  scheduledBy: Types.ObjectId;
  /** When the grace period expires and the destruction may be confirmed. */
  scheduledAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const householdDestructionSchema = new Schema<IHouseholdDestruction>(
  {
    householdId: { type: Schema.Types.ObjectId, ref: 'Household', required: true },
    scheduledBy: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    scheduledAt: { type: Date, required: true },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

// One pending destruction per household, enforced by the database rather than
// by a read-then-write in the service. Two devices tapping "delete household"
// at the same instant is a plausible race for the one person who can do it,
// and the second must find the first schedule rather than create a second
// deadline that a later cancel would only half remove.
householdDestructionSchema.index({ householdId: 1 }, { unique: true });

// The job's query: "everything whose grace period has expired". Sorted scan
// over an index instead of a collection scan, which matters once the
// collection is mostly rows still waiting.
householdDestructionSchema.index({ scheduledAt: 1 });

export const HouseholdDestructionModel = model<IHouseholdDestruction>(
  'HouseholdDestruction',
  householdDestructionSchema,
);

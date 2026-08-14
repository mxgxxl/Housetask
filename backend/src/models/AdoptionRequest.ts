import { Schema, model, Document, Types } from 'mongoose';
import { PetSpecies } from './Pet';
import { jsonSchemaOptions } from '../utils/toJSON';

export type AdoptionRequestStatus = 'pending';

/**
 * A household's in-flight pet adoption proposal (PDR-001 Fase A2): one
 * member starts it, a DIFFERENT member must confirm before a Pet is
 * created. Only one status exists — confirming DELETES this document
 * rather than transitioning it (pet.service.ts's confirmAdoption) — there
 * is no reject flow this round, so nothing needs to read a resolved
 * request.
 *
 * `householdId` is unique: exactly one pending request per household, the
 * same "one at a time" rule as Pet.householdId's unique index.
 */
export interface IAdoptionRequest extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  species: PetSpecies;
  name: string;
  requestedBy: Types.ObjectId;
  status: AdoptionRequestStatus;
  createdAt: Date;
  updatedAt: Date;
}

const adoptionRequestSchema = new Schema<IAdoptionRequest>(
  {
    householdId: {
      type: Schema.Types.ObjectId,
      ref: 'Household',
      required: true,
      unique: true,
      index: true,
    },
    species: { type: String, enum: ['cat', 'dog'], required: true },
    name: { type: String, required: true, trim: true, minlength: 1, maxlength: 50 },
    requestedBy: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    status: { type: String, enum: ['pending'], default: 'pending', required: true },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

export const AdoptionRequestModel = model<IAdoptionRequest>(
  'AdoptionRequest',
  adoptionRequestSchema,
);

import { Schema, model, Document, Types } from 'mongoose';
import { jsonSchemaOptions } from '../utils/toJSON';

export type PetSpecies = 'cat' | 'dog';

/**
 * The household's shared pet (PDR-001 Fase A). Exactly one per household —
 * adoption is a household-level decision, not a per-user one.
 *
 * `hunger`/`mood` are the values as of the last write (feed/play/adoption);
 * they are NOT decayed in place on a timer. Reads must run them through
 * economy.service.ts's `computeDecay` to get the current, time-adjusted
 * value — see that function's doc comment for why decay is lazy.
 */
export interface IPet extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  species: PetSpecies;
  name: string;
  adoptedAt: Date;
  adoptedBy: Types.ObjectId;
  hunger: number;
  mood: number;
  lastFedAt?: Date;
  lastPlayedAt?: Date;
  cosmetics: string[];
  activeCosmetic?: string;
  createdAt: Date;
  updatedAt: Date;
}

const petSchema = new Schema<IPet>(
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
    adoptedAt: { type: Date, required: true, default: Date.now },
    adoptedBy: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    hunger: { type: Number, min: 0, max: 100, default: 80 },
    mood: { type: Number, min: 0, max: 100, default: 80 },
    lastFedAt: { type: Date },
    lastPlayedAt: { type: Date },
    cosmetics: { type: [String], default: [] },
    activeCosmetic: { type: String },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

export const PetModel = model<IPet>('Pet', petSchema);

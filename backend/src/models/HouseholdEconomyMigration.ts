import { Schema, model, Document, Types } from 'mongoose';
import { EconomyMigrationPhase } from '../types/economy-p1';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * Per-household record of the P1 migration, and the authority the feature
 * flag will read (TD-066-DESIGN §6).
 *
 * Its job is to make activation OBSERVABLE AND REVERSIBLE. P1 does not
 * migrate a household implicitly: someone runs the activation script, this
 * row records what was true before the switch, and only then does
 * `isP1Enabled` start answering true. Rolling back sets the phase back and
 * changes nothing else — no ledger is deleted, and `EconomyLedger` plus the
 * Fase A cosmetics stay exactly as they were (§6.5).
 *
 * ── Why legacyWalletUserId cannot be inferred ────────────────────────────
 * The Fase A ledger records `householdId` and never `userId`: the balance
 * belongs to the HOUSEHOLD. P1 wallets are personal, so crediting that
 * balance requires naming a person, and no query can name them — splitting it
 * evenly would invent a distribution nobody agreed to, and crediting each
 * member the full amount would multiply the household's money by its size.
 * So the person is a required input to the migration, recorded here before
 * the credit is written, which turns an irreversible guess into an auditable
 * decision (§6.3, and the closing dependency list of the design).
 */
export interface IHouseholdEconomyMigration extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  phase: EconomyMigrationPhase;
  /**
   * The Fase A balance at snapshot time, kept immutable afterwards.
   *
   * Recorded even though `EconomyLedger` is never deleted, because the ledger
   * keeps moving: the pet and its cosmetics still spend from it during the
   * migration, so "what was the balance when we switched" stops being
   * recomputable the moment anyone feeds the pet.
   */
  legacyBalanceSnapshot?: number;
  /**
   * The newest `EconomyLedger` entry included in the snapshot.
   *
   * Together with the balance it makes the credit checkable after the fact:
   * anything after this watermark is Fase A activity that post-dates the
   * migration, not money that should have been carried over.
   */
  legacyLedgerWatermark?: Date;
  /** The member whose personal wallet receives the legacy credit. */
  legacyWalletUserId?: Types.ObjectId;
  /** When P1 was switched on for this household. */
  activatedAt?: Date;
  /** When it was switched back to Fase A reads, if ever. */
  rolledBackAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

const householdEconomyMigrationSchema = new Schema<IHouseholdEconomyMigration>(
  {
    householdId: {
      type: Schema.Types.ObjectId,
      ref: 'Household',
      required: true,
      unique: true,
    },
    phase: {
      type: String,
      enum: ['pending', 'snapshotted', 'active', 'rolled_back'],
      required: true,
      default: 'pending',
    },
    // Optional at the schema level because a row can legitimately exist in
    // `pending` before anything is measured. B11 enforces the real rule —
    // refusing to credit a legacy balance without a legacyWalletUserId — at
    // the point where a human can still supply it, rather than failing an
    // insert with a validation error nobody can act on.
    legacyBalanceSnapshot: { type: Number, min: 0 },
    legacyLedgerWatermark: { type: Date },
    legacyWalletUserId: { type: Schema.Types.ObjectId, ref: 'User' },
    activatedAt: { type: Date },
    rolledBackAt: { type: Date },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

// One migration record per household. `unique` on the path above already
// creates the index; declaring the query pattern here would duplicate it.

export const HouseholdEconomyMigrationModel = model<IHouseholdEconomyMigration>(
  'HouseholdEconomyMigration',
  householdEconomyMigrationSchema,
);

import { Schema, model, Document, Types } from 'mongoose';
import { ShoppingCategory } from '../types';
import { jsonSchemaOptions } from '../utils/toJSON';

/**
 * A shopping-list item belonging to a household. Indexed by householdId.
 */
export interface IShoppingItem extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  name: string;
  quantity: number;
  unit: string;
  category: ShoppingCategory;
  isPurchased: boolean;
  purchasedAt?: Date;
  purchasedBy?: Types.ObjectId;
  addedBy: Types.ObjectId;
  isRecurring: boolean;
  recurrenceIntervalDays?: number;
  lastAddedAt?: Date;
  estimatedPrice?: number;
  createdAt: Date;
  updatedAt: Date;
}

const shoppingItemSchema = new Schema<IShoppingItem>(
  {
    householdId: {
      type: Schema.Types.ObjectId,
      ref: 'Household',
      required: true,
      index: true,
    },
    name: { type: String, required: true, trim: true },
    quantity: { type: Number, default: 1, min: 0 },
    unit: { type: String, default: 'uds' },
    category: {
      type: String,
      enum: ['fridge', 'pantry', 'cleaning', 'personal', 'other'],
      default: 'other',
    },
    isPurchased: { type: Boolean, default: false, index: true },
    purchasedAt: { type: Date },
    purchasedBy: { type: Schema.Types.ObjectId, ref: 'User' },
    addedBy: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    isRecurring: { type: Boolean, default: false },
    recurrenceIntervalDays: { type: Number },
    lastAddedAt: { type: Date },
    estimatedPrice: { type: Number },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

// Matches the listing sort EXACTLY: householdId equality, isPurchased asc,
// _id desc. The previous index ended in createdAt, which the sort no longer
// uses, so it could not serve it (TD-026).
shoppingItemSchema.index({ householdId: 1, isPurchased: 1, _id: -1 });

export const ShoppingItemModel = model<IShoppingItem>('ShoppingItem', shoppingItemSchema);

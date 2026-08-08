import { Types } from 'mongoose';
import { ShoppingItemModel, IShoppingItem } from '../models/ShoppingItem';
import { AppError } from '../middleware/error.middleware';
import { assertMembership } from './household.service';
import { emitToHousehold } from '../config/socket';
import { ShoppingCategory } from '../types';

const POPULATE_FIELDS = 'name email avatarUrl';

export interface CreateShoppingInput {
  name: string;
  quantity?: number;
  unit?: string;
  category?: ShoppingCategory;
  isRecurring?: boolean;
  recurrenceIntervalDays?: number;
  estimatedPrice?: number;
}

export interface UpdateShoppingInput {
  name?: string;
  quantity?: number;
  unit?: string;
  category?: ShoppingCategory;
  isPurchased?: boolean;
  isRecurring?: boolean;
  recurrenceIntervalDays?: number;
  estimatedPrice?: number;
}

async function populated(item: IShoppingItem): Promise<IShoppingItem> {
  return item.populate([
    { path: 'addedBy', select: POPULATE_FIELDS },
    { path: 'purchasedBy', select: POPULATE_FIELDS },
  ]);
}

/**
 * List a household's shopping items, not-purchased first, newest first.
 */
export async function listItems(householdId: string, userId: string): Promise<IShoppingItem[]> {
  await assertMembership(householdId, userId);

  // isPurchased:1 puts false (not purchased) before true.
  return ShoppingItemModel.find({ householdId: new Types.ObjectId(householdId) })
    .sort({ isPurchased: 1, createdAt: -1 })
    .populate('addedBy', POPULATE_FIELDS)
    .populate('purchasedBy', POPULATE_FIELDS);
}

/**
 * Add a shopping item and broadcast `shopping:created`.
 */
export async function createItem(
  householdId: string,
  userId: string,
  input: CreateShoppingInput
): Promise<IShoppingItem> {
  await assertMembership(householdId, userId);

  if (!input.name || input.name.trim() === '') {
    throw new AppError('Item name is required', 400);
  }

  const item = await ShoppingItemModel.create({
    householdId: new Types.ObjectId(householdId),
    name: input.name.trim(),
    quantity: input.quantity ?? 1,
    unit: input.unit || 'uds',
    category: input.category || 'other',
    addedBy: new Types.ObjectId(userId),
    isRecurring: input.isRecurring ?? false,
    recurrenceIntervalDays: input.recurrenceIntervalDays,
    estimatedPrice: input.estimatedPrice,
    lastAddedAt: new Date(),
  });

  await populated(item);
  emitToHousehold(householdId, 'shopping:created', item.toJSON());
  return item;
}

/**
 * Apply a partial update to a shopping item and broadcast `shopping:updated`.
 * Setting `isPurchased` keeps the purchase metadata consistent.
 */
export async function updateItem(
  householdId: string,
  userId: string,
  itemId: string,
  input: UpdateShoppingInput
): Promise<IShoppingItem> {
  await assertMembership(householdId, userId);

  const item = await ShoppingItemModel.findOne({ _id: itemId, householdId });
  if (!item) {
    throw new AppError('Shopping item not found', 404);
  }

  if (input.name !== undefined) item.name = input.name.trim();
  if (input.quantity !== undefined) item.quantity = input.quantity;
  if (input.unit !== undefined) item.unit = input.unit;
  if (input.category !== undefined) item.category = input.category;
  if (input.isRecurring !== undefined) item.isRecurring = input.isRecurring;
  if (input.recurrenceIntervalDays !== undefined) {
    item.recurrenceIntervalDays = input.recurrenceIntervalDays;
  }
  if (input.estimatedPrice !== undefined) item.estimatedPrice = input.estimatedPrice;

  if (input.isPurchased !== undefined) {
    item.isPurchased = input.isPurchased;
    if (input.isPurchased) {
      item.purchasedAt = item.purchasedAt ?? new Date();
      item.purchasedBy = item.purchasedBy ?? new Types.ObjectId(userId);
    } else {
      item.purchasedAt = undefined;
      item.purchasedBy = undefined;
    }
  }

  await item.save();
  await populated(item);
  emitToHousehold(householdId, 'shopping:updated', item.toJSON());
  return item;
}

/**
 * Mark an item as purchased (sets purchasedAt/purchasedBy) and broadcast
 * `shopping:purchased`.
 */
export async function purchaseItem(
  householdId: string,
  userId: string,
  itemId: string
): Promise<IShoppingItem> {
  await assertMembership(householdId, userId);

  const item = await ShoppingItemModel.findOne({ _id: itemId, householdId });
  if (!item) {
    throw new AppError('Shopping item not found', 404);
  }

  item.isPurchased = true;
  item.purchasedAt = new Date();
  item.purchasedBy = new Types.ObjectId(userId);
  await item.save();

  await populated(item);
  emitToHousehold(householdId, 'shopping:purchased', item.toJSON());
  return item;
}

/**
 * Delete a shopping item and broadcast `shopping:deleted`.
 */
export async function deleteItem(
  householdId: string,
  userId: string,
  itemId: string
): Promise<void> {
  await assertMembership(householdId, userId);

  const item = await ShoppingItemModel.findOneAndDelete({ _id: itemId, householdId });
  if (!item) {
    throw new AppError('Shopping item not found', 404);
  }

  emitToHousehold(householdId, 'shopping:deleted', { id: itemId, householdId });
}

import { Types } from 'mongoose';
import { ShoppingItemModel, IShoppingItem } from '../models/ShoppingItem';
import { AppError } from '../middleware/error.middleware';
import { emitToHousehold } from '../config/socket';
import { ShoppingCategory } from '../types';
import { Page, decodeCursor, encodeCursor } from '../utils/pagination';
import { sanitizeString } from '../utils/sanitize';
import { logger } from '../utils/logger';
import { grantCoins } from './economy.service';
import { PURCHASE_COINS } from '../config/economy';

const POPULATE_FIELDS = 'name email avatarUrl';

const MAX_ITEM_NAME_LENGTH = 200;

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
 * Total order used for listing and for keyset pagination.
 *
 * `isPurchased: 1` puts false (not purchased) before true, then newest first.
 * `_id` replaces `createdAt` as the tiebreaker for the same reason as tasks:
 * ObjectIds are ordered by creation time but, unlike timestamps, never tie, and
 * a cursor over a non-total order skips or repeats rows.
 */
const SHOPPING_SORT = { isPurchased: 1, _id: -1 } as const;

/**
 * Sort position of the last item on a page, carried in the opaque cursor.
 */
interface ShoppingCursor {
  p: boolean;
  id: string;
}

function isShoppingCursor(value: unknown): value is ShoppingCursor {
  if (typeof value !== 'object' || value === null) return false;
  const c = value as Record<string, unknown>;
  return typeof c.p === 'boolean' && typeof c.id === 'string' && Types.ObjectId.isValid(c.id);
}

/**
 * Build the "strictly after this position" predicate for SHOPPING_SORT.
 */
function shoppingCursorFilter(cursor: ShoppingCursor): Record<string, unknown> {
  return {
    $or: [
      // isPurchased ascending: false is followed by true.
      { isPurchased: { $gt: cursor.p } },
      // same purchase state, smaller _id (descending tiebreaker).
      { isPurchased: cursor.p, _id: { $lt: new Types.ObjectId(cursor.id) } },
    ],
  };
}

export interface ListItemsOptions {
  limit: number;
  cursor?: string;
}

/**
 * List one page of a household's shopping items, not-purchased first, newest
 * first.
 */
export async function listItems(
  householdId: string,
  userId: string,
  options: ListItemsOptions,
): Promise<Page<IShoppingItem>> {
  const baseFilter: Record<string, unknown> = { householdId: new Types.ObjectId(householdId) };

  const pageFilter = { ...baseFilter };
  if (options.cursor) {
    Object.assign(pageFilter, shoppingCursorFilter(decodeCursor(options.cursor, isShoppingCursor)));
  }

  // Counted only on the first page: the value is identical for every page of a
  // walk, so recomputing it per page is a pure waste of a collection scan.
  const [total, docs] = await Promise.all([
    options.cursor ? Promise.resolve(null) : ShoppingItemModel.countDocuments(baseFilter),
    ShoppingItemModel.find(pageFilter)
      .sort(SHOPPING_SORT)
      // One extra row is the cheapest way to know whether another page exists.
      .limit(options.limit + 1)
      .populate('addedBy', POPULATE_FIELDS)
      .populate('purchasedBy', POPULATE_FIELDS),
  ]);

  const hasMore = docs.length > options.limit;
  const items = hasMore ? docs.slice(0, options.limit) : docs;
  const last = items[items.length - 1];

  return {
    items,
    hasMore,
    total,
    nextCursor:
      hasMore && last ? encodeCursor({ p: last.isPurchased, id: last._id.toString() }) : null,
  };
}

/**
 * Add a shopping item and broadcast `shopping:created`.
 */
export async function createItem(
  householdId: string,
  userId: string,
  input: CreateShoppingInput,
): Promise<IShoppingItem> {
  if (!input.name || input.name.trim() === '') {
    throw new AppError('Item name is required', 400);
  }

  const item = await ShoppingItemModel.create({
    householdId: new Types.ObjectId(householdId),
    name: sanitizeString(input.name, MAX_ITEM_NAME_LENGTH, 'Item name'),
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
  input: UpdateShoppingInput,
): Promise<IShoppingItem> {
  const item = await ShoppingItemModel.findOne({ _id: itemId, householdId });
  if (!item) {
    throw new AppError('Shopping item not found', 404);
  }

  if (input.name !== undefined) {
    item.name = sanitizeString(input.name, MAX_ITEM_NAME_LENGTH, 'Item name');
  }
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
  itemId: string,
): Promise<IShoppingItem> {
  const item = await ShoppingItemModel.findOne({ _id: itemId, householdId });
  if (!item) {
    throw new AppError('Shopping item not found', 404);
  }

  // Captured before mutation: only the FIRST purchase grants coins
  // (PDR-001 anti-farm) — see task.service.ts:completeTask for the same
  // pattern.
  const isFirstPurchase = !item.isPurchased;

  item.isPurchased = true;
  item.purchasedAt = new Date();
  item.purchasedBy = new Types.ObjectId(userId);
  await item.save();

  // Best-effort: must never fail the purchase itself. See
  // task.service.ts:completeTask for why isFirstPurchase is only a
  // short-circuit, not the actual anti-double-grant guard.
  if (isFirstPurchase) {
    try {
      await grantCoins(householdId, PURCHASE_COINS, 'purchase_complete', itemId);
    } catch (err) {
      logger.error('Error granting purchase-complete coins', (err as Error).message);
    }
  }

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
  itemId: string,
): Promise<void> {
  const item = await ShoppingItemModel.findOneAndDelete({ _id: itemId, householdId });
  if (!item) {
    throw new AppError('Shopping item not found', 404);
  }

  emitToHousehold(householdId, 'shopping:deleted', { id: itemId, householdId });
}

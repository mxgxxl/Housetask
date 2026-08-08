import { Response } from 'express';
import * as shoppingService from '../services/shopping.service';
import { sendSuccess } from '../utils/response';
import { AuthenticatedRequest } from '../types';

/**
 * GET /api/households/:householdId/shopping
 * Lists shopping items (not purchased first).
 */
export async function list(req: AuthenticatedRequest, res: Response): Promise<void> {
  const items = await shoppingService.listItems(req.params.householdId, req.user!.userId);
  sendSuccess(res, items);
}

/**
 * POST /api/households/:householdId/shopping
 * Adds an item; broadcasts shopping:created.
 */
export async function create(req: AuthenticatedRequest, res: Response): Promise<void> {
  const item = await shoppingService.createItem(
    req.params.householdId,
    req.user!.userId,
    req.body ?? {}
  );
  sendSuccess(res, item, 201);
}

/**
 * PATCH /api/households/:householdId/shopping/:itemId
 * Partial update; broadcasts shopping:updated.
 */
export async function update(req: AuthenticatedRequest, res: Response): Promise<void> {
  const item = await shoppingService.updateItem(
    req.params.householdId,
    req.user!.userId,
    req.params.itemId,
    req.body ?? {}
  );
  sendSuccess(res, item);
}

/**
 * PATCH /api/households/:householdId/shopping/:itemId/purchase
 * Marks an item purchased; broadcasts shopping:purchased.
 */
export async function purchase(req: AuthenticatedRequest, res: Response): Promise<void> {
  const item = await shoppingService.purchaseItem(
    req.params.householdId,
    req.user!.userId,
    req.params.itemId
  );
  sendSuccess(res, item);
}

/**
 * DELETE /api/households/:householdId/shopping/:itemId
 * Deletes an item; broadcasts shopping:deleted.
 */
export async function remove(req: AuthenticatedRequest, res: Response): Promise<void> {
  await shoppingService.deleteItem(req.params.householdId, req.user!.userId, req.params.itemId);
  sendSuccess(res, { message: 'Item deleted' });
}

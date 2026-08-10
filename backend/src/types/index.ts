import { Request } from 'express';

/**
 * Shape of the decoded access-token payload.
 */
export interface JwtAccessPayload {
  userId: string;
  email: string;
}

/**
 * Shape of the decoded refresh-token payload.
 */
export interface JwtRefreshPayload {
  userId: string;
  tokenId: string;
}

/**
 * The caller's membership in the household addressed by `:householdId`,
 * attached by membership.middleware so controllers can branch on role without
 * re-querying.
 */
export interface RequesterMembership {
  role: Role;
  joinedAt: Date;
}

/**
 * Express request enriched by auth.middleware with the authenticated user and,
 * on household-scoped routes, by membership.middleware with `member`.
 */
export interface AuthenticatedRequest extends Request {
  user?: JwtAccessPayload;
  member?: RequesterMembership;
}

/**
 * Standard API envelope. Every endpoint responds with this shape.
 */
export interface ApiResponse<T = unknown> {
  success: boolean;
  data?: T;
  error?: string;
}

export type Role = 'admin' | 'member';

export type TaskStatus = 'pending' | 'completed';
export type TaskPriority = 'low' | 'medium' | 'high';
export type TaskCategory = 'cleaning' | 'cooking' | 'shopping' | 'maintenance' | 'other';
export type RecurrenceType = 'daily' | 'weekly' | 'monthly' | 'custom';

export type ShoppingCategory = 'fridge' | 'pantry' | 'cleaning' | 'personal' | 'other';

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
 * Express request enriched by auth.middleware with the authenticated user.
 */
export interface AuthenticatedRequest extends Request {
  user?: JwtAccessPayload;
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

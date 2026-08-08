import { Response } from 'express';
import { ApiResponse } from '../types';

/**
 * Send a standardized success envelope: { success: true, data }.
 */
export function sendSuccess<T>(res: Response, data: T, status = 200): Response<ApiResponse<T>> {
  return res.status(status).json({ success: true, data });
}

/**
 * Send a standardized error envelope: { success: false, error }.
 */
export function sendError(res: Response, error: string, status = 400): Response<ApiResponse> {
  return res.status(status).json({ success: false, error });
}

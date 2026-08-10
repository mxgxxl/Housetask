import { Request, Response, NextFunction } from 'express';
import { sendError } from '../utils/response';

const BODY_METHODS = new Set(['POST', 'PUT', 'PATCH']);

/**
 * Reject request bodies that are not JSON.
 *
 * The API is JSON-only, and `express.json()` simply ignores a body it cannot
 * claim — so a form-encoded or text/plain payload would silently arrive as an
 * empty `req.body` and surface as a confusing "field is required" 400. A 415
 * names the real problem.
 *
 * Body-less POST/PUT/PATCH requests are exempt: `PATCH /tasks/:id/complete`
 * and `PATCH /shopping/:id/purchase` carry no payload, and per RFC 9110
 * Content-Type describes a body that is not there. Demanding the header on
 * those would break correct clients for no benefit.
 */
export function requireJsonContentType(req: Request, res: Response, next: NextFunction): void {
  if (!BODY_METHODS.has(req.method)) {
    next();
    return;
  }

  const contentType = req.get('content-type');
  if (contentType) {
    if (!contentType.toLowerCase().includes('application/json')) {
      sendError(res, 'Content-Type must be application/json', 415);
      return;
    }
    next();
    return;
  }

  // No Content-Type: only an actual payload makes this an error.
  const hasBody =
    Number(req.get('content-length') ?? '0') > 0 || req.get('transfer-encoding') !== undefined;

  if (hasBody) {
    sendError(res, 'Content-Type must be application/json', 415);
    return;
  }

  next();
}

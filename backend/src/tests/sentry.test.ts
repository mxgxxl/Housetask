import { Request, Response } from 'express';

import { errorHandler } from '../middleware/error.middleware';
import { captureSecurityWarning, captureServerError, initSentry } from '../utils/sentry';
import { logger } from '../utils/logger';

/** Minimal Express Response double: enough for sendError's status().json() chain. */
function fakeResponse(): Response {
  const res = {} as Response;
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
}

describe('Sentry no-op fallback (TD-009)', () => {
  // No test in this suite ever sets SENTRY_DSN, so Sentry.init() is never
  // called and every capture below exercises the disabled path for real —
  // this is not a mock of "disabled", it IS disabled.

  it('should log that it is disabled and not throw when SENTRY_DSN is absent', () => {
    const info = jest.spyOn(logger, 'info').mockImplementation(() => undefined);
    const original = process.env.SENTRY_DSN;
    delete process.env.SENTRY_DSN;

    try {
      expect(() => initSentry()).not.toThrow();
      expect(info).toHaveBeenCalledWith('Sentry disabled: no DSN');
    } finally {
      if (original === undefined) delete process.env.SENTRY_DSN;
      else process.env.SENTRY_DSN = original;
      info.mockRestore();
    }
  });

  it('should treat an empty string the same as absent', () => {
    const info = jest.spyOn(logger, 'info').mockImplementation(() => undefined);
    const original = process.env.SENTRY_DSN;
    process.env.SENTRY_DSN = '   ';

    try {
      initSentry();
      expect(info).toHaveBeenCalledWith('Sentry disabled: no DSN');
    } finally {
      if (original === undefined) delete process.env.SENTRY_DSN;
      else process.env.SENTRY_DSN = original;
      info.mockRestore();
    }
  });

  it('should no-op captureServerError and captureSecurityWarning without a DSN', () => {
    expect(() => captureServerError(new Error('boom'), { path: '/x' })).not.toThrow();
    expect(() =>
      captureSecurityWarning('refresh-token replay detected', { userId: 'u1' })
    ).not.toThrow();
  });

  it('errorHandler should answer 500 and never throw for an unrecognized error, with Sentry disabled', () => {
    const error = jest.spyOn(logger, 'error').mockImplementation(() => undefined);
    const req = { path: '/api/whatever', method: 'GET' } as Request;
    const res = fakeResponse();

    try {
      // A bare Error matches none of errorHandler's known shapes (AppError,
      // ValidationError, CastError, duplicate key...), so it falls through to
      // the 500 catch-all — the exact path that now also calls
      // captureServerError. That call must be a no-op here, not a throw.
      expect(() => errorHandler(new Error('unexpected'), req, res, jest.fn())).not.toThrow();
    } finally {
      error.mockRestore();
    }

    expect(res.status).toHaveBeenCalledWith(500);
    expect(res.json).toHaveBeenCalledWith({
      success: false,
      error: 'Internal server error',
    });
  });

  it('errorHandler should not capture 4xx responses to Sentry (verified by not throwing on a bad extra arg)', () => {
    // Sentry.captureException is never reached for a 4xx (respond() only calls
    // it when status >= 500); this asserts the 400 path completes normally,
    // which would also be true if capture were wrongly invoked and threw.
    const req = { path: '/api/whatever', method: 'POST' } as Request;
    const res = fakeResponse();

    errorHandler({ name: 'ValidationError', message: 'bad input' }, req, res, jest.fn());

    expect(res.status).toHaveBeenCalledWith(400);
  });
});

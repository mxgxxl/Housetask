import * as Sentry from '@sentry/node';
import { logger } from './logger';

/**
 * Initialize Sentry from `SENTRY_DSN`. A no-op when the variable is absent or
 * empty, so every environment without a DSN — including every test run —
 * behaves exactly as it did before Sentry existed.
 *
 * `beforeSend` drops events in development even if a DSN is somehow set
 * there: local errors are noise a shared Sentry project should never see.
 */
export function initSentry(): void {
  const dsn = process.env.SENTRY_DSN?.trim();
  if (!dsn) {
    logger.info('Sentry disabled: no DSN');
    return;
  }

  Sentry.init({
    dsn,
    environment: process.env.NODE_ENV || 'development',
    tracesSampleRate: 0.2,
    beforeSend(event) {
      return process.env.NODE_ENV === 'development' ? null : event;
    },
  });
}

/**
 * Report an unexpected server error (5xx). No-op when Sentry was never
 * initialized, so call sites never need to guard on whether a DSN is set.
 */
export function captureServerError(error: unknown, context?: Record<string, unknown>): void {
  if (!Sentry.isInitialized()) return;

  Sentry.captureException(error, context ? { extra: context } : undefined);
}

/**
 * Report a security-relevant event (e.g. refresh-token replay) as a warning,
 * not an error — it is a signal to review, not evidence the server is broken.
 * No-op when Sentry was never initialized.
 */
export function captureSecurityWarning(message: string, context: Record<string, unknown>): void {
  if (!Sentry.isInitialized()) return;

  Sentry.captureMessage(message, { level: 'warning', extra: context });
}

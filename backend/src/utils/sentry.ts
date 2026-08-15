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

  const environment = process.env.NODE_ENV || 'development';

  Sentry.init({
    dsn,
    environment,
    // TD-043: performance tracing is production-only — sampling in
    // development would trace local noise a shared Sentry project should
    // never see, the same reasoning beforeSend already applies to errors.
    // 0.2 in production matches the frontend's rate (sentry_service.dart).
    tracesSampleRate: environment === 'production' ? 0.2 : 0,
    beforeSend(event) {
      return process.env.NODE_ENV === 'development' ? null : event;
    },
  });
}

/**
 * Structured tags attached to every captureServerError report (TD-037).
 * Tags — unlike free-form `extra` context — are indexed by Sentry, so they
 * are what dashboard alert rules (e.g. "category:mongo_connection count >
 * N in 5m") and issue grouping/filtering actually key off. `category`
 * discriminates which of the hardened call sites reported the error;
 * `route`/`userId`/`householdId` are attached whenever known at the call
 * site, omitted otherwise (e.g. a Mongo connection error has none of the
 * three — it isn't tied to a single request).
 */
export interface ServerErrorTags {
  category: 'http_5xx' | 'mongo_connection' | 'socket_auth' | 'socket_room' | 'economy_grant';
  route?: string;
  userId?: string;
  householdId?: string;
  // Sentry's own tags type is an index signature (Record<string, Primitive>);
  // matched here so passing a ServerErrorTags value through structurally
  // satisfies it without a cast at the call site.
  [key: string]: string | undefined;
}

/**
 * Report an unexpected server error with structured tags. No-op when
 * Sentry was never initialized, so call sites never need to guard on
 * whether a DSN is set.
 */
export function captureServerError(error: unknown, tags: ServerErrorTags): void {
  if (!Sentry.isInitialized()) return;

  Sentry.captureException(error, { tags });
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

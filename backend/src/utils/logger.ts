/**
 * Minimal logger. For MVP we log to the console with level + timestamp.
 * In production this can be swapped for pino/winston without touching callers.
 */

type LogLevel = 'info' | 'warn' | 'error' | 'debug';

const isProd = process.env.NODE_ENV === 'production';

function log(level: LogLevel, message: string, meta?: unknown): void {
  // Silence debug logs in production.
  if (isProd && level === 'debug') return;

  const timestamp = new Date().toISOString();
  const prefix = `[${timestamp}] [${level.toUpperCase()}]`;

  if (meta !== undefined) {
    // eslint-disable-next-line no-console
    console[level === 'debug' ? 'log' : level](prefix, message, meta);
  } else {
    // eslint-disable-next-line no-console
    console[level === 'debug' ? 'log' : level](prefix, message);
  }
}

export const logger = {
  info: (message: string, meta?: unknown) => log('info', message, meta),
  warn: (message: string, meta?: unknown) => log('warn', message, meta),
  error: (message: string, meta?: unknown) => log('error', message, meta),
  debug: (message: string, meta?: unknown) => log('debug', message, meta),
};

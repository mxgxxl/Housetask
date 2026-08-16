/**
 * Zod request-validation schemas (TD-028), one file per domain
 * (task.schema.ts, household.schema.ts, auth.schema.ts), applied to routes
 * via `middleware/validate.ts`.
 */
export * from './task.schema';
export * from './household.schema';
export * from './auth.schema';
export * from './pet.schema';
export * from './device.schema';

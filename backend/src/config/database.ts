import mongoose from 'mongoose';
import { logger } from '../utils/logger';
import { captureServerError } from '../utils/sentry';

/**
 * Connect to MongoDB via Mongoose. Reads MONGODB_URI from the environment.
 * Retries are handled by the Mongoose driver internally.
 */
export async function connectDatabase(): Promise<void> {
  const uri = process.env.MONGODB_URI;
  if (!uri) {
    throw new Error('MONGODB_URI is not defined in the environment');
  }

  mongoose.set('strictQuery', true);

  mongoose.connection.on('connected', () => logger.info('MongoDB connected'));
  mongoose.connection.on('error', (err) => {
    logger.error('MongoDB connection error', err);
    // Not tied to a single request — no route/userId/householdId to attach
    // (TD-037); the category tag alone is enough for a dashboard alert.
    captureServerError(err, { category: 'mongo_connection' });
  });
  mongoose.connection.on('disconnected', () => logger.warn('MongoDB disconnected'));

  await mongoose.connect(uri);
}

/**
 * Gracefully close the MongoDB connection (used on shutdown).
 */
export async function disconnectDatabase(): Promise<void> {
  await mongoose.connection.close();
}

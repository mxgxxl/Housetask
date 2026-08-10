import { validateProductionEnv } from '../utils/env';

const VALID_SECRET = 'a'.repeat(32);

// Snapshot/restore so a test that flips NODE_ENV cannot leak into the others.
const originalEnv = { ...process.env };

afterEach(() => {
  process.env = { ...originalEnv };
});

describe('validateProductionEnv', () => {
  it('should throw naming CORS_ORIGINS when it is empty in production', () => {
    process.env.NODE_ENV = 'production';
    process.env.CORS_ORIGINS = '';
    process.env.MONGODB_URI = 'mongodb://localhost:27017/homesync';
    process.env.JWT_SECRET = VALID_SECRET;
    process.env.JWT_REFRESH_SECRET = VALID_SECRET;

    // Hard Rule 15: an empty list silently means "*", so booting is worse
    // than crashing.
    expect(() => validateProductionEnv()).toThrow(/CORS_ORIGINS/);
  });

  it('should throw naming the secret when a JWT secret is shorter than 32 characters', () => {
    process.env.NODE_ENV = 'production';
    process.env.CORS_ORIGINS = 'https://app.homesync.com';
    process.env.MONGODB_URI = 'mongodb://localhost:27017/homesync';
    process.env.JWT_SECRET = 'too-short';
    process.env.JWT_REFRESH_SECRET = VALID_SECRET;

    expect(() => validateProductionEnv()).toThrow(/JWT_SECRET/);
  });

  it('should throw naming MONGODB_URI when it is missing in production', () => {
    process.env.NODE_ENV = 'production';
    process.env.CORS_ORIGINS = 'https://app.homesync.com';
    delete process.env.MONGODB_URI;
    process.env.JWT_SECRET = VALID_SECRET;
    process.env.JWT_REFRESH_SECRET = VALID_SECRET;

    expect(() => validateProductionEnv()).toThrow(/MONGODB_URI/);
  });

  it('should not throw when every production variable is present and valid', () => {
    process.env.NODE_ENV = 'production';
    process.env.CORS_ORIGINS = 'https://app.homesync.com,https://admin.homesync.com';
    process.env.MONGODB_URI = 'mongodb://localhost:27017/homesync';
    process.env.JWT_SECRET = VALID_SECRET;
    process.env.JWT_REFRESH_SECRET = VALID_SECRET;

    expect(() => validateProductionEnv()).not.toThrow();
  });

  it('should not throw in development even with an entirely empty environment', () => {
    process.env.NODE_ENV = 'development';
    delete process.env.CORS_ORIGINS;
    delete process.env.MONGODB_URI;
    delete process.env.JWT_SECRET;
    delete process.env.JWT_REFRESH_SECRET;

    expect(() => validateProductionEnv()).not.toThrow();
  });
});

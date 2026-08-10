// Jest configuration for the HomeSync backend integration test suite.
//
// Environment is set here (not only in setup.ts) because this module is
// evaluated before any test module is imported, so modules that read
// process.env at import time (jwt.ts, logger.ts) already see the test values.
process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test_access_secret_at_least_32_characters';
process.env.JWT_REFRESH_SECRET =
  process.env.JWT_REFRESH_SECRET || 'test_refresh_secret_at_least_32_characters';

/** @type {import('ts-jest').JestConfigWithTsJest} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  rootDir: '.',
  testMatch: ['**/*.test.ts'],
  globalSetup: '<rootDir>/src/tests/globalSetup.ts',
  globalTeardown: '<rootDir>/src/tests/globalTeardown.ts',
  setupFilesAfterEnv: ['<rootDir>/src/tests/setup.ts'],
  // The in-memory MongoDB instance is shared per process: run serially so
  // suites never observe each other's collections mid-cleanup.
  maxWorkers: 1,
  testTimeout: 30000,
  clearMocks: true,
  transform: {
    '^.+\\.ts$': ['ts-jest', { tsconfig: '<rootDir>/tsconfig.test.json' }],
  },
  collectCoverageFrom: [
    'src/**/*.ts',
    '!src/tests/**',
    '!src/scripts/**',
    '!src/server.ts',
    '!src/config/swagger.ts',
  ],
};

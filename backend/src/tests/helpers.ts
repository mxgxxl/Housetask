import { Server } from 'http';
import request from 'supertest';

/**
 * A registered user plus its live token pair, as returned by /auth/register.
 */
export interface TestUser {
  id: string;
  email: string;
  password: string;
  name: string;
  accessToken: string;
  refreshToken: string;
}

/**
 * A household created through the API, from the creator's point of view.
 */
export interface TestHousehold {
  id: string;
  name: string;
  inviteCode: string;
}

// Guarantees unique emails within a run without relying on random collisions.
let userSequence = 0;

/**
 * Build the Authorization header for an access token.
 */
export function authHeader(accessToken: string): Record<string, string> {
  return { Authorization: `Bearer ${accessToken}` };
}

/**
 * Register a user through the public API and return it with its tokens.
 */
export async function createTestUser(
  app: Server,
  overrides: Partial<Pick<TestUser, 'email' | 'password' | 'name'>> = {}
): Promise<TestUser> {
  userSequence += 1;
  const email = overrides.email ?? `user${userSequence}@test.com`;
  const password = overrides.password ?? 'password123';
  const name = overrides.name ?? `Test User ${userSequence}`;

  const res = await request(app).post('/api/auth/register').send({ email, password, name });
  if (res.status !== 201) {
    throw new Error(`createTestUser failed (${res.status}): ${JSON.stringify(res.body)}`);
  }

  return {
    id: res.body.data.user.id,
    email,
    password,
    name,
    accessToken: res.body.data.tokens.accessToken,
    refreshToken: res.body.data.tokens.refreshToken,
  };
}

/**
 * Create a household owned by the given user (who becomes its first admin).
 */
export async function createTestHousehold(
  app: Server,
  user: TestUser,
  name = 'Casa de prueba'
): Promise<TestHousehold> {
  const res = await request(app)
    .post('/api/households')
    .set(authHeader(user.accessToken))
    .send({ name });
  if (res.status !== 201) {
    throw new Error(`createTestHousehold failed (${res.status}): ${JSON.stringify(res.body)}`);
  }

  return {
    id: res.body.data.id,
    name: res.body.data.name,
    inviteCode: res.body.data.inviteCode,
  };
}

/**
 * Add an existing user to a household using its invite code.
 */
export async function joinTestHousehold(
  app: Server,
  user: TestUser,
  inviteCode: string
): Promise<void> {
  const res = await request(app)
    .post('/api/households/join')
    .set(authHeader(user.accessToken))
    .send({ inviteCode });
  if (res.status !== 200) {
    throw new Error(`joinTestHousehold failed (${res.status}): ${JSON.stringify(res.body)}`);
  }
}

/**
 * Convenience: create a household whose creator is `admin` and which also has
 * a second, non-admin member.
 */
export async function createHouseholdWithMember(
  app: Server
): Promise<{ admin: TestUser; member: TestUser; household: TestHousehold }> {
  const admin = await createTestUser(app);
  const member = await createTestUser(app);
  const household = await createTestHousehold(app, admin);
  await joinTestHousehold(app, member, household.inviteCode);
  return { admin, member, household };
}

/**
 * ISO string for `days` from now — handy for dueDate assertions.
 */
export function daysFromNow(days: number): string {
  const date = new Date();
  date.setDate(date.getDate() + days);
  return date.toISOString();
}

/**
 * ISO string for `hours` from now — handy for startsAt/endsAt assertions
 * (PDR-004), where day-level granularity is too coarse to express a range.
 */
export function hoursFromNow(hours: number): string {
  const date = new Date();
  date.setHours(date.getHours() + hours);
  return date.toISOString();
}

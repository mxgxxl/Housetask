import 'dotenv/config';
import { randomUUID } from 'crypto';
import { logger } from '../utils/logger';

/**
 * Generate real API traffic so TD-001's dual-read verification has samples to
 * compare (phase 2).
 *
 * `requireMembership` runs on every household-scoped request and, since commit
 * 5209029, compares the HouseholdMember collection against the embedded array
 * on each one. The go/no-go for the cutover is a number — zero divergences
 * under real traffic — so the window needs traffic. This produces it without
 * anyone opening the app.
 *
 * Talks to the deployed API over HTTPS, so it needs no database access and no
 * `railway run`: only the public endpoints the app itself uses.
 *
 * SAFETY: it never touches an existing household. It registers its own users
 * and creates its own household ("Muestras TD-001"), and it does NOT remove
 * anyone at the end — the departure is deliberately left as a write sample for
 * when the observation window closes.
 *
 * Usage:
 *   npx ts-node src/scripts/td001-sample-traffic.ts        # dry run, prints the plan
 *   npx ts-node src/scripts/td001-sample-traffic.ts --yes  # performs the calls
 *   API_BASE_URL=http://localhost:3000 npx ts-node ... --yes
 */
const DEFAULT_HOST = 'https://housetask-production.up.railway.app';
const HOUSEHOLD_NAME = 'Muestras TD-001';

/** Fixed so re-runs reuse the same two accounts instead of littering. */
const SAMPLE_USERS = [
  { email: 'td001-sample-1@homesync.test', name: 'Muestra TD-001 Uno' },
  { email: 'td001-sample-2@homesync.test', name: 'Muestra TD-001 Dos' },
];
const SAMPLE_PASSWORD = 'td001-sample-password';

/**
 * How many times to re-read the household surfaces. Each read is one more
 * dual-read comparison; the cap keeps the whole run inside the global rate
 * limit of 100 requests / 15 min / IP (app.ts's buildGlobalLimiter).
 */
const READ_ROUNDS = 6;

interface Session {
  email: string;
  accessToken: string;
  userId: string;
}

let baseUrl = `${process.env.API_BASE_URL ?? DEFAULT_HOST}/api`;
let performed = 0;
const failures: string[] = [];

async function call(
  method: string,
  path: string,
  options: { token?: string; body?: unknown; idempotent?: boolean } = {},
): Promise<{ status: number; body: unknown }> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (options.token) headers.Authorization = `Bearer ${options.token}`;
  if (options.idempotent) headers['Idempotency-Key'] = randomUUID();

  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  });

  const text = await res.text();
  let body: unknown = text;
  try {
    body = JSON.parse(text);
  } catch {
    // Non-JSON (a proxy error page, say) — keep the raw text for the log.
  }

  performed += 1;
  const label = `${method} ${path}`;
  logger.info(`  [${res.status}] ${label}`);
  if (res.status >= 400) failures.push(`${label} -> ${res.status}`);

  return { status: res.status, body };
}

function dataOf(body: unknown): Record<string, unknown> {
  const envelope = body as { data?: Record<string, unknown> };
  return envelope?.data ?? {};
}

/**
 * The token pair lives under `data.tokens`, not at the top of `data`:
 * auth.service returns `{ user: toPublicUser(user), tokens }` and the
 * controller wraps it in the standard envelope. Reading `data.accessToken`
 * yields undefined and every later call 401s.
 */
function sessionFrom(email: string, body: unknown): Session | null {
  const data = dataOf(body);
  const tokens = data.tokens as { accessToken?: string } | undefined;
  const user = data.user as { id?: string } | undefined;
  if (!tokens?.accessToken || !user?.id) return null;
  return { email, accessToken: tokens.accessToken, userId: user.id };
}

/**
 * Log in, registering only if the account does not exist yet.
 *
 * Login first, not register first: on every run after the first, register
 * would fail and still cost a request against the strict credential limiter
 * (5 per 15 min per IP, CLAUDE.md "Security rules"). Trying login first makes
 * a re-run cost one request per user instead of two.
 */
async function signIn(user: { email: string; name: string }): Promise<Session> {
  const loggedIn = await call('POST', '/auth/login', {
    body: { email: user.email, password: SAMPLE_PASSWORD },
  });
  const existing = sessionFrom(user.email, loggedIn.body);
  if (existing) return existing;

  const registered = await call('POST', '/auth/register', {
    body: { email: user.email, password: SAMPLE_PASSWORD, name: user.name },
  });
  const created = sessionFrom(user.email, registered.body);
  if (!created) {
    throw new Error(
      `Could not sign in ${user.email}: login and register both failed ` +
        `(register status ${registered.status})`,
    );
  }
  return created;
}

function plan(): string[] {
  return [
    `POST /auth/login x2     (${SAMPLE_USERS.map((u) => u.email).join(', ')}; registers them only if they do not exist)`,
    `POST /households        (creates "${HOUSEHOLD_NAME}", user 1 becomes admin)`,
    'POST /households/join   (user 2 joins with the invite code)',
    `GET  /households/:id, /members, /stats, /tasks, /shopping  x${READ_ROUNDS} rounds, both users`,
    'NO removal: the departure is kept as a write sample for when the window closes',
  ];
}

export async function generateSampleTraffic(): Promise<void> {
  logger.info(`Target: ${baseUrl}`);

  logger.info('Signing in the two sample users...');
  const one = await signIn(SAMPLE_USERS[0]);
  const two = await signIn(SAMPLE_USERS[1]);

  logger.info(`Creating the household "${HOUSEHOLD_NAME}"...`);
  const created = await call('POST', '/households', {
    token: one.accessToken,
    body: { name: HOUSEHOLD_NAME },
    idempotent: true,
  });
  const household = dataOf(created.body);
  const householdId = household.id as string;
  const inviteCode = household.inviteCode as string;

  if (!householdId) {
    throw new Error('Household creation did not return an id; aborting.');
  }
  logger.info(`  household ${householdId}, invite code ${inviteCode}`);

  logger.info('Second user joins by invite code...');
  await call('POST', '/households/join', {
    token: two.accessToken,
    body: { inviteCode },
    idempotent: true,
  });

  // Every one of these passes through requireMembership, which is where the
  // dual-read comparison lives. Alternating users exercises both the admin and
  // the plain-member branch of the comparison.
  logger.info(`Reading household surfaces, ${READ_ROUNDS} rounds...`);
  const paths = [
    `/households/${householdId}`,
    `/households/${householdId}/members`,
    `/households/${householdId}/stats`,
    `/households/${householdId}/tasks`,
    `/households/${householdId}/shopping`,
  ];

  for (let round = 0; round < READ_ROUNDS; round += 1) {
    const session = round % 2 === 0 ? one : two;
    for (const path of paths) {
      await call('GET', path, { token: session.accessToken });
    }
  }

  logger.info('');
  logger.info(`Household left ACTIVE on purpose: ${householdId}`);
  logger.info(
    `To close the window with a write sample: DELETE /households/${householdId}/members/${two.userId} as user 1.`,
  );
}

async function main(): Promise<void> {
  const confirmed = process.argv.includes('--yes');
  baseUrl = `${process.env.API_BASE_URL ?? DEFAULT_HOST}/api`;

  if (!confirmed) {
    logger.info(`Dry run — nothing sent. Target would be: ${baseUrl}`);
    for (const step of plan()) logger.info(`  ${step}`);
    logger.warn('Re-run with --yes to generate the traffic.');
    return;
  }

  try {
    await generateSampleTraffic();
  } catch (err) {
    logger.error('Sample traffic run failed', (err as Error).message);
    process.exitCode = 1;
  } finally {
    logger.info('');
    logger.info(`Requests performed: ${performed}`);
    if (failures.length > 0) {
      logger.warn(`Non-2xx responses (${failures.length}):`);
      for (const f of failures) logger.warn(`  ${f}`);
    } else {
      logger.info('All responses were 2xx.');
    }
  }
}

if (require.main === module) {
  void main();
}

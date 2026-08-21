import 'dotenv/config';
import { randomUUID } from 'crypto';
import { logger } from '../utils/logger';

/**
 * Close TD-001's phase-2 observation window by consuming a real write sample.
 *
 * WHY THIS EXISTS
 *
 * The go/no-go for the cutover is a number — zero dual-read divergences under
 * real traffic — and reads alone do not test it. A hole in the dual WRITE path
 * only becomes visible in the reads that follow a write, so the window cannot
 * be closed without performing one. `td001-sample-traffic.ts` generated the
 * reads and deliberately left the second sample user inside the household as
 * the write sample to spend here.
 *
 * On 2026-08-21 that reserved membership turned out to be GONE — absent from
 * the embedded array, from `User.households` and from the mirror collection,
 * all three in agreement — with no way to tell whether an earlier unrecorded
 * DELETE or a `join` that never happened produced it. Rather than close the
 * window on that ambiguity, this script regenerates the sample and spends it:
 *
 *     join -> reads -> DELETE -> reads
 *
 * That exercises BOTH dual-write paths (`mirrorMemberAdded` on the join and
 * the transactional `removeMemberInTransaction` on the removal), not just the
 * removal, and it is self-undoing: the household ends with exactly the members
 * it started with, so the script is safe to re-run.
 *
 * READING THE RESULT
 *
 * A divergence is reported by `requireMembership`'s `verifyMembershipMirror`
 * as a `logger.warn` (visible in Railway) plus a Sentry event tagged
 * `td001_dual_read`. Note the asymmetry, learned the hard way:
 *
 *   - Log SILENCE does not prove a request never ran. The API has no request
 *     logging and `errorHandler` only records 5xx, so a successful removal on
 *     a household without pending tasks writes zero lines.
 *   - Log silence DOES prove there was no divergence, because `logger.warn`
 *     reaches `console.warn` unfiltered in production (`utils/logger.ts` only
 *     silences `debug`).
 *
 * So after running this, check:
 *     railway logs -s Housetask --lines 1000 -d | grep -i "divergence|WARN|ERROR"
 * and search Sentry for the `td001_dual_read` category. Both must be empty.
 *
 * SAFETY
 *
 * Touches only the dedicated household "Muestras TD-001" and the two
 * `@homesync.test` sample accounts created by `td001-sample-traffic.ts`. It
 * never touches a real household, and it aborts if the target user id does not
 * match the one on record. Talks to the deployed API over HTTPS, so it needs
 * no database access and no `railway run`.
 *
 * Usage:
 *   npx ts-node src/scripts/td001-close-window.ts        # dry run, prints the plan and current state
 *   npx ts-node src/scripts/td001-close-window.ts --yes  # performs the join/DELETE cycle
 *   API_BASE_URL=http://localhost:3000 npx ts-node src/scripts/td001-close-window.ts --yes
 */
const DEFAULT_HOST = 'https://housetask-production.up.railway.app';
const HOUSEHOLD_NAME = 'Muestras TD-001';

/** The household `td001-sample-traffic.ts` created on 2026-08-18. */
const HOUSEHOLD_ID = '6a84e3ff6f8391134ebe9dde';

/**
 * The reserved target, on record in docs/NEXT_SESSION_MAC.md. Checked rather
 * than trusted: if the sample accounts are ever recreated the ids change, and
 * silently removing a different member would be much worse than aborting.
 */
const EXPECTED_TARGET_ID = '6a84e33d6f8391134ebe9dd0';

const SAMPLE_PASSWORD = 'td001-sample-password';
const ADMIN_EMAIL = 'td001-sample-1@homesync.test';
const TARGET_EMAIL = 'td001-sample-2@homesync.test';

interface Envelope {
  data?: Record<string, unknown>;
}

interface CallOptions {
  token?: string;
  body?: unknown;
  idempotent?: boolean;
}

let baseUrl = `${process.env.API_BASE_URL ?? DEFAULT_HOST}/api`;
let performed = 0;
const failures: string[] = [];

async function call(
  method: string,
  path: string,
  options: CallOptions = {},
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
  logger.info(`  [${res.status}] ${new Date().toISOString()} ${label}`);
  // The closing 403 is the assertion, not a failure: it proves the removed
  // member can no longer read the household.
  if (res.status >= 400 && res.status !== 403) failures.push(`${label} -> ${res.status}`);

  return { status: res.status, body };
}

function dataOf(body: unknown): Record<string, unknown> {
  return (body as Envelope)?.data ?? {};
}

interface Member {
  user?: { id?: string; email?: string };
  role?: string;
}

function membersOf(household: Record<string, unknown>): Member[] {
  return (household.members as Member[]) ?? [];
}

function describeMembers(household: Record<string, unknown>): string {
  return membersOf(household)
    .map((m) => `${m.user?.email ?? 'unknown'}(${m.role ?? '?'})`)
    .join(', ');
}

/**
 * Sign in an existing sample account. Unlike `td001-sample-traffic.ts` this
 * never registers: by the time the window closes both accounts must already
 * exist, and creating one here would mean the household is not the one the
 * window observed.
 */
async function signIn(email: string): Promise<{ token: string; userId: string }> {
  const res = await call('POST', '/auth/login', {
    body: { email, password: SAMPLE_PASSWORD },
  });
  const data = dataOf(res.body);
  const tokens = data.tokens as { accessToken?: string } | undefined;
  const user = data.user as { id?: string } | undefined;
  if (!tokens?.accessToken || !user?.id) {
    throw new Error(`Could not sign in ${email} (status ${res.status}).`);
  }
  return { token: tokens.accessToken, userId: user.id };
}

export async function closeObservationWindow(apply: boolean): Promise<void> {
  logger.info(`Target: ${baseUrl}`);
  logger.info(apply ? 'MODE: APPLY' : 'MODE: DRY RUN (no writes will be sent)');

  // Two logins is the whole budget worth spending here: the credential
  // limiter allows 5 per 15 min per IP (CLAUDE.md "Security rules").
  logger.info('1. Signing in both sample accounts...');
  const admin = await signIn(ADMIN_EMAIL);
  const target = await signIn(TARGET_EMAIL);

  if (target.userId !== EXPECTED_TARGET_ID) {
    throw new Error(
      `Target id ${target.userId} does not match the one on record ` +
        `(${EXPECTED_TARGET_ID}); aborting rather than removing the wrong member.`,
    );
  }
  logger.info(`   target ${target.userId} matches docs/NEXT_SESSION_MAC.md`);

  logger.info('2. Reading the household (dual-read sample, and the precondition check)...');
  const before = await call('GET', `/households/${HOUSEHOLD_ID}`, { token: admin.token });
  if (before.status !== 200) {
    throw new Error(`Could not read ${HOUSEHOLD_ID} (status ${before.status}).`);
  }
  const household = dataOf(before.body);
  if (household.name !== HOUSEHOLD_NAME) {
    throw new Error(`Household ${HOUSEHOLD_ID} is "${household.name}", not "${HOUSEHOLD_NAME}".`);
  }
  const inviteCode = household.inviteCode as string;
  logger.info(`   "${household.name}" members: [${describeMembers(household)}]`);

  const alreadyMember = membersOf(household).some((m) => m.user?.id === target.userId);
  logger.info(
    alreadyMember
      ? '   target IS a member: the reserved write sample is intact and will be spent as-is.'
      : '   target is NOT a member: the reserved sample is gone, so it gets regenerated first.',
  );

  if (!apply) {
    logger.info('');
    logger.info('DRY RUN — would run:');
    if (!alreadyMember) logger.info(`  POST   /households/join (code ${inviteCode}) as the target`);
    logger.info('  GET    household surfaces x4        (dual-read samples, both roles)');
    logger.info(`  DELETE /households/${HOUSEHOLD_ID}/members/${target.userId}`);
    logger.info('  GET    household surfaces x4        (post-write dual-read samples)');
    logger.warn('Re-run with --yes to close the window.');
    return;
  }

  if (!alreadyMember) {
    logger.info('3. Regenerating the write sample: target joins (dual write)...');
    const joined = await call('POST', '/households/join', {
      token: target.token,
      body: { inviteCode },
      idempotent: true,
    });
    if (joined.status >= 400) {
      throw new Error(`Join failed (${joined.status}).`);
    }
    logger.info(`   members now: [${describeMembers(dataOf(joined.body))}]`);
  }

  // Both roles, because verifyMembershipMirror compares the caller's own role
  // as well as the whole member set.
  logger.info('4. Dual-read samples with both members present...');
  await call('GET', `/households/${HOUSEHOLD_ID}`, { token: admin.token });
  await call('GET', `/households/${HOUSEHOLD_ID}/members`, { token: admin.token });
  await call('GET', `/households/${HOUSEHOLD_ID}`, { token: target.token });
  await call('GET', `/households/${HOUSEHOLD_ID}/stats`, { token: target.token });

  logger.info('5. THE WRITE SAMPLE — transactional removal...');
  const removed = await call('DELETE', `/households/${HOUSEHOLD_ID}/members/${target.userId}`, {
    token: admin.token,
  });
  if (removed.status !== 200) {
    throw new Error(`DELETE failed (${removed.status}).`);
  }
  logger.info(`   members now: [${describeMembers(dataOf(removed.body))}]`);

  // This is the half that actually measures the write: a hole opened by the
  // removal is invisible until something reads through requireMembership again.
  logger.info('6. Post-write dual-read samples...');
  await call('GET', `/households/${HOUSEHOLD_ID}`, { token: admin.token });
  await call('GET', `/households/${HOUSEHOLD_ID}/members`, { token: admin.token });
  await call('GET', `/households/${HOUSEHOLD_ID}/stats`, { token: admin.token });
  await call('GET', `/households/${HOUSEHOLD_ID}/tasks`, { token: admin.token });

  // Reuses the target's existing access token instead of logging in again: a
  // stateless JWT stays valid after the removal (TD-054), so the 403 comes
  // from requireMembership reading the membership authority — which is the
  // point being proved.
  logger.info('7. Confirming the removal from the removed member side...');
  const forbidden = await call('GET', `/households/${HOUSEHOLD_ID}`, { token: target.token });
  if (forbidden.status !== 403) {
    throw new Error(`Expected 403 for the removed member, got ${forbidden.status}.`);
  }

  logger.info('');
  logger.info(`Command of record: DELETE /households/${HOUSEHOLD_ID}/members/${target.userId}`);
}

async function main(): Promise<void> {
  const confirmed = process.argv.includes('--yes');
  baseUrl = `${process.env.API_BASE_URL ?? DEFAULT_HOST}/api`;

  try {
    await closeObservationWindow(confirmed);
  } catch (err) {
    logger.error('Window closing run failed', (err as Error).message);
    process.exitCode = 1;
  } finally {
    logger.info('');
    logger.info(`Requests performed: ${performed}`);
    if (failures.length > 0) {
      logger.warn(`Unexpected non-2xx responses (${failures.length}):`);
      for (const f of failures) logger.warn(`  ${f}`);
    } else {
      logger.info('No unexpected non-2xx responses.');
    }
    logger.info('Now verify BOTH channels are empty:');
    logger.info('  railway logs -s Housetask --lines 1000 -d | grep -iE "divergence|WARN|ERROR"');
    logger.info('  Sentry: search the `td001_dual_read` category');
  }
}

if (require.main === module) {
  void main();
}

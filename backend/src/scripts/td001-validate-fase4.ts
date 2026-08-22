import 'dotenv/config';
import { randomUUID } from 'crypto';
import { Types } from 'mongoose';
import { connectDatabase, disconnectDatabase } from '../config/database';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { HouseholdModel } from '../models/Household';
import { UserModel } from '../models/User';
import { logger } from '../utils/logger';

/**
 * Post-deploy validation for TD-001 phase 3 (cutover), during the phase-4
 * observation window.
 *
 * WHY THIS EXISTS
 *
 * The cutover made the HouseholdMember collection the authority for every
 * HTTP read. Nothing in production exercises that on demand — the owner would
 * otherwise have to drive two devices by hand — so this generates the traffic
 * and, unlike `td001-sample-traffic.ts`, ASSERTS the invariants instead of just
 * producing requests for something else to observe.
 *
 * It is deliberately not a test suite: the suite already proves the logic
 * against an in-memory MongoDB. What this proves is different and cannot be
 * faked locally — that the deployed build, against real Atlas data with the
 * real indexes, still upholds them.
 *
 * WHAT IT CHECKS
 *
 *   - `serializeHousehold` orders members by `joinedAt` (the ordering the
 *     embedded array used to give for free; an unsorted index scan would
 *     reshuffle every member list in the app without changing a field).
 *   - Hard Rule 9: the last admin cannot be removed, now that the admin count
 *     is a `countDocuments` on the collection rather than a filter in memory.
 *   - `join` is idempotent and does not duplicate a membership.
 *   - `getHouseholdStats` builds `memberStats` from the same authority, in the
 *     same order.
 *   - Re-joining after a removal works (the `$setOnInsert` upsert lands on a
 *     row that was deleted, not on a surviving one).
 *   - Every response carries the status code the contract promises.
 *
 * A NOTE ON "DIVERGENCES"
 *
 * Before the cutover, a divergence was a `td001_dual_read` event: the two
 * copies disagreeing. That comparison no longer exists — commit 5 removed it,
 * because there is no second opinion left to compare against. So searching
 * Sentry for `td001_dual_read` after this deploy will correctly find nothing,
 * and that is not evidence of health. From here on, a divergence is a FAILED
 * CHECK below: the deployed API not answering what the contract says.
 *
 * WHAT IT CANNOT COVER — see the closing summary; those need two real clients.
 *
 * SAFETY
 *
 * Touches only the dedicated household "Muestras TD-001" and the two
 * `@homesync.test` sample accounts. It aborts rather than guess if either is
 * missing, and every iteration ends by removing the second account again, so
 * the household is left exactly as it was found.
 *
 * Usage:
 *   npx ts-node src/scripts/td001-validate-fase4.ts                 # dry run (default)
 *   npx ts-node src/scripts/td001-validate-fase4.ts --execute
 *   npx ts-node src/scripts/td001-validate-fase4.ts --execute --iterations=5
 *   npx ts-node src/scripts/td001-validate-fase4.ts --check-socket-source   # read-only DB audit, no traffic
 *   npx ts-node src/scripts/td001-validate-fase4.ts --check-orphan-households # read-only, households with no members
 *   npx ts-node src/scripts/td001-validate-fase4.ts --execute --check-socket-source
 *   API_BASE_URL=http://localhost:3000 npx ts-node src/scripts/td001-validate-fase4.ts --execute
 *
 * If the sample accounts or the household do not exist yet, create them first
 * with:  npx ts-node src/scripts/td001-sample-traffic.ts --yes
 */
const DEFAULT_HOST = 'https://housetask-production.up.railway.app';
const HOUSEHOLD_NAME = 'Muestras TD-001';
const HOUSEHOLD_ID = '6a84e3ff6f8391134ebe9dde';

const SAMPLE_PASSWORD = 'td001-sample-password';
const ADMIN_EMAIL = 'td001-sample-1@homesync.test';
const MEMBER_EMAIL = 'td001-sample-2@homesync.test';

const DEFAULT_ITERATIONS = 10;
const REQUESTS_PER_ITERATION = 6;

/**
 * `app.ts`'s buildGlobalLimiter: 100 requests / 15 min / IP across every
 * `/api` route. Only `/api/auth/register` and `/api/auth/login` are skipped,
 * so the two logins are free against THIS budget (they answer to the stricter
 * 5-per-15-min credential limiter instead). Staying under it matters: blowing
 * the budget turns the rest of the run into a wall of 429s that looks like a
 * failure of the thing being validated.
 */
const GLOBAL_LIMIT_PER_WINDOW = 100;
const BUDGET_HEADROOM = 20;

interface Session {
  email: string;
  token: string;
  userId: string;
  /** `User.households` — the array the SOCKET handshake resolves rooms from. */
  households: string[];
}

interface MemberView {
  user: { id: string; name?: string; email?: string };
  role: string;
  joinedAt: string;
}

interface CheckResult {
  iteration: number;
  label: string;
  ok: boolean;
  detail: string;
}

let baseUrl = `${process.env.API_BASE_URL ?? DEFAULT_HOST}/api`;
let performed = 0;
let rateLimited = false;
const statusCounts = new Map<number, number>();
const checks: CheckResult[] = [];
let currentIteration = 0;

function record(label: string, ok: boolean, detail: string): void {
  checks.push({ iteration: currentIteration, label, ok, detail });
  const mark = ok ? 'PASS' : 'FAIL';
  const line = `    [${mark}] ${label}${detail ? ` — ${detail}` : ''}`;
  if (ok) {
    logger.info(line);
  } else {
    logger.warn(line);
  }
}

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
  statusCounts.set(res.status, (statusCounts.get(res.status) ?? 0) + 1);

  if (res.status === 429) rateLimited = true;
  // An expired access token mid-run would make every later check fail for a
  // reason that has nothing to do with the cutover. Surface it as itself.
  if (res.status === 401) {
    throw new Error(
      `401 on ${method} ${path}: the access token expired (15 min). Re-run the script.`,
    );
  }

  return { status: res.status, body };
}

function dataOf(body: unknown): Record<string, unknown> {
  return (body as { data?: Record<string, unknown> })?.data ?? {};
}

function membersOf(payload: Record<string, unknown>): MemberView[] {
  return (payload.members as MemberView[]) ?? [];
}

function idsOf(members: MemberView[]): string[] {
  return members.map((m) => m.user?.id);
}

/**
 * The ordering invariant, checked as a property of whatever came back rather
 * than against a hardcoded expected list: the sort must hold for any member
 * set, not just for the two this script happens to use.
 */
function isSortedByJoinedAt(members: MemberView[]): boolean {
  for (let i = 1; i < members.length; i += 1) {
    if (new Date(members[i - 1].joinedAt).getTime() > new Date(members[i].joinedAt).getTime()) {
      return false;
    }
  }
  return true;
}

async function signIn(email: string): Promise<Session> {
  const res = await call('POST', '/auth/login', { body: { email, password: SAMPLE_PASSWORD } });
  const data = dataOf(res.body);
  const tokens = data.tokens as { accessToken?: string } | undefined;
  const user = data.user as { id?: string; households?: string[] } | undefined;
  if (!tokens?.accessToken || !user?.id) {
    throw new Error(
      `Could not sign in ${email} (status ${res.status}). ` +
        'If the sample accounts do not exist yet, create them with: ' +
        'npx ts-node src/scripts/td001-sample-traffic.ts --yes',
    );
  }
  return {
    email,
    token: tokens.accessToken,
    userId: user.id,
    households: user.households ?? [],
  };
}

/**
 * One self-contained cycle. It starts and ends with the member OUT of the
 * household, so iterations do not depend on each other and an aborted run
 * leaves nothing behind. Each step is labelled with the letter it covers in
 * the validation plan.
 */
async function runIteration(admin: Session, member: Session, n: number): Promise<void> {
  currentIteration = n;
  logger.info(`  Iteration ${n}:`);

  // (a) join — from iteration 2 on this is also the "re-join after removal"
  // case, which lands the upsert on a row that was deleted rather than on a
  // surviving one.
  const joined = await call('POST', '/households/join', {
    token: member.token,
    body: { inviteCode: await inviteCode(admin) },
    idempotent: true,
  });
  record('join returns 200', joined.status === 200, `got ${joined.status}`);
  const afterJoin = membersOf(dataOf(joined.body));
  record(
    'join response contains both members',
    idsOf(afterJoin).sort().join() === [admin.userId, member.userId].sort().join(),
    `[${idsOf(afterJoin).join(', ')}]`,
  );

  // (f) idempotency — a second join must not duplicate the membership.
  const rejoined = await call('POST', '/households/join', {
    token: member.token,
    body: { inviteCode: await inviteCode(admin) },
    idempotent: true,
  });
  const afterRejoin = membersOf(dataOf(rejoined.body));
  record('re-join returns 200', rejoined.status === 200, `got ${rejoined.status}`);
  record(
    'join is idempotent (no duplicate membership)',
    afterRejoin.length === 2 && idsOf(afterRejoin).filter((id) => id === member.userId).length === 1,
    `${afterRejoin.length} members, target appears ` +
      `${idsOf(afterRejoin).filter((id) => id === member.userId).length}x`,
  );

  // (b) GET household — serializeHousehold off the collection.
  const read = await call('GET', `/households/${HOUSEHOLD_ID}`, { token: admin.token });
  record('GET household returns 200', read.status === 200, `got ${read.status}`);
  const readMembers = membersOf(dataOf(read.body));
  record('members are ordered by joinedAt', isSortedByJoinedAt(readMembers), orderDetail(readMembers));
  record(
    'admin still sorts first (joined earliest)',
    readMembers[0]?.user?.id === admin.userId,
    `first is ${readMembers[0]?.user?.id}`,
  );

  // (c) GET stats — getHouseholdStats off the same authority.
  const stats = await call('GET', `/households/${HOUSEHOLD_ID}/stats`, { token: admin.token });
  record('GET stats returns 200', stats.status === 200, `got ${stats.status}`);
  const statIds = ((dataOf(stats.body).memberStats as { userId: string }[]) ?? []).map(
    (m) => m.userId,
  );
  record(
    'stats memberStats matches the household members, in the same order',
    statIds.join() === idsOf(readMembers).join(),
    `stats [${statIds.join(', ')}] vs household [${idsOf(readMembers).join(', ')}]`,
  );

  // (d) Hard Rule 9 — the admin is the household's only one, so removing them
  // must be refused. This is the check that most matters after the cutover:
  // the count behind it moved from an in-memory filter to a collection query.
  const lastAdmin = await call(
    'DELETE',
    `/households/${HOUSEHOLD_ID}/members/${admin.userId}`,
    { token: admin.token },
  );
  record('Hard Rule 9: removing the last admin returns 400', lastAdmin.status === 400,
    `got ${lastAdmin.status}`);
  record(
    'Hard Rule 9: the refusal names the reason',
    (lastAdmin.body as { error?: string })?.error === 'Cannot remove the last admin of the household',
    String((lastAdmin.body as { error?: string })?.error),
  );

  // (e) removeMember — the valid one, which also restores the starting state.
  const removed = await call(
    'DELETE',
    `/households/${HOUSEHOLD_ID}/members/${member.userId}`,
    { token: admin.token },
  );
  record('removeMember returns 200', removed.status === 200, `got ${removed.status}`);
  const afterRemove = membersOf(dataOf(removed.body));
  record(
    'removed member is gone from the response',
    idsOf(afterRemove).join() === admin.userId,
    `[${idsOf(afterRemove).join(', ')}]`,
  );
}

function orderDetail(members: MemberView[]): string {
  return members.map((m) => `${m.user?.id}@${m.joinedAt}`).join(' < ');
}

/**
 * Cached: the invite code does not change, and re-reading the household to get
 * it would double this script's cost against the rate-limit budget.
 */
let cachedInviteCode: string | null = null;
async function inviteCode(admin: Session): Promise<string> {
  if (cachedInviteCode) return cachedInviteCode;
  const res = await call('GET', `/households/${HOUSEHOLD_ID}`, { token: admin.token });
  const data = dataOf(res.body);
  if (data.name !== HOUSEHOLD_NAME) {
    throw new Error(
      `Household ${HOUSEHOLD_ID} is "${String(data.name)}", not "${HOUSEHOLD_NAME}" — ` +
        'refusing to run against a household that is not the dedicated sample.',
    );
  }
  cachedInviteCode = data.inviteCode as string;
  return cachedInviteCode;
}

function plan(iterations: number): string[] {
  return [
    `POST /auth/login x2            (${ADMIN_EMAIL}, ${MEMBER_EMAIL}) — exempt from the /api budget`,
    `GET  /households/${HOUSEHOLD_ID}   once, to read the invite code and confirm the household`,
    '',
    `Then ${iterations} iterations of 6 requests each:`,
    '  (a) POST   /households/join                       expect 200, both members present',
    '  (f) POST   /households/join            again      expect 200, still 2 members, no duplicate',
    '  (b) GET    /households/:id                        expect 200, members sorted by joinedAt',
    '  (c) GET    /households/:id/stats                  expect 200, memberStats matches, same order',
    '  (d) DELETE /households/:id/members/<admin>        expect 400, Hard Rule 9 refusal',
    '  (e) DELETE /households/:id/members/<member>       expect 200, member gone',
    '',
    'Each iteration ends with the household exactly as it started: admin only.',
  ];
}

function printSummary(iterations: number, executed: boolean): void {
  const failed = checks.filter((c) => !c.ok);

  logger.info('');
  logger.info('='.repeat(72));
  logger.info('SUMMARY');
  logger.info('='.repeat(72));
  logger.info(`Requests performed:   ${performed}`);

  if (statusCounts.size > 0) {
    const histogram = [...statusCounts.entries()]
      .sort(([a], [b]) => a - b)
      .map(([status, count]) => `${status} x${count}`)
      .join('   ');
    logger.info(`Status codes:         ${histogram}`);
  }

  if (executed) {
    logger.info(`Checks run:           ${checks.length} over ${iterations} iteration(s)`);
    logger.info(`Checks passed:        ${checks.length - failed.length}`);
    if (failed.length === 0) {
      logger.info('Divergences:          NONE');
    } else {
      logger.warn(`Divergences:          ${failed.length} FAILED CHECK(S)`);
      for (const f of failed) {
        logger.warn(`  iteration ${f.iteration}: ${f.label} — ${f.detail}`);
      }
    }
  }

  if (rateLimited) {
    logger.warn('');
    logger.warn('A 429 was returned: the global limiter is 100 requests / 15 min / IP.');
    logger.warn('Results after that point are meaningless. Wait 15 minutes and re-run,');
    logger.warn('or use --iterations=N with a smaller N.');
  }

  logger.info('');
  logger.info('-'.repeat(72));
  logger.info('WHAT THIS SCRIPT CANNOT COVER — requires manual validation with two clients');
  logger.info('-'.repeat(72));
  logger.info('These are NOT validated above, and a green run says nothing about them:');
  logger.info('');
  logger.info('  1. Socket rooms. The handshake still resolves rooms from User.households');
  logger.info('     (config/socket.ts), NOT from HouseholdMember — that moves in commit 7.');
  logger.info('     So HTTP reads and realtime delivery currently use DIFFERENT sources.');
  logger.info('     A room-joining regression would be invisible to every check above.');
  logger.info('     Manual: two logged-in devices in one household; change a task on A and');
  logger.info('     confirm B updates live without a refresh.');
  logger.info('');
  logger.info('  2. Realtime propagation of membership changes. `household:member_joined`');
  logger.info('     and `household:member_left` are emitted by the same service calls this');
  logger.info('     script makes, but this script has no socket connected, so it cannot');
  logger.info('     observe whether they ARRIVE.');
  logger.info('     Manual: with B watching, remove B from A and confirm B reacts.');
  logger.info('');
  logger.info('  3. Push notifications (FCM). Still blocked on TD-049 regardless — no real');
  logger.info('     Firebase project is connected, so every send is a logged no-op.');
  logger.info('');
  logger.info('  4. The Flutter client itself. The cutover promises the wire contract did');
  logger.info('     not change; this script verifies the SHAPE the API returns, not that');
  logger.info('     the app parses it. Manual: open Perfil and the assignee selector.');
  logger.info('');
  logger.info('Also note: searching Sentry for `td001_dual_read` will now find nothing,');
  logger.info('because commit 5 removed the comparison that emitted it. That silence is');
  logger.info('expected and is NOT evidence of health — the checks above are.');
}

export async function validate(iterations: number, execute: boolean): Promise<void> {
  logger.info(`Target: ${baseUrl}`);
  logger.info(execute ? 'MODE: EXECUTE' : 'MODE: DRY RUN (no requests will be sent)');
  logger.info('');

  const projected = iterations * REQUESTS_PER_ITERATION + 1;
  logger.info(
    `Projected /api requests: ${projected} of the ${GLOBAL_LIMIT_PER_WINDOW} allowed per 15 min ` +
      '(the 2 logins are exempt).',
  );
  if (projected > GLOBAL_LIMIT_PER_WINDOW - BUDGET_HEADROOM) {
    logger.warn(
      `That leaves under ${BUDGET_HEADROOM} spare. Use --iterations=N to lower it, or the ` +
        'run may end in 429s that look like failures.',
    );
  }

  if (!execute) {
    logger.info('');
    logger.info('Would run:');
    for (const step of plan(iterations)) logger.info(`  ${step}`);
    logger.info('');
    logger.warn('Re-run with --execute to generate the traffic.');
    printSummary(iterations, false);
    return;
  }

  logger.info('');
  logger.info('Signing in the two sample accounts...');
  const admin = await signIn(ADMIN_EMAIL);
  const member = await signIn(MEMBER_EMAIL);
  logger.info(`  admin  ${admin.userId} (${admin.email})`);
  logger.info(`  member ${member.userId} (${member.email})`);

  // Also confirms the household is the dedicated sample before anything writes.
  const code = await inviteCode(admin);
  logger.info(`  household ${HOUSEHOLD_ID} "${HOUSEHOLD_NAME}", invite code ${code}`);
  logger.info('');

  for (let n = 1; n <= iterations; n += 1) {
    await runIteration(admin, member, n);
    if (rateLimited) {
      logger.warn(`  Stopping after iteration ${n}: the rate limiter kicked in.`);
      break;
    }
  }

  printSummary(iterations, true);
}

/**
 * The membership sources a single user is described by, right now.
 *
 * Three, not two: the dual write still maintains all of them, and they answer
 * three different questions. `collection` is the authority for every HTTP read
 * since the cutover. `userHouseholds` is what the SOCKET handshake resolves
 * rooms from (`config/socket.ts` does `UserModel.findById(...).select('households')`)
 * and does not move to the collection until commit 7. `embedded` is the
 * rollback net that commit 6 stops writing.
 */
interface MembershipSources {
  email: string;
  userId: string;
  collection: Set<string>;
  userHouseholds: Set<string>;
  embedded: Set<string>;
}

function sortedIds(set: Set<string>): string {
  return [...set].sort().join(', ') || '(none)';
}

function difference(a: Set<string>, b: Set<string>): string[] {
  return [...a].filter((id) => !b.has(id)).sort();
}

/**
 * Read every membership representation for one user. Strictly read-only: this
 * function issues nothing but `find`/`findOne`, because an audit that repairs
 * what it measures destroys the evidence it was run to collect.
 */
async function readSources(email: string): Promise<MembershipSources | null> {
  const user = await UserModel.findOne({ email }).select('households').lean();
  if (!user) return null;

  const userId = user._id.toString();

  const [rows, embeddedHouseholds] = await Promise.all([
    HouseholdMemberModel.find({ userId: new Types.ObjectId(userId) })
      .select('householdId')
      .lean(),
    HouseholdModel.find({ 'members.user': new Types.ObjectId(userId) })
      .select('_id')
      .lean(),
  ]);

  return {
    email,
    userId,
    collection: new Set(rows.map((r) => r.householdId.toString())),
    userHouseholds: new Set((user.households ?? []).map((h) => h.toString())),
    embedded: new Set(embeddedHouseholds.map((h) => h._id.toString())),
  };
}

/**
 * Compare one user's sources and report. Returns true when they agree.
 *
 * The two divergence directions are NOT symmetric in consequence, so they are
 * named rather than merged into one "mismatch" count:
 *
 *   - In the collection but NOT in User.households: HTTP works, the socket
 *     never joins the room. The user loads correct data that then never
 *     updates live — the silent one, indistinguishable from "nothing is
 *     happening" unless someone watches two clients at once.
 *   - In User.households but NOT in the collection: the socket joins a room
 *     for a household every HTTP read answers 403 for. Noisy, and it also
 *     means realtime events are being delivered to someone the authority says
 *     is not a member.
 */
function compareSources(s: MembershipSources): boolean {
  const onlyCollection = difference(s.collection, s.userHouseholds);
  const onlyUser = difference(s.userHouseholds, s.collection);
  const embeddedDrift = [
    ...difference(s.collection, s.embedded).map((id) => `${id} (missing from embedded array)`),
    ...difference(s.embedded, s.collection).map((id) => `${id} (stale in embedded array)`),
  ];

  const agreed = onlyCollection.length === 0 && onlyUser.length === 0;

  logger.info(`  ${s.email}  (${s.userId})`);
  logger.info(`    HouseholdMember.find({userId}) : ${sortedIds(s.collection)}`);
  logger.info(`    User.households                : ${sortedIds(s.userHouseholds)}`);

  if (agreed) {
    logger.info('    -> sources agree');
  } else {
    logger.warn('    -> CRITICAL FAILURE: the two sources disagree');
    for (const id of onlyCollection) {
      logger.warn(
        `       ${id}: in the COLLECTION but NOT in User.households — ` +
          'HTTP reads work, the socket never joins the room (silent: data loads, never updates live)',
      );
    }
    for (const id of onlyUser) {
      logger.warn(
        `       ${id}: in User.households but NOT in the COLLECTION — ` +
          'the socket joins a room for a household every HTTP read answers 403 for',
      );
    }
  }

  // Beyond the requested scope, but free while connected and it is what
  // commit 6 removes: if the rollback net has drifted, rolling back would
  // restore a wrong member list.
  if (embeddedDrift.length > 0) {
    logger.warn(`    -> note: the embedded rollback array has drifted: ${embeddedDrift.join('; ')}`);
  }

  return agreed;
}

/**
 * `--check-socket-source`: audit the one risk the HTTP checks are blind to.
 *
 * Between commits 5 and 7 two sources of truth are live at once — HTTP reads
 * the collection, the socket handshake reads `User.households` — so they can
 * drift apart without any endpoint answering wrongly. This reads both
 * directly from MongoDB rather than probing over HTTP, because the collection
 * side cannot be enumerated through the API: there is no "my households"
 * endpoint, only per-household membership answers, so an HTTP-only version
 * could never see a household it had not already been told about.
 *
 * Read-only, and it needs MONGODB_URI (the other td001 scripts deliberately do
 * not; this one cannot answer the question without it).
 */
/**
 * HTTP-only fallback, used when MongoDB is unreachable (no credentials, or a
 * network that cannot resolve the SRV record).
 *
 * `User.households` comes back on the login response (`toPublicUser` includes
 * it). The collection side has no enumeration endpoint, but it does have an
 * oracle: `requireMembership` reads the collection, so `GET /households/:id`
 * answering 200 means the collection holds the membership and 403 means it
 * does not.
 *
 * The limitation is real and worth stating plainly: this can only ask about
 * households it already knows of — the union of `User.households` and the
 * sample household. For these two fixture accounts that union is exhaustive,
 * because they have never belonged to anything else, so the answer is complete
 * FOR THEM. It cannot sweep other accounts, which is where a drift would
 * actually matter. That is why this is a fallback and not the design.
 */
async function httpSocketSourceProbe(): Promise<boolean> {
  logger.info('Falling back to an HTTP-only probe of the sample accounts.');
  logger.info('');

  let allAgreed = true;

  for (const email of [ADMIN_EMAIL, MEMBER_EMAIL]) {
    const session = await signIn(email);
    const userHouseholds = new Set(session.households);
    const candidates = new Set([...session.households, HOUSEHOLD_ID]);
    const collection = new Set<string>();

    for (const id of candidates) {
      const res = await call('GET', `/households/${id}`, { token: session.token });
      if (res.status === 200) collection.add(id);
    }

    const onlyCollection = difference(collection, userHouseholds);
    const onlyUser = difference(userHouseholds, collection);

    logger.info(`  ${email}  (${session.userId})`);
    logger.info(`    collection (via GET /households/:id) : ${sortedIds(collection)}`);
    logger.info(`    User.households (via login response) : ${sortedIds(userHouseholds)}`);

    if (onlyCollection.length === 0 && onlyUser.length === 0) {
      logger.info('    -> sources agree');
    } else {
      allAgreed = false;
      logger.warn('    -> CRITICAL FAILURE: the two sources disagree');
      for (const id of onlyCollection) {
        logger.warn(
          `       ${id}: in the COLLECTION but NOT in User.households — ` +
            'HTTP reads work, the socket never joins the room (silent: data loads, never updates live)',
        );
      }
      for (const id of onlyUser) {
        logger.warn(
          `       ${id}: in User.households but NOT in the COLLECTION — ` +
            'the socket joins a room for a household every HTTP read answers 403 for',
        );
      }
    }
  }

  logger.info('');
  if (allAgreed) {
    logger.info('Socket source check: PASS (PARTIAL) — the 2 sample accounts are synchronized.');
    logger.warn('Coverage is PARTIAL: other accounts were not audited. Re-run with a working');
    logger.warn('MONGODB_URI for the full sweep, which is where a real drift would show.');
  } else {
    logger.warn('Socket source check: FAIL — see the divergences above.');
  }
  return allAgreed;
}

async function checkSocketSource(): Promise<boolean> {
  logger.info('');
  logger.info('='.repeat(72));
  logger.info('SOCKET SOURCE CHECK — HouseholdMember vs User.households');
  logger.info('='.repeat(72));
  logger.info('Read-only. Connecting to MongoDB directly: the collection side has no');
  logger.info('HTTP surface that can enumerate it.');
  logger.info('');

  try {
    await connectDatabase();
  } catch (err) {
    // Degrade rather than abort. A missing or stale MONGODB_URI is an
    // operator problem, not a finding about the cutover, and answering for
    // the sample accounts is worth more than answering for nothing.
    logger.warn(`MongoDB is unreachable: ${(err as Error).message}`);
    logger.warn('');
    return httpSocketSourceProbe();
  }

  try {
    logger.info('Sample accounts:');
    let allAgreed = true;
    let audited = 0;

    for (const email of [ADMIN_EMAIL, MEMBER_EMAIL]) {
      const sources = await readSources(email);
      if (!sources) {
        logger.warn(`  ${email}: no such user — create it with td001-sample-traffic.ts --yes`);
        allAgreed = false;
        continue;
      }
      audited += 1;
      if (!compareSources(sources)) allAgreed = false;
    }

    // The sample accounts are a fixture; they have only ever belonged to the
    // sample household. A drift that mattered would be on a REAL account, so
    // auditing only the fixture would answer a question nobody asked.
    logger.info('');
    logger.info('Every other account in the database:');
    const others = await UserModel.find({ email: { $nin: [ADMIN_EMAIL, MEMBER_EMAIL] } })
      .select('email')
      .lean();

    if (others.length === 0) {
      logger.info('  (none)');
    }
    for (const other of others) {
      const sources = await readSources(other.email);
      if (!sources) continue;
      audited += 1;
      if (!compareSources(sources)) allAgreed = false;
    }

    logger.info('');
    if (allAgreed) {
      logger.info(`Socket source check: PASS  (${audited} account(s), both sources synchronized)`);
    } else {
      logger.warn(`Socket source check: FAIL  (${audited} account(s) audited, see above)`);
    }
    return allAgreed;
  } finally {
    await disconnectDatabase();
  }
}

/**
 * `--check-orphan-households`: look for households with no membership at all.
 *
 * Between the phase-3 cutover (deployed 2026-08-21T09:24Z) and the atomicity
 * fix, `createHousehold` wrote the household document and the membership row as
 * two separate, untransacted operations. A failure in between left a household
 * nobody can reach: `requireMembership` answers 403 for everyone, so it cannot
 * be read, cannot be joined by anyone who is not already a member (nobody is),
 * and cannot be deleted — while still holding its unique `inviteCode` forever.
 *
 * Worth running BEFORE commit 7: the `$unset` erases the embedded array, which
 * for anything created before commit 6 is the last surviving clue about who the
 * household belonged to.
 *
 * Read-only. Two queries for the whole sweep — `distinct` over the memberships
 * rather than a count per household — plus one confirming `countDocuments` on
 * each suspect, so a finding is never an artifact of the cheap query.
 */
async function checkOrphanHouseholds(): Promise<boolean> {
  logger.info('');
  logger.info('='.repeat(72));
  logger.info('ORPHAN HOUSEHOLD CHECK — households with zero memberships');
  logger.info('='.repeat(72));
  logger.info('Read-only. Requires MONGODB_URI: households cannot be enumerated over HTTP.');
  logger.info('');

  await connectDatabase();
  try {
    const [households, withMembers] = await Promise.all([
      HouseholdModel.find({})
        .select('name inviteCode createdBy createdAt members')
        .sort({ createdAt: 1 })
        .lean(),
      HouseholdMemberModel.distinct('householdId'),
    ]);

    const populated = new Set(withMembers.map((id) => String(id)));
    const suspects = households.filter((h) => !populated.has(h._id.toString()));

    logger.info(`Households scanned:      ${households.length}`);
    logger.info(`With at least one member: ${households.length - suspects.length}`);

    if (suspects.length === 0) {
      logger.info('');
      logger.info('Orphan household check: PASS — 0 orphans, every household has a membership.');
      return true;
    }

    logger.warn('');
    logger.warn(`Orphan household check: FAIL — ${suspects.length} orphan(s) found.`);

    for (const h of suspects) {
      // Confirm against the authoritative count before reporting it.
      const confirmed = await HouseholdMemberModel.countDocuments({ householdId: h._id });
      if (confirmed > 0) {
        logger.warn(`  ${h._id.toString()}: not an orphan after all (${confirmed} rows); skipping.`);
        continue;
      }

      const creator = await UserModel.findById(h.createdBy).select('email households').lean();
      const stillListed = (creator?.households ?? []).some(
        (id) => id.toString() === h._id.toString(),
      );

      logger.warn('');
      logger.warn(`  householdId : ${h._id.toString()}`);
      logger.warn(`  nombre      : ${h.name}`);
      logger.warn(`  inviteCode  : ${h.inviteCode}`);
      logger.warn(`  createdAt   : ${new Date(h.createdAt).toISOString()}`);
      logger.warn(`  createdBy   : ${creator?.email ?? '(usuario no encontrado)'}`);
      logger.warn(
        `  User.households del creador todavía lo lista: ${stillListed ? 'SÍ (entrada colgada)' : 'no'}`,
      );
      // The embedded array is the only clue left about who belonged to a
      // household created before commit 6 — and commit 7 deletes it.
      logger.warn(`  members embebidos (vestigio): ${(h.members ?? []).length}`);
    }

    return false;
  } finally {
    await disconnectDatabase();
  }
}

function parseIterations(): number {
  const flag = process.argv.find((a) => a.startsWith('--iterations='));
  if (!flag) return DEFAULT_ITERATIONS;
  const value = Number(flag.split('=')[1]);
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(`--iterations must be a positive integer, got "${flag.split('=')[1]}"`);
  }
  return value;
}

async function main(): Promise<void> {
  baseUrl = `${process.env.API_BASE_URL ?? DEFAULT_HOST}/api`;
  // Dry run is the default: --execute must be explicit, since this writes to
  // production.
  const execute = process.argv.includes('--execute');
  const socketSource = process.argv.includes('--check-socket-source');
  const orphans = process.argv.includes('--check-orphan-households');
  // The read-only audits cost nothing against the rate limiter, so on their own
  // they skip the traffic entirely. Combined with --execute they run after,
  // when the traffic has just exercised all three writes.
  const trafficRequested = (!socketSource && !orphans) || execute;

  try {
    if (trafficRequested) {
      await validate(parseIterations(), execute);
    }
    if (socketSource && !(await checkSocketSource())) {
      process.exitCode = 1;
    }
    if (orphans && !(await checkOrphanHouseholds())) {
      process.exitCode = 1;
    }
  } catch (err) {
    logger.error('Validation run failed', (err as Error).message);
    process.exitCode = 1;
    return;
  }

  if (checks.some((c) => !c.ok)) process.exitCode = 1;
}

if (require.main === module) {
  void main();
}

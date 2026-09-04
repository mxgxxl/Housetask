import mongoose, { ClientSession, Types } from 'mongoose';
import { HouseholdModel, IHousehold } from '../models/Household';
import { HouseholdMemberModel, IHouseholdMember } from '../models/HouseholdMember';
import { TaskModel } from '../models/Task';
import { AppError } from '../middleware/error.middleware';
import { emitToHousehold } from '../config/socket';
import { RequesterMembership, Role } from '../types';
import { sanitizeString } from '../utils/sanitize';
import { logger } from '../utils/logger';
import { refundDepartingMember } from './economy-p1-savings.service';

const MAX_HOUSEHOLD_NAME_LENGTH = 100;
const TASK_POPULATE_FIELDS = 'name email avatarUrl';

const INVITE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no ambiguous 0/O/1/I
const INVITE_LENGTH = 8;

/**
 * Generate a random 8-char uppercase alphanumeric invite code that is not
 * already in use. Retries on the (rare) collision.
 */
async function generateUniqueInviteCode(): Promise<string> {
  // A handful of attempts is plenty given the large keyspace.
  for (let attempt = 0; attempt < 10; attempt++) {
    let code = '';
    for (let i = 0; i < INVITE_LENGTH; i++) {
      code += INVITE_CHARS[Math.floor(Math.random() * INVITE_CHARS.length)];
    }
    const exists = await HouseholdModel.exists({ inviteCode: code });
    if (!exists) return code;
  }
  throw new AppError('Could not generate a unique invite code, please retry', 500);
}

/**
 * Load a household's memberships from the authoritative collection, with the
 * user refs populated for serialization (TD-001 phase 3).
 *
 * Sorted by `joinedAt` so the response preserves the order the embedded array
 * gave for free — creator first, then joins in sequence. Without it the list
 * would come back in whatever order the index happened to yield, which is a
 * visible change to every member list in the app even though no field changed.
 * `_id` breaks ties: two members backfilled with the same timestamp must still
 * come out in a stable order across requests.
 */
async function loadMembers(householdId: Types.ObjectId | string): Promise<IHouseholdMember[]> {
  return HouseholdMemberModel.find({ householdId })
    .populate('userId', 'name email avatarUrl')
    .sort({ joinedAt: 1, _id: 1 })
    .exec();
}

/**
 * Shape a household for API responses.
 *
 * TD-001 phase 3: the `members` array is composed from the HouseholdMember
 * collection instead of the embedded array, and the shape is deliberately
 * unchanged — same key, same three fields, same nesting. That is what keeps
 * the Flutter client a complete no-op through this migration: an app already
 * in the stores cannot be rolled back the way a backend deploy can, so a
 * database migration that changes the wire contract would strand every
 * installed copy (see "Deployment order" in CLAUDE.md).
 *
 * Async now, because the members no longer arrive inside the household
 * document. The extra query replaces the dual-read verification that ran on
 * every household-scoped request until the cutover, so the net cost is flat.
 */
export async function serializeHousehold(household: IHousehold): Promise<Record<string, unknown>> {
  const members = await loadMembers(household._id);

  return {
    id: household._id.toString(),
    name: household.name,
    inviteCode: household.inviteCode,
    createdBy: household.createdBy.toString(),
    createdAt: household.createdAt,
    members: members.map((m) => {
      // A non-populated ref is an ObjectId; anything else is a populated user.
      const isPopulated = !(m.userId instanceof Types.ObjectId);
      const populated = m.userId as unknown as {
        _id?: Types.ObjectId;
        name?: string;
        email?: string;
        avatarUrl?: string;
      };
      return {
        user: isPopulated
          ? {
              id: populated._id?.toString(),
              name: populated.name,
              email: populated.email,
              avatarUrl: populated.avatarUrl,
            }
          : { id: m.userId.toString() },
        role: m.role,
        joinedAt: m.joinedAt,
      };
    }),
  };
}

/**
 * Create a household. The creator becomes its first admin.
 */
export async function createHousehold(userId: string, name: string): Promise<IHousehold> {
  // Both computed OUTSIDE the transaction on purpose. `withTransaction` may
  // re-run its callback on a transient error, and minting a fresh invite code
  // per attempt would burn codes and make the retry non-deterministic; reusing
  // the one already generated is safe because the aborted attempt left nothing
  // behind to collide with.
  const inviteCode = await generateUniqueInviteCode();
  const safeName = sanitizeString(name, MAX_HOUSEHOLD_NAME_LENGTH, 'Household name');

  // TD-001 phase 4: no `members` array — the HouseholdMember row is the only
  // record of the membership. Which is exactly why this needs a transaction:
  // if the row failed to land after the household document was written, the
  // household would exist with NO members at all. Nobody could read it
  // (requireMembership answers 403), nobody could delete it, and it would hold
  // its unique invite code forever. Before the cutover the embedded array at
  // least kept a trace; now there is none.
  const session = await mongoose.startSession();
  let created: IHousehold | undefined;
  try {
    await session.withTransaction(async () => {
      // Safe to repeat: every attempt writes a brand-new household document
      // and the membership upsert converges.
      const [household] = await HouseholdModel.create(
        [{ name: safeName, inviteCode, createdBy: new Types.ObjectId(userId) }],
        { session },
      );
      await addMembership(household._id, userId, 'admin', new Date(), session);
      created = household;
    });
  } finally {
    await session.endSession();
  }

  if (!created) {
    // Unreachable while withTransaction resolves only after the callback ran,
    // but the type has to be narrowed and a silent undefined would be worse.
    throw new AppError('Could not create the household, please retry', 500);
  }
  return created;
}

/**
 * Record a membership in the HouseholdMember collection (TD-001).
 *
 * Since phase 4 this is not a mirror of anything — it is THE membership write.
 * The embedded array it used to shadow is no longer maintained.
 *
 * Deliberately an upsert on `{householdId, userId}`: replaying it — after a
 * partial failure, or from the backfill — must converge instead of throwing on
 * the unique index. `$setOnInsert` means a replay never rewrites the role or
 * the original `joinedAt` of a membership that already exists. That is also
 * what makes it safe inside `withTransaction`, whose callback may run more
 * than once.
 *
 * Always takes a session: every caller now writes inside a transaction, since
 * this row became the only record that a membership exists.
 */
async function addMembership(
  householdId: Types.ObjectId,
  userId: string,
  role: Role,
  joinedAt: Date,
  session: ClientSession,
): Promise<void> {
  await HouseholdMemberModel.updateOne(
    { householdId, userId: new Types.ObjectId(userId) },
    { $setOnInsert: { role, joinedAt } },
    { upsert: true, session },
  );
}

/**
 * Fetch a household by id with members populated.
 *
 * Membership is NOT checked here: requireMembership guards every route that
 * reaches this function, and duplicating the check would mean two queries and
 * two places to keep in sync.
 */
export async function getHousehold(householdId: string): Promise<IHousehold> {
  // No populate since the cutover: the members it used to hydrate are read
  // from the HouseholdMember collection by serializeHousehold. Populating the
  // embedded array here would fetch the same users a second time to build a
  // list nobody reads.
  // `isDeleted` excluded since PDR-022 D4: a destroyed household is gone as
  // far as the API is concerned, even though its row survives to keep its
  // invite code out of circulation.
  const household = await HouseholdModel.findOne({
    _id: householdId,
    isDeleted: { $ne: true },
  });
  if (!household) {
    throw new AppError('Household not found', 404);
  }
  return household;
}

/**
 * Join a household by invite code. Idempotent for existing members.
 */
export async function joinHousehold(userId: string, inviteCode: string): Promise<IHousehold> {
  // A destroyed household's code still exists and still belongs to it — it is
  // never handed to a new household (PDR-022 D4) — but it stops resolving.
  // "Invalid invite code" rather than "that household was deleted": the caller
  // holding a code is not entitled to learn anything about a household they
  // were never in.
  const household = await HouseholdModel.findOne({
    inviteCode: inviteCode.toUpperCase().trim(),
    isDeleted: { $ne: true },
  });
  if (!household) {
    throw new AppError('Invalid invite code', 404);
  }

  // Idempotency is decided by the authority, the collection.
  const alreadyMember = await HouseholdMemberModel.exists({
    householdId: household._id,
    userId: new Types.ObjectId(userId),
  });

  if (alreadyMember) return household;

  // Still transactional after commit 7 retired `User.households`, even though
  // the membership row is now the only write: `withTransaction` is what makes
  // the row's absence on failure guaranteed rather than incidental, and the
  // next write added to this path inherits the guarantee instead of having to
  // rediscover it.
  const session = await mongoose.startSession();
  try {
    await session.withTransaction(async () => {
      await addMembership(household._id, userId, 'member', new Date(), session);

      // Keeps `updatedAt` meaning "last membership change" across all three
      // operations. NOT load-bearing here, unlike the identical write in
      // removeMemberInTransaction: a join only ever adds a non-admin, so it
      // cannot lower the admin count and cannot put Hard Rule 9 at risk. It is
      // consistency of the timestamp, not a lock — do not reason about it as
      // one.
      await HouseholdModel.updateOne(
        { _id: household._id },
        { $currentDate: { updatedAt: true } },
        { session },
      );
    });
  } finally {
    await session.endSession();
  }

  // After the commit, never inside it: `withTransaction` can re-run its
  // callback, and a socket event that has already gone out cannot be rolled
  // back — subscribers would see a join that the database then abandoned.
  emitToHousehold(household._id.toString(), 'household:member_joined', {
    householdId: household._id.toString(),
    userId,
  });

  return household;
}

/**
 * TD-018 (Hard Rule 16): when a member leaves a household — currently the
 * only exit path is removeMember below — their PENDING task assignments must
 * not linger pointing at someone who can no longer see or complete them.
 * This prunes the departed user from `assignedTo` on every pending,
 * non-deleted task in the household, leaving the task itself intact:
 *   - A task the departing member was assigned to (by themselves or anyone
 *     else) becomes unassigned if they were the only assignee, or keeps its
 *     remaining assignees otherwise.
 *   - A task the departing member CREATED is preserved untouched except for
 *     this same assignedTo pruning — authorship is never erased.
 *   - Completed and already soft-deleted tasks are left alone: they are
 *     historical record, not live work someone still needs to act on.
 * Each affected task is re-broadcast as `task:updated` so connected clients
 * drop the departed member from the assignee avatars without a manual
 * refresh (mirrors the `household:member_left` emission below).
 */
async function unassignDepartedMemberTasks(householdId: string, userId: string): Promise<void> {
  const userObjectId = new Types.ObjectId(userId);
  const affected = await TaskModel.find({
    householdId: new Types.ObjectId(householdId),
    assignedTo: userObjectId,
    status: 'pending',
    isDeleted: { $ne: true },
  });

  if (affected.length === 0) return;

  await TaskModel.updateMany(
    { _id: { $in: affected.map((t) => t._id) } },
    { $pull: { assignedTo: userObjectId } },
  );

  logger.info('Unassigned departed member from pending tasks', {
    householdId,
    userId,
    count: affected.length,
  });

  for (const task of affected) {
    task.assignedTo = task.assignedTo.filter((id) => id.toString() !== userId);
    await task.populate([
      { path: 'assignedTo', select: TASK_POPULATE_FIELDS },
      { path: 'createdBy', select: TASK_POPULATE_FIELDS },
      { path: 'completedBy', select: TASK_POPULATE_FIELDS },
    ]);
    emitToHousehold(householdId, 'task:updated', task.toJSON());
  }
}

/**
 * The mutating half of [removeMember], isolated so it can run inside a
 * transaction (and be re-run if the driver retries it).
 *
 * Since commit 7 it writes ONE side: the HouseholdMember row. The embedded
 * array stopped being written in commit 6 and the denormalized
 * `User.households` is gone entirely — membership lives in exactly one place.
 */
async function removeMemberInTransaction(
  householdId: string,
  targetUserId: string,
  session: ClientSession,
): Promise<void> {
  // Existence check and serialization point in ONE write, and the write is
  // deliberate — this is the subtlest consequence of dropping the dual write.
  //
  // Hard Rule 9 is a count followed by a delete on two DIFFERENT documents, so
  // transaction isolation alone does not serialize two admins removing each
  // other at the same time: with snapshot reads neither sees the other's
  // delete, both count 2 admins, both pass, and the household ends with none.
  // What actually prevented that until now was incidental — both transactions
  // also wrote the shared household document (`household.save()` for the
  // embedded array), so the second hit a WriteConflict and MongoDB retried it
  // against fresh state. Removing the embedded write would have silently
  // removed that protection along with it.
  //
  // So the conflict is kept on purpose: every removal touches the household
  // document, which makes concurrent removals in the SAME household serialize
  // (and leaves removals in different households unaffected, since they touch
  // different documents). `matchedCount` doubles as the 404 check, so this
  // costs no extra round trip.
  // `lockHousehold` performs exactly the write this function used to do inline
  // — and for exactly the reason documented above — and additionally returns
  // the household document, which PDR-022 now needs here to know who the
  // creator is.
  const household = await lockHousehold(householdId, session);

  const householdObjectId = new Types.ObjectId(householdId);

  // The target's membership and role come from the collection, the authority.
  const target = await HouseholdMemberModel.findOne({
    householdId: householdObjectId,
    userId: new Types.ObjectId(targetUserId),
  }).session(session);
  if (!target) {
    throw new AppError('Target user is not a member of this household', 404);
  }

  // Prevent removing the last admin (protects both self-removal and others).
  // The count and the delete are one atomic unit because of the transaction,
  // serialized against other removals in this household by the write above.
  const adminCount = await HouseholdMemberModel.countDocuments({
    householdId: householdObjectId,
    role: 'admin',
  }).session(session);
  if (target.role === 'admin' && adminCount <= 1) {
    throw new AppError('Cannot remove the last admin of the household', 400);
  }

  // PDR-022 D1: the creator cannot be demoted, and being expelled is strictly
  // stronger than being demoted — an admin who cannot take the creator's role
  // away must not be able to take their membership away either. Without this,
  // any second admin could remove the creator and leave `createdBy` pointing
  // at a non-member: a household with nobody able to manage roles, transfer
  // ownership or delete it. The creator's own exit is `leaveHousehold` (which
  // auto-transfers) or destruction (D4).
  //
  // Deliberately AFTER the last-admin check, not before. When the creator is
  // also the only admin, both rules reject the same request, and Hard Rule 9 is
  // the one that should say so: it is the older invariant, it is what the
  // caller actually has to fix (find another admin), and half a dozen tests
  // across the TD-001 suites pin that exact 400 as the evidence that the admin
  // count is read from the authoritative collection. This guard only changes
  // the answer where the request would otherwise have SUCCEEDED — a second
  // admin expelling the creator.
  if (household.createdBy.toString() === targetUserId) {
    throw new AppError('The household creator cannot be removed', 403);
  }

  // TD-066 B10: give the departing member their still-active savings
  // contributions back, BEFORE their membership goes (TD-066-DESIGN §4). The
  // order is the point: once the row is gone they are no longer a member, and
  // a later best-effort refund could fail and leave their coins locked in a
  // goal they can no longer see — money held by a household they left.
  //
  // Scoped to this member and this household, so nobody else's contributions
  // move. Safe to repeat, which matters because `withTransaction` may re-run
  // this whole callback: it only touches contributions still `active`, and a
  // second pass finds none.
  //
  // NOT wrapped in try/catch, unlike `unassignDepartedMemberTasks` below. That
  // one is cleanup and may fail without consequence; this one is money. A
  // removal that cannot return someone's coins must fail as a unit rather than
  // complete and lose them.
  await refundDepartingMember(householdId, targetUserId, session);

  await HouseholdMemberModel.deleteOne(
    { householdId: householdObjectId, userId: new Types.ObjectId(targetUserId) },
    { session },
  );
}

/**
 * Order a household's memberships the way governance decisions read them:
 * oldest first (TD-067 / PDR-022 D2 and D3).
 *
 * `joinedAt` ascending with `_id` as tiebreak, identical to `loadMembers`.
 * The tiebreak is not cosmetic here the way it is there: seniority now decides
 * who inherits the household's administration and its ownership, so two
 * memberships sharing a timestamp — which a backfill can produce — must still
 * resolve to the same successor on every request, not to whichever the index
 * happened to yield first.
 */
async function loadMembersBySeniority(
  householdId: Types.ObjectId,
  session: ClientSession,
): Promise<IHouseholdMember[]> {
  return HouseholdMemberModel.find({ householdId })
    .sort({ joinedAt: 1, _id: 1 })
    .session(session)
    .exec();
}

/**
 * Re-read the household inside a transaction AND make it that transaction's
 * serialization point (TD-067).
 *
 * Every governance operation added by PDR-022 is a read-then-write across two
 * different documents — count the admins, then change a role; find the oldest
 * admin, then rewrite `createdBy` — which is exactly the shape snapshot
 * isolation does NOT serialize on its own. `removeMemberInTransaction` already
 * documents this at length: two transactions that only read the household and
 * write different membership rows never conflict, so both can pass a check the
 * other invalidates.
 *
 * Touching `updatedAt` here puts every governance operation on the same
 * household document, so they conflict with each other and with member
 * removal, and MongoDB retries the loser against fresh state. `matchedCount`
 * doubles as the 404 check, so the guarantee costs no extra round trip.
 */
async function lockHousehold(householdId: string, session: ClientSession): Promise<IHousehold> {
  const touched = await HouseholdModel.updateOne(
    { _id: householdId, isDeleted: { $ne: true } },
    { $currentDate: { updatedAt: true } },
    { session },
  );
  if (touched.matchedCount === 0) {
    // Either it never existed or it was destroyed (PDR-022 D4). Both are 404,
    // and the filter belongs on the WRITE rather than on a separate read: a
    // destruction committing between the two would otherwise let a governance
    // operation mutate a household that is already gone.
    throw new AppError('Household not found', 404);
  }

  // Read AFTER the write, so `createdBy` is the value this transaction just
  // serialized on rather than one a concurrent transfer may have replaced.
  const household = await HouseholdModel.findById(householdId).session(session);
  if (!household) {
    throw new AppError('Household not found', 404);
  }
  return household;
}

/**
 * Turn a `:userId` path segment into an ObjectId, or answer 404.
 *
 * `new Types.ObjectId('nope')` throws a BSONError, which the error middleware
 * can only render as a 500 — an unhandled server fault for what is really a
 * client sending a malformed id. `removeMember` never hits that because it
 * filters the target through `memberIds` first; the governance endpoints take
 * the id straight to a query, so they need the guard explicitly. 404 rather
 * than 400 keeps it indistinguishable from "that user is not a member", which
 * is the same answer from the caller's side and leaks nothing about which ids
 * exist.
 */
function memberObjectId(userId: string): Types.ObjectId {
  if (!Types.ObjectId.isValid(userId)) {
    throw new AppError('Target user is not a member of this household', 404);
  }
  return new Types.ObjectId(userId);
}

/**
 * PDR-022 D1: only the household's creator may change roles.
 *
 * `createdBy` stopped being a historical field with PDR-022 and became a live
 * permission — which is also why it is read from the household document inside
 * the transaction rather than from anything the caller sent or the membership
 * middleware cached (Hard Rule 3).
 */
function assertCreator(household: IHousehold, userId: string): void {
  if (household.createdBy.toString() !== userId) {
    throw new AppError('Only the household creator can perform this action', 403);
  }
}

/**
 * Promote a member to admin, or demote an admin to member (PDR-022 D1).
 *
 * Only the creator may call this, and the creator is never a valid demotion
 * target: demoting them would leave the household with nobody able to manage
 * roles at all, since D1 makes that authority exclusively theirs. Promoting
 * them is a no-op rather than an error — they are already an admin, and
 * answering 400 to a request asking for a state the system is already in would
 * make a retry fail where the original succeeded.
 *
 * Hard Rule 9 is re-checked even though D1 makes it unreachable (the creator
 * cannot be demoted, so an admin always remains): the invariant is cheap to
 * assert inside a transaction already held, and it should survive a future
 * change to D1 rather than silently depend on it.
 */
export async function changeMemberRole(
  householdId: string,
  requesterUserId: string,
  targetUserId: string,
  role: Role,
): Promise<IHousehold> {
  const session = await mongoose.startSession();
  let previousRole: Role | null = null;

  try {
    await session.withTransaction(async () => {
      // Reset per attempt: withTransaction may re-run this callback, and a
      // value left over from an aborted attempt would be emitted as if it had
      // committed.
      previousRole = null;

      const household = await lockHousehold(householdId, session);
      assertCreator(household, requesterUserId);

      const householdObjectId = new Types.ObjectId(householdId);
      const target = await HouseholdMemberModel.findOne({
        householdId: householdObjectId,
        userId: memberObjectId(targetUserId),
      }).session(session);
      if (!target) {
        throw new AppError('Target user is not a member of this household', 404);
      }

      if (household.createdBy.toString() === targetUserId && role === 'member') {
        throw new AppError('The household creator cannot be demoted', 403);
      }

      if (target.role === role) {
        // Already there. Idempotent success, and deliberately no event: a
        // socket event announcing a transition that did not happen would make
        // every client re-render for nothing.
        return;
      }

      if (role === 'member') {
        const adminCount = await HouseholdMemberModel.countDocuments({
          householdId: householdObjectId,
          role: 'admin',
        }).session(session);
        if (adminCount <= 1) {
          throw new AppError('The household must keep at least one admin', 400);
        }
      }

      previousRole = target.role;
      target.role = role;
      await target.save({ session });
    });
  } finally {
    await session.endSession();
  }

  const household = await getHousehold(householdId);

  // After the commit, never inside it — same contract as every other emit in
  // this file: withTransaction can re-run its callback and a socket event
  // cannot be un-emitted.
  if (previousRole) {
    emitToHousehold(householdId, 'household:member_role_changed', {
      householdId,
      userId: targetUserId,
      previousRole,
      role,
    });
  }

  return household;
}

/**
 * Hand the household over to another admin (PDR-022 D2).
 *
 * The receiver must ALREADY be an admin. Ownership carries the authority to
 * promote and demote, so handing it to a plain member would skip the step
 * where the creator deliberately decided that person can administer anything
 * at all — the two-step promotion is a feature, not friction.
 *
 * The outgoing creator stays `admin`, not `member`: they lose authority over
 * roles (D1) and keep the day-to-day administration they had. Nobody is
 * removed — this transfers responsibility, not membership.
 */
export async function transferOwnership(
  householdId: string,
  requesterUserId: string,
  targetUserId: string,
): Promise<IHousehold> {
  const session = await mongoose.startSession();

  try {
    await session.withTransaction(async () => {
      const household = await lockHousehold(householdId, session);
      assertCreator(household, requesterUserId);

      if (targetUserId === requesterUserId) {
        throw new AppError('You already own this household', 400);
      }

      const householdObjectId = new Types.ObjectId(householdId);
      const target = await HouseholdMemberModel.findOne({
        householdId: householdObjectId,
        userId: memberObjectId(targetUserId),
      }).session(session);
      if (!target) {
        throw new AppError('Target user is not a member of this household', 404);
      }
      if (target.role !== 'admin') {
        throw new AppError('Ownership can only be transferred to an admin', 400);
      }

      // The outgoing creator keeps admin. Written explicitly rather than
      // assumed: it is what makes this operation total, and the assumption
      // would be silently wrong for any household whose creator was demoted
      // before D1 forbade it.
      await HouseholdMemberModel.updateOne(
        { householdId: householdObjectId, userId: new Types.ObjectId(requesterUserId) },
        { $set: { role: 'admin' } },
        { session },
      );

      household.createdBy = new Types.ObjectId(targetUserId);
      await household.save({ session });
    });
  } finally {
    await session.endSession();
  }

  emitToHousehold(householdId, 'household:ownership_transferred', {
    householdId,
    previousOwnerId: requesterUserId,
    ownerId: targetUserId,
  });

  return getHousehold(householdId);
}

/** What a departure has to change before the membership row can go. */
interface SuccessionPlan {
  promoteUserId?: string;
  newOwnerId?: string;
}

/**
 * Decide who inherits administration and/or ownership when `leavingUserId`
 * walks out (PDR-022 D2 and D3).
 *
 * Two separate successions, resolved from the same seniority order:
 *   - administration goes to the most senior remaining member whenever the
 *     leaver was the last admin;
 *   - ownership goes to the most senior remaining ADMIN when the leaver owned
 *     the household — or, if there is none, to whoever was just promoted, who
 *     is by construction the most senior member and inherits both.
 *
 * Returns what has to change so the caller can apply it inside the same
 * transaction as the delete. Nothing is written here.
 */
function planSuccession(
  members: IHouseholdMember[],
  leavingUserId: string,
  creatorId: string,
): SuccessionPlan {
  // `members` arrives sorted oldest-first, so [0] IS the most senior.
  const others = members.filter((m) => m.userId.toString() !== leavingUserId);
  const leaverIsAdmin =
    members.find((m) => m.userId.toString() === leavingUserId)?.role === 'admin';
  const remainingAdmins = others.filter((m) => m.role === 'admin');

  const plan: SuccessionPlan = {};

  if (leaverIsAdmin && remainingAdmins.length === 0) {
    // Hard Rule 9: the household would be left with no admin. D3 promotes the
    // most senior member rather than refusing the exit — leaving is a right,
    // and the pre-existing refusal only ever applied to expulsion.
    plan.promoteUserId = others[0].userId.toString();
  }

  if (creatorId === leavingUserId) {
    // D2: ownership never evaporates.
    plan.newOwnerId = remainingAdmins[0]
      ? remainingAdmins[0].userId.toString()
      : (plan.promoteUserId as string);
  }

  return plan;
}

/**
 * Leave a household voluntarily (PDR-022 D3).
 *
 * Any member may leave. What the server guarantees, in this order and inside
 * one transaction:
 *   1. the household keeps an admin (Hard Rule 9) — promoting the most senior
 *      remaining member if the leaver was the last one;
 *   2. the household keeps an owner (D2) — auto-transferring to the most
 *      senior remaining admin if the leaver never transferred;
 *   3. the leaver's active savings contributions come back to them (Hard Rule
 *      16b, PDR-018) BEFORE the membership row disappears;
 *   4. only then is the membership deleted.
 *
 * The order is the contract. Promoting after the delete would momentarily
 * leave a household with no admin, and refunding after it would be refunding
 * someone who is no longer a member — the exact failure Hard Rule 16b exists
 * to forbid.
 *
 * The last member of a household cannot leave: doing so would strand the
 * household with zero members — unreadable (requireMembership answers 403),
 * undeletable, and holding its unique invite code forever, the state
 * `createHousehold`'s transaction exists to prevent. PDR-022 D4 gives that
 * person the intended exit: destroy the household, which they can always do
 * because D2 guarantees the last member is its creator.
 */
export async function leaveHousehold(
  householdId: string,
  userId: string,
): Promise<SuccessionPlan> {
  const session = await mongoose.startSession();
  let outcome: SuccessionPlan = {};

  try {
    await session.withTransaction(async () => {
      outcome = {};

      const household = await lockHousehold(householdId, session);
      const householdObjectId = new Types.ObjectId(householdId);

      const members = await loadMembersBySeniority(householdObjectId, session);
      const leaving = members.find((m) => m.userId.toString() === userId);
      if (!leaving) {
        throw new AppError('You are not a member of this household', 403);
      }

      if (members.length === 1) {
        throw new AppError(
          'You are the last member of this household. Delete the household instead of leaving it.',
          400,
        );
      }

      const plan = planSuccession(members, userId, household.createdBy.toString());

      if (plan.promoteUserId) {
        await HouseholdMemberModel.updateOne(
          { householdId: householdObjectId, userId: new Types.ObjectId(plan.promoteUserId) },
          { $set: { role: 'admin' } },
          { session },
        );
      }

      if (plan.newOwnerId) {
        household.createdBy = new Types.ObjectId(plan.newOwnerId);
        await household.save({ session });
      }

      // Money before membership (Hard Rule 16b). Not wrapped in try/catch, on
      // purpose: an exit that cannot return someone's coins must fail as a
      // unit rather than complete and lose them.
      await refundDepartingMember(householdId, userId, session);

      await HouseholdMemberModel.deleteOne(
        { householdId: householdObjectId, userId: new Types.ObjectId(userId) },
        { session },
      );

      outcome = plan;
    });
  } finally {
    await session.endSession();
  }

  if (outcome.promoteUserId) {
    emitToHousehold(householdId, 'household:member_role_changed', {
      householdId,
      userId: outcome.promoteUserId,
      previousRole: 'member',
      role: 'admin',
    });
  }
  if (outcome.newOwnerId) {
    emitToHousehold(householdId, 'household:ownership_transferred', {
      householdId,
      previousOwnerId: userId,
      ownerId: outcome.newOwnerId,
    });
  }
  emitToHousehold(householdId, 'household:member_left', { householdId, userId });

  // TD-018 (Hard Rule 16): same follow-up as removeMember, and same
  // fire-and-forget contract — a successful exit must not come back as an
  // error because the task cleanup hit a problem.
  try {
    await unassignDepartedMemberTasks(householdId, userId);
  } catch (err) {
    logger.error('Error unassigning departed member from tasks', (err as Error).message);
  }

  return outcome;
}

/**
 * Remove a member from a household. Only admins may remove members. The last
 * remaining admin cannot be removed (which would leave the household leaderless).
 *
 * @param requester The caller's membership, as attached by requireMembership.
 */
export async function removeMember(
  householdId: string,
  requester: RequesterMembership,
  targetUserId: string,
): Promise<IHousehold> {
  // Both rejections are answered from what requireMembership already loaded,
  // so an unauthorized or bogus request never costs a second read.
  if (requester.role !== 'admin') {
    throw new AppError('Only admins can remove members', 403);
  }
  if (!requester.memberIds.includes(targetUserId)) {
    throw new AppError('Target user is not a member of this household', 404);
  }

  // The last-admin check and every write run inside ONE transaction (TD-001).
  // While membership lived only in the embedded array, checking and writing
  // touched the same document, so a concurrent removal could not slip between
  // them. Now the check counts admins and the writes land on different
  // documents, so without a transaction two admins removing each other
  // simultaneously could both pass the count and leave the household with NO
  // admin, a state the UI offers no way back from (Hard Rule 9). See
  // removeMemberInTransaction for why the transaction alone is not enough and
  // what serializes concurrent removals now that the embedded write is gone.
  //
  // Requires a replica set. Production is unaffected (Atlas always is) and
  // the test harness runs a single-node replica set for exactly this.
  const session = await mongoose.startSession();
  try {
    await session.withTransaction(async () => {
      // NOTE: withTransaction may run this callback more than once on a
      // transient error, so everything in here must be safe to repeat. It is:
      // each attempt re-reads the household and recomputes the decision.
      await removeMemberInTransaction(householdId, targetUserId, session);
    });
  } finally {
    await session.endSession();
  }

  // Re-read after the commit rather than reusing the in-transaction document:
  // it costs one query on a path that already mutates, and it guarantees what
  // we serialize is what actually landed.
  const household = await HouseholdModel.findById(householdId);
  if (!household) {
    throw new AppError('Household not found', 404);
  }

  emitToHousehold(household._id.toString(), 'household:member_left', {
    householdId: household._id.toString(),
    userId: targetUserId,
  });

  // TD-018: prune the departed member from pending task assignments. Runs
  // after the membership mutation is already committed and broadcast, and is
  // wrapped so it can never fail the removal itself (same fire-and-forget
  // contract as grantCoins/sendPushNotification) — a removal must not come
  // back as an error just because the follow-up task cleanup hit a problem.
  try {
    await unassignDepartedMemberTasks(household._id.toString(), targetUserId);
  } catch (err) {
    logger.error('Error unassigning departed member from tasks', (err as Error).message);
  }

  return household;
}

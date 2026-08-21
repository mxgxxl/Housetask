import mongoose, { ClientSession, Types } from 'mongoose';
import { HouseholdModel, IHousehold } from '../models/Household';
import { HouseholdMemberModel, IHouseholdMember } from '../models/HouseholdMember';
import { UserModel } from '../models/User';
import { TaskModel } from '../models/Task';
import { AppError } from '../middleware/error.middleware';
import { emitToHousehold } from '../config/socket';
import { RequesterMembership, Role } from '../types';
import { sanitizeString } from '../utils/sanitize';
import { logger } from '../utils/logger';

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
 * Create a household. The creator becomes its first admin and the household
 * is added to their `households` list.
 */
export async function createHousehold(userId: string, name: string): Promise<IHousehold> {
  const inviteCode = await generateUniqueInviteCode();

  // TD-001 phase 4: no `members` array. The household document no longer
  // carries its own membership; the HouseholdMember row created below is the
  // only record of it.
  const household = await HouseholdModel.create({
    name: sanitizeString(name, MAX_HOUSEHOLD_NAME_LENGTH, 'Household name'),
    inviteCode,
    createdBy: new Types.ObjectId(userId),
  });

  await UserModel.findByIdAndUpdate(userId, { $addToSet: { households: household._id } });
  await addMembership(household._id, userId, 'admin', new Date());

  return household;
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
 * the original `joinedAt` of a membership that already exists.
 *
 * Not transactional, by design: the only invariant that needs atomicity is
 * Hard Rule 9, which lives on the removal path (see removeMember).
 */
async function addMembership(
  householdId: Types.ObjectId,
  userId: string,
  role: Role,
  joinedAt: Date,
): Promise<void> {
  await HouseholdMemberModel.updateOne(
    { householdId, userId: new Types.ObjectId(userId) },
    { $setOnInsert: { role, joinedAt } },
    { upsert: true },
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
  const household = await HouseholdModel.findById(householdId);
  if (!household) {
    throw new AppError('Household not found', 404);
  }
  return household;
}

/**
 * Join a household by invite code. Idempotent for existing members.
 */
export async function joinHousehold(userId: string, inviteCode: string): Promise<IHousehold> {
  const household = await HouseholdModel.findOne({ inviteCode: inviteCode.toUpperCase().trim() });
  if (!household) {
    throw new AppError('Invalid invite code', 404);
  }

  // Idempotency is decided by the authority, the collection.
  const alreadyMember = await HouseholdMemberModel.exists({
    householdId: household._id,
    userId: new Types.ObjectId(userId),
  });

  if (!alreadyMember) {
    // TD-001 phase 4: the embedded array is no longer written. What used to be
    // a push plus `household.save()` is now just the membership row.
    await UserModel.findByIdAndUpdate(userId, { $addToSet: { households: household._id } });
    await addMembership(household._id, userId, 'member', new Date());

    emitToHousehold(household._id.toString(), 'household:member_joined', {
      householdId: household._id.toString(),
      userId,
    });
  }

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
 * Since phase 4 it writes two sides, not three: the HouseholdMember row (the
 * membership itself) and the denormalized `User.households`. The embedded
 * array is no longer maintained.
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
  const touched = await HouseholdModel.updateOne(
    { _id: householdId },
    { $currentDate: { updatedAt: true } },
    { session },
  );
  if (touched.matchedCount === 0) {
    throw new AppError('Household not found', 404);
  }

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

  await HouseholdMemberModel.deleteOne(
    { householdId: householdObjectId, userId: new Types.ObjectId(targetUserId) },
    { session },
  );

  await UserModel.findByIdAndUpdate(
    targetUserId,
    { $pull: { households: householdObjectId } },
    { session },
  );
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

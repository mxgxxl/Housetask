import mongoose, { ClientSession, Types } from 'mongoose';
import { HouseholdModel, IHousehold } from '../models/Household';
import { HouseholdMemberModel } from '../models/HouseholdMember';
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
 * Shape a household (with populated member users) for API responses.
 */
export function serializeHousehold(household: IHousehold): Record<string, unknown> {
  return {
    id: household._id.toString(),
    name: household.name,
    inviteCode: household.inviteCode,
    createdBy: household.createdBy.toString(),
    createdAt: household.createdAt,
    members: household.members.map((m) => {
      // A non-populated ref is an ObjectId; anything else is a populated user.
      const isPopulated = !(m.user instanceof Types.ObjectId);
      const populated = m.user as unknown as {
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
          : { id: m.user.toString() },
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

  const household = await HouseholdModel.create({
    name: sanitizeString(name, MAX_HOUSEHOLD_NAME_LENGTH, 'Household name'),
    inviteCode,
    createdBy: new Types.ObjectId(userId),
    members: [{ user: new Types.ObjectId(userId), role: 'admin' as Role, joinedAt: new Date() }],
  });

  await UserModel.findByIdAndUpdate(userId, { $addToSet: { households: household._id } });
  await mirrorMemberAdded(household._id, userId, 'admin', household.members[0].joinedAt);

  return household;
}

/**
 * Mirror a membership into the HouseholdMember collection (TD-001, phase 0).
 *
 * The embedded array is still the authority; this keeps the new collection in
 * step so the later phases have something to read. Deliberately an upsert on
 * `{householdId, userId}`: replaying it — after a partial failure, or from the
 * backfill — must converge instead of throwing on the unique index.
 *
 * Not transactional, by design: a divergence here is corrected by the
 * idempotent backfill, and wrapping every join in a transaction would buy
 * consistency for a mirror nobody reads yet. `removeMember` is the exception,
 * because its Hard Rule 9 check has to stay atomic (see below).
 */
async function mirrorMemberAdded(
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
  const household = await HouseholdModel.findById(householdId).populate(
    'members.user',
    'name email avatarUrl',
  );
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

  const alreadyMember = household.members.some((m) => m.user.toString() === userId);
  if (!alreadyMember) {
    household.members.push({
      user: new Types.ObjectId(userId),
      role: 'member',
      joinedAt: new Date(),
    });
    await household.save();
    await UserModel.findByIdAndUpdate(userId, { $addToSet: { households: household._id } });
    await mirrorMemberAdded(household._id, userId, 'member', new Date());

    emitToHousehold(household._id.toString(), 'household:member_joined', {
      householdId: household._id.toString(),
      userId,
    });
  }

  await household.populate('members.user', 'name email avatarUrl');
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
 * Writes all three sides of the membership: the embedded array (still the
 * authority in this phase), the HouseholdMember mirror, and the denormalized
 * `User.households`.
 */
async function removeMemberInTransaction(
  householdId: string,
  targetUserId: string,
  session: ClientSession,
): Promise<void> {
  const household = await HouseholdModel.findById(householdId).session(session);
  if (!household) {
    throw new AppError('Household not found', 404);
  }

  const target = household.members.find((m) => m.user.toString() === targetUserId);
  if (!target) {
    throw new AppError('Target user is not a member of this household', 404);
  }

  // Prevent removing the last admin (protects both self-removal and others).
  // Roles are read from the document loaded in THIS transaction, so a
  // concurrent removal cannot commit between the count and the write.
  const adminCount = household.members.filter((m) => m.role === 'admin').length;
  if (target.role === 'admin' && adminCount <= 1) {
    throw new AppError('Cannot remove the last admin of the household', 400);
  }

  household.members = household.members.filter((m) => m.user.toString() !== targetUserId);
  await household.save({ session });

  await HouseholdMemberModel.deleteOne(
    { householdId: household._id, userId: new Types.ObjectId(targetUserId) },
    { session },
  );

  await UserModel.findByIdAndUpdate(
    targetUserId,
    { $pull: { households: household._id } },
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

  // The read, the last-admin check and all three writes run inside ONE
  // transaction (TD-001). While membership lived only in the embedded array,
  // checking and writing touched the same document, so a concurrent removal
  // could not slip between them. Now the check counts admins and the writes
  // land on three different documents — household, householdmember, user — so
  // without a transaction two admins removing each other simultaneously could
  // both pass the count and leave the household with NO admin, a state the UI
  // offers no way back from (Hard Rule 9).
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

  await household.populate('members.user', 'name email avatarUrl');
  return household;
}

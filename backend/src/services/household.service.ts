import { Types } from 'mongoose';
import { HouseholdModel, IHousehold } from '../models/Household';
import { UserModel } from '../models/User';
import { AppError } from '../middleware/error.middleware';
import { emitToHousehold } from '../config/socket';
import { RequesterMembership, Role } from '../types';
import { sanitizeString } from '../utils/sanitize';

const MAX_HOUSEHOLD_NAME_LENGTH = 100;

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

  return household;
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
    'name email avatarUrl'
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

    emitToHousehold(household._id.toString(), 'household:member_joined', {
      householdId: household._id.toString(),
      userId,
    });
  }

  await household.populate('members.user', 'name email avatarUrl');
  return household;
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
  targetUserId: string
): Promise<IHousehold> {
  // Both rejections are answered from what requireMembership already loaded,
  // so an unauthorized or bogus request never costs a second read.
  if (requester.role !== 'admin') {
    throw new AppError('Only admins can remove members', 403);
  }
  if (!requester.memberIds.includes(targetUserId)) {
    throw new AppError('Target user is not a member of this household', 404);
  }

  // Only a request that will actually mutate reaches the database.
  const household = await HouseholdModel.findById(householdId);
  if (!household) {
    throw new AppError('Household not found', 404);
  }

  const target = household.members.find((m) => m.user.toString() === targetUserId);
  if (!target) {
    throw new AppError('Target user is not a member of this household', 404);
  }

  // Prevent removing the last admin (protects both self-removal and others).
  // Roles are read from the freshly loaded document rather than from the
  // request-scoped snapshot: a concurrent demotion must not slip past here.
  const adminCount = household.members.filter((m) => m.role === 'admin').length;
  if (target.role === 'admin' && adminCount <= 1) {
    throw new AppError('Cannot remove the last admin of the household', 400);
  }

  household.members = household.members.filter((m) => m.user.toString() !== targetUserId);
  await household.save();

  await UserModel.findByIdAndUpdate(targetUserId, { $pull: { households: household._id } });

  emitToHousehold(household._id.toString(), 'household:member_left', {
    householdId: household._id.toString(),
    userId: targetUserId,
  });

  await household.populate('members.user', 'name email avatarUrl');
  return household;
}

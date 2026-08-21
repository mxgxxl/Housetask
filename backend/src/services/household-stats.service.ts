import { Types, FilterQuery } from 'mongoose';
import { HouseholdModel } from '../models/Household';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import { TaskModel, ITask } from '../models/Task';
import { AppError } from '../middleware/error.middleware';

export type StatsPeriod = 'last30days' | 'allTime';

const LAST_30_DAYS_MS = 30 * 24 * 60 * 60 * 1000;

export interface MemberStat {
  userId: string;
  userName: string;
  avatarUrl?: string;
  created: number;
  completed: number;
}

export interface HouseholdStats {
  totalTasks: number;
  completedTasks: number;
  completionRate: number;
  memberStats: MemberStat[];
  topCompleter: { userId: string; userName: string; completed: number } | null;
  period: StatsPeriod;
}

/**
 * Household load/completion stats — seed for future retention features
 * (PDR-007). Any member can read; membership is verified by requireMembership.
 *
 * last30days windows the two metric families independently, per PDR-007:
 * completion metrics (completedTasks, memberStats[].completed, topCompleter)
 * use completedAt, everything else (totalTasks, memberStats[].created) uses
 * createdAt. allTime applies no date filter at all.
 */
export async function getHouseholdStats(
  householdId: string,
  period: StatsPeriod,
): Promise<HouseholdStats> {
  // TD-001 phase 3: members come from the authoritative collection, not from
  // the embedded array. The household is still read, but only to keep the 404
  // — a household with zero memberships and one that does not exist would
  // otherwise be indistinguishable here.
  const [household, members] = await Promise.all([
    HouseholdModel.exists({ _id: householdId }),
    HouseholdMemberModel.find({ householdId })
      .populate('userId', 'name avatarUrl')
      .sort({ joinedAt: 1, _id: 1 })
      .exec(),
  ]);
  if (!household) {
    throw new AppError('Household not found', 404);
  }

  const since = period === 'last30days' ? new Date(Date.now() - LAST_30_DAYS_MS) : null;
  const householdObjectId = new Types.ObjectId(householdId);

  const createdFilter: FilterQuery<ITask> = {
    householdId: householdObjectId,
    isDeleted: { $ne: true },
    ...(since ? { createdAt: { $gte: since } } : {}),
  };
  const completedFilter: FilterQuery<ITask> = {
    householdId: householdObjectId,
    isDeleted: { $ne: true },
    status: 'completed',
    ...(since ? { completedAt: { $gte: since } } : {}),
  };

  const [totalTasks, completedTasks, createdAgg, completedAgg] = await Promise.all([
    TaskModel.countDocuments(createdFilter),
    TaskModel.countDocuments(completedFilter),
    TaskModel.aggregate<{ _id: Types.ObjectId; count: number }>([
      { $match: createdFilter },
      { $group: { _id: '$createdBy', count: { $sum: 1 } } },
    ]),
    TaskModel.aggregate<{ _id: Types.ObjectId; count: number }>([
      { $match: completedFilter },
      { $group: { _id: '$completedBy', count: { $sum: 1 } } },
    ]),
  ]);

  const createdByMember = new Map(createdAgg.map((row) => [row._id.toString(), row.count]));
  const completedByMember = new Map(completedAgg.map((row) => [row._id.toString(), row.count]));

  const memberStats: MemberStat[] = members.map((m) => {
    const isPopulated = !(m.userId instanceof Types.ObjectId);
    const populated = m.userId as unknown as {
      _id: Types.ObjectId;
      name?: string;
      avatarUrl?: string;
    };
    const userId = isPopulated ? populated._id.toString() : m.userId.toString();
    return {
      userId,
      userName: isPopulated ? (populated.name ?? 'Former member') : 'Former member',
      avatarUrl: isPopulated ? populated.avatarUrl : undefined,
      created: createdByMember.get(userId) ?? 0,
      completed: completedByMember.get(userId) ?? 0,
    };
  });

  const topCompleter = memberStats.reduce<HouseholdStats['topCompleter']>((top, m) => {
    if (m.completed === 0) return top;
    if (!top || m.completed > top.completed) {
      return { userId: m.userId, userName: m.userName, completed: m.completed };
    }
    return top;
  }, null);

  const completionRate =
    totalTasks > 0 ? Math.round((completedTasks / totalTasks) * 1000) / 10 : 0;

  return { totalTasks, completedTasks, completionRate, memberStats, topCompleter, period };
}

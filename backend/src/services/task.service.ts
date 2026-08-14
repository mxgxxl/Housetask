import { Types } from 'mongoose';
import { TaskModel, ITask, IRecurrenceRule } from '../models/Task';
import { AppError } from '../middleware/error.middleware';
import { emitToHousehold } from '../config/socket';
import { calculateNextDueDate } from '../utils/recurrence';
import { logger } from '../utils/logger';
import { sanitizeDate, sanitizeString } from '../utils/sanitize';
import { Page, decodeCursor, encodeCursor } from '../utils/pagination';
import { TaskStatus, TaskPriority, TaskCategory, Role } from '../types';
import { grantCoins } from './economy.service';
import { TASK_COINS } from '../config/economy';

const POPULATE_FIELDS = 'name email avatarUrl';

const MAX_TITLE_LENGTH = 200;
const MAX_DESCRIPTION_LENGTH = 2000;

/**
 * Ensure every assignee actually belongs to the household.
 *
 * Without this an authenticated member could assign work to an arbitrary user
 * id, leaking that account's name and avatar through the populated task and
 * putting a stranger's row into the household's list.
 *
 * The member ids come from requireMembership, which already loaded the
 * household to authorize the request — re-querying here would double the reads
 * on the hottest write path.
 */
function assertAssigneesAreMembers(assignedTo: string[], memberIds: string[]): void {
  if (assignedTo.length === 0) return;

  const members = new Set(memberIds);
  for (const id of assignedTo) {
    if (!Types.ObjectId.isValid(id) || !members.has(id)) {
      throw new AppError('Invalid assigned member', 400);
    }
  }
}

/**
 * Resource-level authorization for edit/delete (TD-011, Hard Rule 17).
 *
 * Admins may modify any task in the household; a regular member may only
 * modify a task they created. Completing a task and creating a task are
 * deliberately NOT gated by this check — any member may do either.
 */
export function canModifyTask(task: ITask, userId: string, memberRole: Role): boolean {
  return memberRole === 'admin' || task.createdBy.toString() === userId;
}

export interface CreateTaskInput {
  title: string;
  description?: string;
  assignedTo?: string[];
  dueDate?: string | Date;
  startsAt?: string | Date;
  endsAt?: string | Date;
  priority?: TaskPriority;
  category?: TaskCategory;
  isRecurring?: boolean;
  recurrenceRule?: IRecurrenceRule;
}

export interface UpdateTaskInput {
  title?: string;
  description?: string;
  assignedTo?: string[];
  dueDate?: string | Date | null;
  startsAt?: string | Date | null;
  endsAt?: string | Date | null;
  priority?: TaskPriority;
  status?: TaskStatus;
  category?: TaskCategory;
  isRecurring?: boolean;
  recurrenceRule?: IRecurrenceRule;
}

/**
 * PDR-004: if both startsAt and endsAt are given, endsAt must be strictly
 * after startsAt. A single bound alone (start-only, or end-only) is valid —
 * only the pair needs ordering.
 */
function assertValidDuration(startsAt?: Date, endsAt?: Date): void {
  if (startsAt && endsAt && endsAt <= startsAt) {
    throw new AppError('endsAt must be after startsAt', 400);
  }
}

async function populated(task: ITask): Promise<ITask> {
  return task.populate([
    { path: 'assignedTo', select: POPULATE_FIELDS },
    { path: 'createdBy', select: POPULATE_FIELDS },
    { path: 'completedBy', select: POPULATE_FIELDS },
  ]);
}

/**
 * Check whether a pending task with the same title already exists near
 * `dueDate` (±1 day) so recurrence generation never creates duplicates.
 */
async function pendingDuplicateExists(
  householdId: Types.ObjectId,
  title: string,
  dueDate: Date,
): Promise<boolean> {
  const oneDayBefore = new Date(dueDate);
  oneDayBefore.setDate(oneDayBefore.getDate() - 1);
  const oneDayAfter = new Date(dueDate);
  oneDayAfter.setDate(oneDayAfter.getDate() + 1);

  const existing = await TaskModel.exists({
    householdId,
    title,
    status: 'pending',
    dueDate: { $gte: oneDayBefore, $lte: oneDayAfter },
  });
  return existing !== null;
}

/**
 * Build the next occurrence of a recurring task from a source task and its
 * computed next due date. Returns the persisted (unpopulated) task.
 */
async function createNextOccurrence(source: ITask, nextDueDate: Date): Promise<ITask> {
  return TaskModel.create({
    householdId: source.householdId,
    title: source.title,
    description: source.description,
    assignedTo: source.assignedTo,
    createdBy: source.createdBy,
    priority: source.priority,
    category: source.category,
    status: 'pending',
    dueDate: nextDueDate,
    isRecurring: true,
    recurrenceRule: source.recurrenceRule,
    parentTaskId: source.parentTaskId || source._id,
  });
}

/**
 * When a recurring task is completed, generate its next pending occurrence
 * (unless one already exists) and broadcast `task:created`. Called with the
 * source task BEFORE it is populated so its refs remain ObjectIds.
 */
async function generateNextInstance(task: ITask): Promise<void> {
  if (!task.isRecurring || !task.recurrenceRule || !task.recurrenceRule.type || !task.dueDate) {
    return;
  }

  const nextDueDate = calculateNextDueDate(task.dueDate, task.recurrenceRule);
  if (await pendingDuplicateExists(task.householdId, task.title, nextDueDate)) {
    return;
  }

  const nextTask = await createNextOccurrence(task, nextDueDate);
  await populated(nextTask);
  emitToHousehold(task.householdId.toString(), 'task:created', nextTask.toJSON());
}

/**
 * Total order used for listing and for keyset pagination.
 *
 * `status: -1` puts "pending" before "completed", then earliest dueDate first.
 * `_id` is the final tiebreaker instead of `createdAt`: ObjectIds embed their
 * creation time so the visible order is unchanged, but unlike `createdAt` they
 * can never tie — and a cursor over a non-total order skips or repeats rows.
 */
const TASK_SORT = { status: -1, dueDate: 1, _id: -1 } as const;

/**
 * Sort position of the last task on a page, carried in the opaque cursor.
 * `d` is the dueDate as ISO string, or null when the task has none.
 */
interface TaskCursor {
  s: TaskStatus;
  d: string | null;
  id: string;
}

function isTaskCursor(value: unknown): value is TaskCursor {
  if (typeof value !== 'object' || value === null) return false;
  const c = value as Record<string, unknown>;
  if (c.s !== 'pending' && c.s !== 'completed') return false;
  if (c.d !== null && typeof c.d !== 'string') return false;
  if (typeof c.d === 'string' && Number.isNaN(Date.parse(c.d))) return false;
  return typeof c.id === 'string' && Types.ObjectId.isValid(c.id);
}

/**
 * Build the "strictly after this position" predicate for TASK_SORT.
 *
 * Null dueDates need their own branch: MongoDB's range operators only match
 * within a BSON type, so `{ dueDate: { $gt: null } }` matches nothing and
 * would silently truncate the list at the first dated task.
 */
function taskCursorFilter(cursor: TaskCursor): Record<string, unknown> {
  const dueEquals = cursor.d === null ? { dueDate: null } : { dueDate: new Date(cursor.d) };
  const dueAfter =
    cursor.d === null ? { dueDate: { $ne: null } } : { dueDate: { $gt: new Date(cursor.d) } };

  return {
    $or: [
      // status descending: anything ordered after the cursor's status.
      { status: { $lt: cursor.s } },
      // same status, later dueDate.
      { status: cursor.s, ...dueAfter },
      // same status and dueDate, smaller _id (descending tiebreaker).
      { status: cursor.s, ...dueEquals, _id: { $lt: new Types.ObjectId(cursor.id) } },
    ],
  };
}

export interface ListTasksOptions {
  status?: TaskStatus;
  limit: number;
  cursor?: string;
  from?: Date;
  to?: Date;
}

/**
 * Match tasks whose dueDate falls within [from, to], PLUS every undated task.
 *
 * Undated tasks have no day to place on the PDR-003 timeline, so the client
 * always buckets them into its "Sin fecha" section regardless of which window
 * it asked for — "para que nada se pierda" (docs/PRODUCT_DECISIONS.md
 * PDR-003). Returning them from every from/to query, rather than adding a
 * second endpoint call, is what the client's single-request
 * `loadTimeline()`/`agrupa client-side por día local` is built around.
 * Returns null when neither bound is given (date filtering off entirely —
 * the pre-PDR-003 behavior).
 */
function dueDateWindowFilter(from?: Date, to?: Date): Record<string, unknown> | null {
  if (!from && !to) return null;
  const range: Record<string, Date> = {};
  if (from) range.$gte = from;
  if (to) range.$lte = to;
  return { $or: [{ dueDate: null }, { dueDate: range }] };
}

/**
 * List one page of a household's tasks. Pending tasks come first, then by
 * dueDate asc. Optionally filtered by status and/or a dueDate window
 * (from/to, PDR-003), both of which combine with the cursor.
 */
export async function listTasks(
  householdId: string,
  userId: string,
  options: ListTasksOptions,
): Promise<Page<ITask>> {
  const baseFilter: Record<string, unknown> = { householdId: new Types.ObjectId(householdId) };
  if (options.status) baseFilter.status = options.status;

  const dateFilter = dueDateWindowFilter(options.from, options.to);
  const countFilter = dateFilter ? { ...baseFilter, ...dateFilter } : baseFilter;

  // dateFilter and the cursor filter are each a top-level `$or`: merging them
  // with a plain spread would let the second silently clobber the first, so
  // once both are present they are combined under `$and` instead.
  let pageFilter: Record<string, unknown> = countFilter;
  if (options.cursor) {
    const cursorFilter = taskCursorFilter(decodeCursor(options.cursor, isTaskCursor));
    pageFilter = dateFilter
      ? { ...baseFilter, $and: [dateFilter, cursorFilter] }
      : { ...baseFilter, ...cursorFilter };
  }

  // Counted only on the first page: the value is identical for every page of a
  // walk, so recomputing it per page is a pure waste of a collection scan.
  const [total, docs] = await Promise.all([
    options.cursor ? Promise.resolve(null) : TaskModel.countDocuments(countFilter),
    TaskModel.find(pageFilter)
      .sort(TASK_SORT)
      // One extra row is the cheapest way to know whether another page exists.
      .limit(options.limit + 1)
      .populate('assignedTo', POPULATE_FIELDS)
      .populate('createdBy', POPULATE_FIELDS)
      .populate('completedBy', POPULATE_FIELDS),
  ]);

  const hasMore = docs.length > options.limit;
  const items = hasMore ? docs.slice(0, options.limit) : docs;
  const last = items[items.length - 1];

  return {
    items,
    hasMore,
    total,
    nextCursor:
      hasMore && last
        ? encodeCursor({
            s: last.status,
            d: last.dueDate ? last.dueDate.toISOString() : null,
            id: last._id.toString(),
          })
        : null,
  };
}

/**
 * Create a task in a household and broadcast `task:created`.
 */
export async function createTask(
  householdId: string,
  userId: string,
  input: CreateTaskInput,
  memberIds: string[],
): Promise<ITask> {
  if (!input.title || input.title.trim() === '') {
    throw new AppError('Task title is required', 400);
  }

  const assignedTo = input.assignedTo || [];
  assertAssigneesAreMembers(assignedTo, memberIds);

  const isRecurring = input.isRecurring ?? false;

  // PDR-004: duration + recurrence is out of scope this round — a recurring
  // task never persists startsAt/endsAt, whatever the client sent.
  let startsAt: Date | undefined;
  let endsAt: Date | undefined;
  if (!isRecurring) {
    startsAt = input.startsAt ? sanitizeDate(input.startsAt, 'startsAt') : undefined;
    endsAt = input.endsAt ? sanitizeDate(input.endsAt, 'endsAt') : undefined;
    assertValidDuration(startsAt, endsAt);
  }

  const task = await TaskModel.create({
    householdId: new Types.ObjectId(householdId),
    title: sanitizeString(input.title, MAX_TITLE_LENGTH, 'Task title'),
    description:
      input.description === undefined
        ? undefined
        : sanitizeString(input.description, MAX_DESCRIPTION_LENGTH, 'Task description'),
    assignedTo: assignedTo.map((id) => new Types.ObjectId(id)),
    createdBy: new Types.ObjectId(userId),
    priority: input.priority || 'medium',
    category: input.category || 'other',
    dueDate: input.dueDate ? sanitizeDate(input.dueDate, 'dueDate') : undefined,
    startsAt,
    endsAt,
    isRecurring,
    recurrenceRule: input.recurrenceRule,
  });

  await populated(task);
  emitToHousehold(householdId, 'task:created', task.toJSON());
  return task;
}

/**
 * Apply a partial update to a task and broadcast `task:updated`.
 *
 * Restricted to the task's creator or a household admin (TD-011, Hard Rule
 * 17) — checked before any field is applied, so a forbidden request never
 * partially mutates the document.
 */
export async function updateTask(
  householdId: string,
  userId: string,
  taskId: string,
  input: UpdateTaskInput,
  memberIds: string[],
  memberRole: Role,
): Promise<ITask> {
  const task = await TaskModel.findOne({ _id: taskId, householdId });
  if (!task) {
    throw new AppError('Task not found', 404);
  }
  if (!canModifyTask(task, userId, memberRole)) {
    throw new AppError('You do not have permission to modify this task', 403);
  }

  // Captured before any field is applied: the economy hook below (PDR-001)
  // must key off the ORIGINAL status, not a value this same update sets.
  const wasCompletedBefore = task.status === 'completed';

  if (input.title !== undefined) {
    task.title = sanitizeString(input.title, MAX_TITLE_LENGTH, 'Task title');
  }
  if (input.description !== undefined) {
    task.description = sanitizeString(
      input.description,
      MAX_DESCRIPTION_LENGTH,
      'Task description',
    );
  }
  if (input.assignedTo !== undefined) {
    assertAssigneesAreMembers(input.assignedTo, memberIds);
    task.assignedTo = input.assignedTo.map((id) => new Types.ObjectId(id));
  }
  if (input.dueDate !== undefined) {
    task.dueDate = input.dueDate ? sanitizeDate(input.dueDate, 'dueDate') : undefined;
  }
  if (input.priority !== undefined) task.priority = input.priority;
  if (input.category !== undefined) task.category = input.category;
  if (input.isRecurring !== undefined) task.isRecurring = input.isRecurring;
  if (input.recurrenceRule !== undefined) task.recurrenceRule = input.recurrenceRule;

  // PDR-004: duration + recurrence is out of scope. A task that is (or just
  // became, via isRecurring above) recurring never carries startsAt/endsAt —
  // any it already had are cleared rather than merely refusing to persist
  // new ones, so the invariant holds regardless of how it got here.
  if (task.isRecurring) {
    task.startsAt = undefined;
    task.endsAt = undefined;
  } else if (input.startsAt !== undefined || input.endsAt !== undefined) {
    const nextStartsAt =
      input.startsAt !== undefined
        ? input.startsAt
          ? sanitizeDate(input.startsAt, 'startsAt')
          : undefined
        : task.startsAt;
    const nextEndsAt =
      input.endsAt !== undefined
        ? input.endsAt
          ? sanitizeDate(input.endsAt, 'endsAt')
          : undefined
        : task.endsAt;
    assertValidDuration(nextStartsAt, nextEndsAt);
    task.startsAt = nextStartsAt;
    task.endsAt = nextEndsAt;
  }

  // Keep completion metadata consistent when status is set directly.
  if (input.status !== undefined) {
    task.status = input.status;
    if (input.status === 'completed') {
      task.completedAt = task.completedAt ?? new Date();
      task.completedBy = task.completedBy ?? new Types.ObjectId(userId);
    } else {
      task.completedAt = undefined;
      task.completedBy = undefined;
    }
  }

  await task.save();

  // Economy consistency (PDR-001): a generic PATCH that transitions status
  // to 'completed' grants coins exactly like PATCH .../complete does — same
  // idempotent grantCoins keyed on (householdId, taskId, 'task_complete'),
  // so completing via one path and then the other never pays out twice
  // (the ledger's unique index is the actual guard; wasCompletedBefore is
  // just the cheap short-circuit). Without this hook, a client that only
  // ever uses the generic PATCH to complete tasks would silently never earn
  // coins.
  if (input.status === 'completed' && !wasCompletedBefore) {
    try {
      await grantCoins(householdId, TASK_COINS, 'task_complete', taskId);
    } catch (err) {
      logger.error('Error granting task-complete coins', (err as Error).message);
    }
  }

  await populated(task);
  emitToHousehold(householdId, 'task:updated', task.toJSON());
  return task;
}

/**
 * Mark a task complete (sets completedAt/completedBy) and broadcast
 * `task:completed`.
 */
export async function completeTask(
  householdId: string,
  userId: string,
  taskId: string,
): Promise<ITask> {
  const task = await TaskModel.findOne({ _id: taskId, householdId });
  if (!task) {
    throw new AppError('Task not found', 404);
  }

  // Captured before mutation: only the FIRST completion grants coins
  // (PDR-001 anti-farm). Re-completing an already-completed task — e.g. a
  // duplicate PATCH — must not pay out twice.
  const isFirstCompletion = task.status !== 'completed';

  task.status = 'completed';
  task.completedAt = new Date();
  task.completedBy = new Types.ObjectId(userId);
  await task.save();

  // Generate the next recurring occurrence before populating so the source
  // task's refs are still ObjectIds. Never let recurrence break completion.
  try {
    await generateNextInstance(task);
  } catch (err) {
    logger.error('Error generating next recurrence', (err as Error).message);
  }

  // Best-effort: the ledger's unique index is the real anti-double-grant
  // guard (isFirstCompletion is a cheap short-circuit that also skips a
  // redundant query on every recompletion), so a coin-granting failure here
  // must never fail the completion itself.
  if (isFirstCompletion) {
    try {
      await grantCoins(householdId, TASK_COINS, 'task_complete', taskId);
    } catch (err) {
      logger.error('Error granting task-complete coins', (err as Error).message);
    }
  }

  await populated(task);
  emitToHousehold(householdId, 'task:completed', task.toJSON());
  return task;
}

/**
 * Hard-delete a task and broadcast `task:deleted`.
 *
 * Restricted to the task's creator or a household admin (TD-011, Hard Rule
 * 17) — fetches the task first (rather than delete-by-filter) so the
 * permission check runs before anything is removed.
 */
export async function deleteTask(
  householdId: string,
  userId: string,
  taskId: string,
  memberRole: Role,
): Promise<void> {
  const task = await TaskModel.findOne({ _id: taskId, householdId });
  if (!task) {
    throw new AppError('Task not found', 404);
  }
  if (!canModifyTask(task, userId, memberRole)) {
    throw new AppError('You do not have permission to modify this task', 403);
  }

  await task.deleteOne();
  emitToHousehold(householdId, 'task:deleted', { id: taskId, householdId });
}

const MAX_CATCHUP_ITERATIONS = 52; // cap generation at ~1 year per series

/**
 * Catch up missed recurring occurrences: for each completed recurring series
 * (grouped by title, taking the most recent completion), generate every
 * pending occurrence with a due date up to and including `upTo`. Broadcasts
 * `tasks:batch_created`. Idempotent thanks to the ±1-day duplicate guard.
 */
export async function catchUpRecurring(
  householdId: string,
  userId: string,
  upTo: Date,
): Promise<{ generated: number; tasks: ITask[] }> {
  const completedRecurring = await TaskModel.find({
    householdId: new Types.ObjectId(householdId),
    isRecurring: true,
    status: 'completed',
  }).sort({ completedAt: -1 });

  // Keep only the latest completed task per series (by title).
  const latestByTitle = new Map<string, ITask>();
  for (const task of completedRecurring) {
    if (!latestByTitle.has(task.title)) {
      latestByTitle.set(task.title, task);
    }
  }

  const createdTasks: ITask[] = [];
  const upToTime = upTo.getTime();

  for (const task of latestByTitle.values()) {
    if (!task.recurrenceRule || !task.recurrenceRule.type || !task.dueDate) continue;

    let currentDue = task.dueDate;
    let iterations = 0;

    while (iterations < MAX_CATCHUP_ITERATIONS) {
      const nextDueDate = calculateNextDueDate(currentDue, task.recurrenceRule);
      // Stop once we pass the requested horizon.
      if (nextDueDate.getTime() > upToTime) break;
      // Stop if this occurrence already exists as pending.
      if (await pendingDuplicateExists(task.householdId, task.title, nextDueDate)) break;

      const newTask = await createNextOccurrence(task, nextDueDate);
      createdTasks.push(newTask);
      currentDue = nextDueDate;
      iterations++;
    }
  }

  if (createdTasks.length > 0) {
    const populatedTasks = await Promise.all(createdTasks.map((t) => populated(t)));
    emitToHousehold(householdId, 'tasks:batch_created', {
      tasks: populatedTasks.map((t) => t.toJSON()),
      count: createdTasks.length,
    });
  }

  return { generated: createdTasks.length, tasks: createdTasks };
}

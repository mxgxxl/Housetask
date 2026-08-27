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
import { sendPushNotification } from './notification.service';

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

/**
 * The 404-then-403 guard `updateTask` runs, as a standalone check (TD-066 B4).
 *
 * Extracted so the generic PATCH can keep enforcing exactly the same
 * authorization when its status transition is handed to the P1 reward
 * service instead of being applied here. Duplicating the rule at the call
 * site would be a security bug waiting to happen: `PATCH .../complete`
 * requires no such permission (any member may complete a task, Hard Rule 17)
 * while a status-only generic PATCH has always required creator-or-admin,
 * and quietly dropping that distinction would LOOSEN an existing check.
 */
export async function assertCanModifyTask(
  householdId: string,
  userId: string,
  taskId: string,
  memberRole: Role,
): Promise<void> {
  const task = await TaskModel.findOne({ _id: taskId, householdId, isDeleted: { $ne: true } });
  if (!task) {
    throw new AppError('Task not found', 404);
  }
  if (!canModifyTask(task, userId, memberRole)) {
    throw new AppError('You do not have permission to modify this task', 403);
  }
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
 * A populated user ref carries a Mongoose document, not the plain ObjectId
 * the ITask interface declares — same cast pattern household.service.ts's
 * serializeHousehold uses for populated `members.user`.
 */
function populatedName(ref: Types.ObjectId): string {
  return (ref as unknown as { name?: string }).name ?? 'Alguien';
}

function populatedId(ref: Types.ObjectId): string {
  return (ref as unknown as { _id: Types.ObjectId })._id.toString();
}

/**
 * PDR-008: push each assignee "you were assigned a task", skipping the
 * creator if they assigned it to themselves (no point notifying yourself).
 * Must be called with an already-populated task (populated() above) so
 * `createdBy`'s name is available. Fire-and-forget: a push failure must
 * never fail task creation, so every call is wrapped in try/catch and none
 * of them are awaited by the caller.
 */
function notifyTaskAssigned(task: ITask, creatorId: string): void {
  if (task.assignedTo.length === 0) return;

  const creatorName = populatedName(task.createdBy);
  const data = { type: 'task', taskId: task._id.toString() };

  for (const assignee of task.assignedTo) {
    const assigneeId = populatedId(assignee);
    if (assigneeId === creatorId) continue;

    sendPushNotification(
      assigneeId,
      'Nueva tarea asignada',
      `${creatorName} te asignó: ${task.title}`,
      data,
    ).catch((err) => {
      logger.error('Error sending task-assigned push notification', (err as Error).message);
    });
  }
}

/**
 * PDR-008: push the task's creator "someone completed your task", unless
 * they completed it themselves. Same fire-and-forget contract as
 * notifyTaskAssigned above.
 */
export function notifyTaskCompleted(task: ITask, completerId: string): void {
  const creatorId = populatedId(task.createdBy);
  if (creatorId === completerId) return;

  const completerName = task.completedBy ? populatedName(task.completedBy) : 'Alguien';
  const data = { type: 'task', taskId: task._id.toString() };

  sendPushNotification(
    creatorId,
    'Tarea completada',
    `${completerName} completó: ${task.title}`,
    data,
  ).catch((err) => {
    logger.error('Error sending task-completed push notification', (err as Error).message);
  });
}

/**
 * Check whether a pending task with the same title already exists near
 * `dueDate` (±1 day) so recurrence generation never creates duplicates.
 *
 * Excludes soft-deleted tasks (TD-009/TD-046): a deleted "pending" occurrence
 * no longer represents live, unfinished work, so it must not block a new one
 * from being generated in its place.
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
    isDeleted: { $ne: true },
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
export async function generateNextInstance(task: ITask): Promise<void> {
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
  /**
   * When true, does NOT filter out soft-deleted tasks (TD-009) — the page
   * comes back with both active and deleted tasks mixed in, sorted the same
   * as always. Used by the frontend's trash view, which walks the full list
   * client-side and keeps only isDeleted:true rows (same pattern as TD-035's
   * Recurrentes tab), rather than a dedicated backend endpoint.
   */
  includeDeleted?: boolean;
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
  // $ne (rather than `false`) also matches documents from before this field
  // existed, which have no isDeleted key at all.
  if (!options.includeDeleted) baseFilter.isDeleted = { $ne: true };

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

/* ------------------------------------------------------------------ *
 * TD-064: the timeline reads                                          *
 * ------------------------------------------------------------------ */

/**
 * Sort position of the last DATED task on a timeline page.
 *
 * Versioned (`v`) because the cursor is opaque and long-lived in a client's
 * memory: a future change to the sort key has to be able to reject old
 * cursors instead of silently walking them with the wrong comparator.
 *
 * `f` pins the cursor to the session it was issued for. A cursor is a position
 * in ONE ordered result set; replaying it against a different `from` would
 * resume at a coordinate that means something else, skipping or repeating rows
 * with no error anywhere. Binding it makes that a 400 instead of a silent hole.
 */
interface TimelineCursor {
  v: 1;
  f: string;
  d: string;
  id: string;
}

/** Sort position of the last UNDATED task. Only an id: nothing else orders them. */
interface UndatedCursor {
  v: 1;
  id: string;
}

function isTimelineCursor(value: unknown): value is TimelineCursor {
  if (typeof value !== 'object' || value === null) return false;
  const c = value as Record<string, unknown>;
  if (c.v !== 1) return false;
  if (typeof c.f !== 'string' || Number.isNaN(Date.parse(c.f))) return false;
  if (typeof c.d !== 'string' || Number.isNaN(Date.parse(c.d))) return false;
  return typeof c.id === 'string' && Types.ObjectId.isValid(c.id);
}

function isUndatedCursor(value: unknown): value is UndatedCursor {
  if (typeof value !== 'object' || value === null) return false;
  const c = value as Record<string, unknown>;
  if (c.v !== 1) return false;
  return typeof c.id === 'string' && Types.ObjectId.isValid(c.id);
}

/** `dueDate ASC, _id ASC` — a total order, which a keyset walk requires. */
const TIMELINE_SORT = { dueDate: 1, _id: 1 } as const;

/**
 * Undated tasks keep the order they had inside the old combined list: newest
 * first. MongoDB sorts null before any date, so under the previous
 * `{status, dueDate, _id: -1}` sort they surfaced ahead of dated tasks ordered
 * by descending id. Splitting them into their own read must not silently
 * reshuffle a bucket the user already knows.
 */
const UNDATED_SORT = { _id: -1 } as const;

export interface TimelineOptions {
  from: Date;
  limit: number;
  cursor?: string;
}

export interface UndatedOptions {
  limit: number;
  cursor?: string;
}

/**
 * One page of a household's ACTIVE, DATED tasks from `from` onwards (TD-064).
 *
 * Deliberately not a variant of [listTasks]. That endpoint answers "the
 * household's tasks, optionally windowed", and its `from`/`to` window returns
 * undated tasks in EVERY window (`dueDateWindowFilter` ORs `dueDate: null`
 * in), so a client walking forward re-reads them on every page and the backend
 * re-scans them. The timeline instead walks a single open-ended range with a
 * cursor that never revisits ground, and the undated tasks get their own
 * paginated read below.
 *
 * `dueDate: {$gte: from}` also does the "dated only" filtering for free:
 * MongoDB range operators match within a BSON type, so null and missing
 * dueDates cannot satisfy it.
 */
export async function listTimeline(
  householdId: string,
  options: TimelineOptions,
): Promise<Page<ITask>> {
  const baseFilter: Record<string, unknown> = {
    householdId: new Types.ObjectId(householdId),
    isDeleted: { $ne: true },
    dueDate: { $gte: options.from },
  };

  let pageFilter = baseFilter;
  if (options.cursor) {
    const cursor = decodeCursor(options.cursor, isTimelineCursor);
    if (cursor.f !== options.from.toISOString()) {
      throw new AppError('Cursor does not belong to this timeline query', 400);
    }
    const after = new Date(cursor.d);
    // Top-level `$or` alongside the base `dueDate` bound: both apply (implicit
    // AND) and neither clobbers the other, since they live under different keys.
    pageFilter = {
      ...baseFilter,
      $or: [
        { dueDate: { $gt: after } },
        { dueDate: after, _id: { $gt: new Types.ObjectId(cursor.id) } },
      ],
    };
  }

  const [total, docs] = await Promise.all([
    options.cursor ? Promise.resolve(null) : TaskModel.countDocuments(baseFilter),
    TaskModel.find(pageFilter)
      .sort(TIMELINE_SORT)
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
      hasMore && last?.dueDate
        ? encodeCursor({
            v: 1,
            f: options.from.toISOString(),
            d: last.dueDate.toISOString(),
            id: last._id.toString(),
          })
        : null,
  };
}

/**
 * One page of a household's ACTIVE, UNDATED tasks (TD-064).
 *
 * Separate from the timeline on purpose: a household with a long list of
 * undated tasks would otherwise push them through every dated page, so the
 * cost of reading "next week" would grow with a backlog that has nothing to do
 * with next week.
 */
export async function listUndatedTasks(
  householdId: string,
  options: UndatedOptions,
): Promise<Page<ITask>> {
  const baseFilter: Record<string, unknown> = {
    householdId: new Types.ObjectId(householdId),
    isDeleted: { $ne: true },
    // `$eq: null` matches BOTH an explicit null and a missing key, which is
    // what documents created before dueDate existed look like.
    dueDate: null,
  };

  let pageFilter = baseFilter;
  if (options.cursor) {
    const cursor = decodeCursor(options.cursor, isUndatedCursor);
    pageFilter = { ...baseFilter, _id: { $lt: new Types.ObjectId(cursor.id) } };
  }

  const [total, docs] = await Promise.all([
    options.cursor ? Promise.resolve(null) : TaskModel.countDocuments(baseFilter),
    TaskModel.find(pageFilter)
      .sort(UNDATED_SORT)
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
    nextCursor: hasMore && last ? encodeCursor({ v: 1, id: last._id.toString() }) : null,
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
  notifyTaskAssigned(task, userId);
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
  // Excludes soft-deleted tasks (TD-009): a deleted task is not editable —
  // restore it first via POST .../restore.
  const task = await TaskModel.findOne({ _id: taskId, householdId, isDeleted: { $ne: true } });
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
  // Excludes soft-deleted tasks (TD-009), same as updateTask.
  const task = await TaskModel.findOne({ _id: taskId, householdId, isDeleted: { $ne: true } });
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
  notifyTaskCompleted(task, userId);
  emitToHousehold(householdId, 'task:completed', task.toJSON());
  return task;
}

/**
 * Soft-delete a task (TD-009) and broadcast `task:deleted`.
 *
 * Restricted to the task's creator or a household admin (TD-011, Hard Rule
 * 17) — fetches the task first (rather than update-by-filter) so the
 * permission check runs before anything is mutated. The lookup deliberately
 * does NOT exclude already-deleted tasks (unlike updateTask/completeTask):
 * deleting an already-deleted task must be a safe no-op, not a 404, so a
 * retried/duplicate DELETE request behaves identically to the first one.
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

  // Idempotent no-op: already deleted, nothing changes and no duplicate
  // event is broadcast (matches the "don't re-emit on replay" spirit of
  // ADR-007's idempotency handling).
  if (task.isDeleted) {
    return;
  }

  task.isDeleted = true;
  task.deletedAt = new Date();
  await task.save();
  emitToHousehold(householdId, 'task:deleted', { id: taskId, householdId });
}

/**
 * Restore a soft-deleted task (TD-009) and broadcast `task:updated`.
 *
 * Restricted to the task's creator or a household admin, same rule as
 * edit/delete (TD-011, Hard Rule 17). Restoring a task that is not
 * (or no longer) deleted is a safe no-op rather than an error, for the same
 * retry-safety reason as deleteTask's no-op branch.
 */
export async function restoreTask(
  householdId: string,
  userId: string,
  taskId: string,
  memberRole: Role,
): Promise<ITask> {
  const task = await TaskModel.findOne({ _id: taskId, householdId });
  if (!task) {
    throw new AppError('Task not found', 404);
  }
  if (!canModifyTask(task, userId, memberRole)) {
    throw new AppError('You do not have permission to modify this task', 403);
  }

  if (task.isDeleted) {
    task.isDeleted = false;
    task.deletedAt = undefined;
    await task.save();
    await populated(task);
    emitToHousehold(householdId, 'task:updated', task.toJSON());
    return task;
  }

  await populated(task);
  return task;
}

export const DEFAULT_PURGE_DAYS = 30;

/**
 * Hard-delete soft-deleted tasks whose `deletedAt` is older than `days`
 * (TD-048, follow-up to TD-046's soft delete: marking a task isDeleted
 * stopped it from being visible, but nothing ever removed the document, so
 * the `tasks` collection accumulates trash forever).
 *
 * Shared by the `purge-trash` maintenance script (global — no `householdId`,
 * meant for a daily cron across every household) and
 * `purgeHouseholdTrash` (the admin-only HTTP endpoint, scoped to one
 * household) so both purge paths run the exact same query and can never
 * drift apart.
 */
export async function purgeDeletedTasks(days: number, householdId?: string): Promise<number> {
  if (!Number.isFinite(days) || days < 0) {
    throw new AppError('days must be a non-negative number', 400);
  }

  const cutoff = new Date(Date.now() - days * 24 * 60 * 60 * 1000);
  const filter: Record<string, unknown> = { isDeleted: true, deletedAt: { $lt: cutoff } };
  if (householdId) {
    filter.householdId = new Types.ObjectId(householdId);
  }

  const { deletedCount } = await TaskModel.deleteMany(filter);
  return deletedCount ?? 0;
}

/**
 * Household-scoped trash purge for `POST /households/:householdId/tasks/purge`.
 * Admin-only: an accidental or malicious purge is unrecoverable (unlike soft
 * delete, there is no restore for this), so it gets the same authorization
 * bar as removing a member (household.service.ts's removeMember) rather than
 * the creator-or-admin rule the rest of task mutation uses.
 *
 * Broadcasts `tasks:purged` when anything was actually deleted, so any other
 * connected device looking at the trash view (or holding purged rows in its
 * offline cache) refreshes instead of drifting from what the server now has.
 */
export async function purgeHouseholdTrash(
  householdId: string,
  memberRole: Role,
  days: number,
): Promise<number> {
  if (memberRole !== 'admin') {
    throw new AppError('Only admins can purge the trash', 403);
  }

  const deleted = await purgeDeletedTasks(days, householdId);
  if (deleted > 0) {
    emitToHousehold(householdId, 'tasks:purged', { householdId, deleted });
  }
  return deleted;
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
  // Excludes soft-deleted tasks (TD-009/TD-046): a deleted completed
  // occurrence should not seed further catch-up generation for its series.
  const completedRecurring = await TaskModel.find({
    householdId: new Types.ObjectId(householdId),
    isRecurring: true,
    status: 'completed',
    isDeleted: { $ne: true },
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

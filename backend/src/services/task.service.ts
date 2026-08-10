import { Types } from 'mongoose';
import { TaskModel, ITask, IRecurrenceRule } from '../models/Task';
import { AppError } from '../middleware/error.middleware';
import { emitToHousehold } from '../config/socket';
import { calculateNextDueDate } from '../utils/recurrence';
import { logger } from '../utils/logger';
import { TaskStatus, TaskPriority, TaskCategory } from '../types';

const POPULATE_FIELDS = 'name email avatarUrl';

export interface CreateTaskInput {
  title: string;
  description?: string;
  assignedTo?: string[];
  dueDate?: string | Date;
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
  priority?: TaskPriority;
  status?: TaskStatus;
  category?: TaskCategory;
  isRecurring?: boolean;
  recurrenceRule?: IRecurrenceRule;
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
  dueDate: Date
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
 * List a household's tasks. Pending tasks come first, then by dueDate asc.
 * Optionally filter by status via the `status` argument.
 */
export async function listTasks(
  householdId: string,
  userId: string,
  status?: TaskStatus
): Promise<ITask[]> {
  const filter: Record<string, unknown> = { householdId: new Types.ObjectId(householdId) };
  if (status) filter.status = status;

  // status:-1 puts "pending" before "completed"; then earliest dueDate first.
  return TaskModel.find(filter)
    .sort({ status: -1, dueDate: 1, createdAt: -1 })
    .populate('assignedTo', POPULATE_FIELDS)
    .populate('createdBy', POPULATE_FIELDS)
    .populate('completedBy', POPULATE_FIELDS);
}

/**
 * Create a task in a household and broadcast `task:created`.
 */
export async function createTask(
  householdId: string,
  userId: string,
  input: CreateTaskInput
): Promise<ITask> {
  if (!input.title || input.title.trim() === '') {
    throw new AppError('Task title is required', 400);
  }

  const task = await TaskModel.create({
    householdId: new Types.ObjectId(householdId),
    title: input.title.trim(),
    description: input.description,
    assignedTo: (input.assignedTo || []).map((id) => new Types.ObjectId(id)),
    createdBy: new Types.ObjectId(userId),
    priority: input.priority || 'medium',
    category: input.category || 'other',
    dueDate: input.dueDate ? new Date(input.dueDate) : undefined,
    isRecurring: input.isRecurring ?? false,
    recurrenceRule: input.recurrenceRule,
  });

  await populated(task);
  emitToHousehold(householdId, 'task:created', task.toJSON());
  return task;
}

/**
 * Apply a partial update to a task and broadcast `task:updated`.
 */
export async function updateTask(
  householdId: string,
  userId: string,
  taskId: string,
  input: UpdateTaskInput
): Promise<ITask> {
  const task = await TaskModel.findOne({ _id: taskId, householdId });
  if (!task) {
    throw new AppError('Task not found', 404);
  }

  if (input.title !== undefined) task.title = input.title.trim();
  if (input.description !== undefined) task.description = input.description;
  if (input.assignedTo !== undefined) {
    task.assignedTo = input.assignedTo.map((id) => new Types.ObjectId(id));
  }
  if (input.dueDate !== undefined) {
    task.dueDate = input.dueDate ? new Date(input.dueDate) : undefined;
  }
  if (input.priority !== undefined) task.priority = input.priority;
  if (input.category !== undefined) task.category = input.category;
  if (input.isRecurring !== undefined) task.isRecurring = input.isRecurring;
  if (input.recurrenceRule !== undefined) task.recurrenceRule = input.recurrenceRule;

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
  taskId: string
): Promise<ITask> {
  const task = await TaskModel.findOne({ _id: taskId, householdId });
  if (!task) {
    throw new AppError('Task not found', 404);
  }

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

  await populated(task);
  emitToHousehold(householdId, 'task:completed', task.toJSON());
  return task;
}

/**
 * Hard-delete a task and broadcast `task:deleted`.
 */
export async function deleteTask(
  householdId: string,
  userId: string,
  taskId: string
): Promise<void> {
  const task = await TaskModel.findOneAndDelete({ _id: taskId, householdId });
  if (!task) {
    throw new AppError('Task not found', 404);
  }

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
  upTo: Date
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

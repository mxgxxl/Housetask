import { Types } from 'mongoose';
import { TaskModel, ITask, IRecurrenceRule } from '../models/Task';
import { AppError } from '../middleware/error.middleware';
import { assertMembership } from './household.service';
import { emitToHousehold } from '../config/socket';
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
 * List a household's tasks. Pending tasks come first, then by dueDate asc.
 * Optionally filter by status via the `status` argument.
 */
export async function listTasks(
  householdId: string,
  userId: string,
  status?: TaskStatus
): Promise<ITask[]> {
  await assertMembership(householdId, userId);

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
  await assertMembership(householdId, userId);

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
  await assertMembership(householdId, userId);

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
  await assertMembership(householdId, userId);

  const task = await TaskModel.findOne({ _id: taskId, householdId });
  if (!task) {
    throw new AppError('Task not found', 404);
  }

  task.status = 'completed';
  task.completedAt = new Date();
  task.completedBy = new Types.ObjectId(userId);
  await task.save();

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
  await assertMembership(householdId, userId);

  const task = await TaskModel.findOneAndDelete({ _id: taskId, householdId });
  if (!task) {
    throw new AppError('Task not found', 404);
  }

  emitToHousehold(householdId, 'task:deleted', { id: taskId, householdId });
}

import { Response } from 'express';
import * as taskService from '../services/task.service';
import { AppError } from '../middleware/error.middleware';
import { sendSuccess } from '../utils/response';
import { AuthenticatedRequest, TaskStatus } from '../types';

const VALID_STATUS: TaskStatus[] = ['pending', 'completed'];

/**
 * GET /api/households/:householdId/tasks?status=pending|completed
 * Lists tasks (pending first, then by dueDate asc).
 */
export async function list(req: AuthenticatedRequest, res: Response): Promise<void> {
  const statusParam = req.query.status;
  let status: TaskStatus | undefined;
  if (typeof statusParam === 'string') {
    if (!VALID_STATUS.includes(statusParam as TaskStatus)) {
      throw new AppError('Invalid status filter', 400);
    }
    status = statusParam as TaskStatus;
  }

  const tasks = await taskService.listTasks(req.params.householdId, req.user!.userId, status);
  sendSuccess(res, tasks);
}

/**
 * POST /api/households/:householdId/tasks
 * Creates a task and broadcasts task:created.
 */
export async function create(req: AuthenticatedRequest, res: Response): Promise<void> {
  const task = await taskService.createTask(
    req.params.householdId,
    req.user!.userId,
    req.body ?? {}
  );
  sendSuccess(res, task, 201);
}

/**
 * PATCH /api/households/:householdId/tasks/:taskId
 * Partial update; broadcasts task:updated.
 */
export async function update(req: AuthenticatedRequest, res: Response): Promise<void> {
  const task = await taskService.updateTask(
    req.params.householdId,
    req.user!.userId,
    req.params.taskId,
    req.body ?? {}
  );
  sendSuccess(res, task);
}

/**
 * PATCH /api/households/:householdId/tasks/:taskId/complete
 * Marks the task complete; broadcasts task:completed.
 */
export async function complete(req: AuthenticatedRequest, res: Response): Promise<void> {
  const task = await taskService.completeTask(
    req.params.householdId,
    req.user!.userId,
    req.params.taskId
  );
  sendSuccess(res, task);
}

/**
 * DELETE /api/households/:householdId/tasks/:taskId
 * Hard-deletes the task; broadcasts task:deleted.
 */
export async function remove(req: AuthenticatedRequest, res: Response): Promise<void> {
  await taskService.deleteTask(req.params.householdId, req.user!.userId, req.params.taskId);
  sendSuccess(res, { message: 'Task deleted' });
}

/**
 * POST /api/households/:householdId/tasks/generate-instances
 * Body: { upTo?: ISO date } (defaults to now)
 * Catch-up: generates missed recurring occurrences up to `upTo`.
 * Broadcasts tasks:batch_created.
 */
export async function generateRecurringInstances(
  req: AuthenticatedRequest,
  res: Response
): Promise<void> {
  const rawUpTo = (req.body ?? {}).upTo;
  const upTo = rawUpTo ? new Date(rawUpTo) : new Date();
  if (Number.isNaN(upTo.getTime())) {
    throw new AppError('Invalid upTo date', 400);
  }

  const result = await taskService.catchUpRecurring(
    req.params.householdId,
    req.user!.userId,
    upTo
  );
  sendSuccess(res, result);
}

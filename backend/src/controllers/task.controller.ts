import { Response } from 'express';
import * as taskService from '../services/task.service';
import { AppError } from '../middleware/error.middleware';
import { sendSuccess } from '../utils/response';
import { parseCursorParam, parseDateParam, parseLimit } from '../utils/pagination';
import { AuthenticatedRequest, TaskStatus } from '../types';

const VALID_STATUS: TaskStatus[] = ['pending', 'completed'];

/**
 * Parse the `days` query param for the purge endpoint. Absent falls back to
 * taskService.DEFAULT_PURGE_DAYS (30); present-but-invalid is a 400, same
 * convention as pagination.ts's parseLimit/parseCursorParam.
 */
function parseDays(raw: unknown): number | undefined {
  if (raw === undefined) return undefined;
  if (typeof raw !== 'string') {
    throw new AppError('Invalid days', 400);
  }
  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new AppError('days must be a non-negative integer', 400);
  }
  return parsed;
}

/**
 * GET /api/households/:householdId/tasks?status=&limit=&cursor=&from=&to=&includeDeleted=
 * Lists one page of tasks (pending first, then by dueDate asc). `from`/`to`
 * (PDR-003) additionally restrict dueDate to that window — see
 * taskService.listTasks for how they combine with status and undated tasks.
 * `includeDeleted=true` (TD-009) additionally includes soft-deleted tasks,
 * for the frontend's trash view — every other value/absence excludes them.
 * Responds with { items, nextCursor, hasMore, total }.
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

  const page = await taskService.listTasks(req.params.householdId, req.user!.userId, {
    status,
    limit: parseLimit(req.query.limit),
    cursor: parseCursorParam(req.query.cursor),
    from: parseDateParam(req.query.from, 'from'),
    to: parseDateParam(req.query.to, 'to'),
    includeDeleted: req.query.includeDeleted === 'true',
  });
  sendSuccess(res, page);
}

/**
 * GET /api/households/:householdId/tasks/timeline?from=<ISO>&limit=&cursor=
 *
 * Active, DATED tasks from `from` onwards, keyset-paginated (TD-064).
 * `from` is required: it is both the lower bound and the identity of the
 * pagination session, so there is no sensible default — a missing one would
 * silently start a different walk than the cursors already in flight.
 */
export async function timeline(req: AuthenticatedRequest, res: Response): Promise<void> {
  const from = parseDateParam(req.query.from, 'from');
  if (!from) {
    throw new AppError('from is required', 400);
  }

  const page = await taskService.listTimeline(req.params.householdId, {
    from,
    limit: parseLimit(req.query.limit),
    cursor: parseCursorParam(req.query.cursor),
  });
  sendSuccess(res, page);
}

/**
 * GET /api/households/:householdId/tasks/undated?limit=&cursor=
 *
 * Active tasks with no due date, paginated on their own so a backlog of them
 * never rides along with every dated page (TD-064).
 */
export async function undated(req: AuthenticatedRequest, res: Response): Promise<void> {
  const page = await taskService.listUndatedTasks(req.params.householdId, {
    limit: parseLimit(req.query.limit),
    cursor: parseCursorParam(req.query.cursor),
  });
  sendSuccess(res, page);
}

/**
 * POST /api/households/:householdId/tasks
 * Creates a task and broadcasts task:created.
 */
export async function create(req: AuthenticatedRequest, res: Response): Promise<void> {
  const task = await taskService.createTask(
    req.params.householdId,
    req.user!.userId,
    req.body ?? {},
    req.member!.memberIds,
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
    req.body ?? {},
    req.member!.memberIds,
    req.member!.role,
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
    req.params.taskId,
  );
  sendSuccess(res, task);
}

/**
 * DELETE /api/households/:householdId/tasks/:taskId
 * Soft-deletes the task (TD-009: sets isDeleted/deletedAt, does not remove
 * the document); broadcasts task:deleted. Idempotent — deleting an
 * already-deleted task is a no-op, not a 404.
 */
export async function remove(req: AuthenticatedRequest, res: Response): Promise<void> {
  await taskService.deleteTask(
    req.params.householdId,
    req.user!.userId,
    req.params.taskId,
    req.member!.role,
  );
  sendSuccess(res, { message: 'Task deleted' });
}

/**
 * POST /api/households/:householdId/tasks/:taskId/restore
 * Restores a soft-deleted task (TD-009); broadcasts task:updated. Restricted
 * to the task's creator or a household admin, same as edit/delete (TD-011).
 */
export async function restore(req: AuthenticatedRequest, res: Response): Promise<void> {
  const task = await taskService.restoreTask(
    req.params.householdId,
    req.user!.userId,
    req.params.taskId,
    req.member!.role,
  );
  sendSuccess(res, task);
}

/**
 * POST /api/households/:householdId/tasks/purge?days=
 * Hard-deletes soft-deleted tasks older than `days` (default 30, TD-048).
 * Admin-only; broadcasts tasks:purged when anything was deleted.
 * Responds { deleted: number }.
 */
export async function purge(req: AuthenticatedRequest, res: Response): Promise<void> {
  const days = parseDays(req.query.days) ?? taskService.DEFAULT_PURGE_DAYS;
  const deleted = await taskService.purgeHouseholdTrash(
    req.params.householdId,
    req.member!.role,
    days,
  );
  sendSuccess(res, { deleted });
}

/**
 * POST /api/households/:householdId/tasks/generate-instances
 * Body: { upTo?: ISO date } (defaults to now)
 * Catch-up: generates missed recurring occurrences up to `upTo`.
 * Broadcasts tasks:batch_created.
 */
export async function generateRecurringInstances(
  req: AuthenticatedRequest,
  res: Response,
): Promise<void> {
  const rawUpTo = (req.body ?? {}).upTo;
  const upTo = rawUpTo ? new Date(rawUpTo) : new Date();
  if (Number.isNaN(upTo.getTime())) {
    throw new AppError('Invalid upTo date', 400);
  }

  const result = await taskService.catchUpRecurring(req.params.householdId, req.user!.userId, upTo);
  sendSuccess(res, result);
}

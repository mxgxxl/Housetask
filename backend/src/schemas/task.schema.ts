import { z } from 'zod';

// Mirrors task.service.ts's MAX_TITLE_LENGTH/MAX_DESCRIPTION_LENGTH and its
// sanitizeString() error message format exactly, so switching the check to
// the Zod edge doesn't change what a client sees.
const MAX_TITLE_LENGTH = 200;
const MAX_DESCRIPTION_LENGTH = 2000;

// { error } (Zod v4's unified message param) covers missing/null/wrong-type
// with the same message .min() alone would only cover for an empty string —
// a missing `title` would otherwise surface Zod's generic "expected string,
// received undefined" instead of this codebase's existing message.
const title = z
  .string({ error: 'Task title is required' })
  .trim()
  .min(1, 'Task title is required')
  .max(MAX_TITLE_LENGTH, `Task title must be at most ${MAX_TITLE_LENGTH} characters`);

const description = z
  .string()
  .trim()
  .max(
    MAX_DESCRIPTION_LENGTH,
    `Task description must be at most ${MAX_DESCRIPTION_LENGTH} characters`,
  );

const priority = z.enum(['low', 'medium', 'high']);
const category = z.enum(['cleaning', 'cooking', 'shopping', 'maintenance', 'other']);
const status = z.enum(['pending', 'completed']);

// Mirrors models/Task.ts's recurrenceRuleSchema. Unlike the Mongoose schema,
// `type` is required here: Mongoose's own `type` field isn't `required:
// true` despite being non-optional in the IRecurrenceRule TS interface, and
// downstream code (task.service.ts's generateNextInstance) has to guard
// against a missing `type` at runtime — exactly the inconsistent-data gap
// PDR-001 calls out. Closing it here is a deliberate tightening, not part
// of the literal request; verified no existing test omits `type`.
const recurrenceRule = z.object({
  type: z.enum(['daily', 'weekly', 'monthly', 'custom']),
  interval: z.coerce.number().int().positive().optional(),
  daysOfWeek: z.array(z.coerce.number().int().min(0).max(6)).optional(),
  dayOfMonth: z.coerce.number().int().min(1).max(31).optional(),
});

// A date field that may be cleared with an explicit `null` (used by
// updateTaskSchema). z.null() MUST come before z.coerce.date() in this
// union: z.coerce.date() "succeeds" on `null` via JS's `new Date(null)` ===
// epoch (1970-01-01), so with the branches in the other order a client
// sending `null` to clear a date would silently get the epoch instead —
// verified against zod's actual union-resolution order, not assumed.
const nullableCoercedDate = z.union([z.null(), z.coerce.date()]);

/**
 * POST /api/tasks body. `endsAt > startsAt` is enforced here only when
 * !isRecurring, matching task.service.ts's assertValidDuration exactly: a
 * recurring task's startsAt/endsAt are never persisted regardless of what's
 * sent (PDR-004), so the service never validates their range either — this
 * schema must not reject something the service has always silently allowed.
 * `recurrenceRule` is required when isRecurring is true (see above).
 */
export const createTaskSchema = z
  .object({
    title,
    description: description.optional(),
    dueDate: z.coerce.date().optional(),
    assignedTo: z.array(z.string()).optional(),
    priority: priority.optional(),
    category: category.optional(),
    isRecurring: z.boolean().default(false),
    recurrenceRule: recurrenceRule.optional(),
    startsAt: z.coerce.date().optional(),
    endsAt: z.coerce.date().optional(),
  })
  .superRefine((data, ctx) => {
    if (!data.isRecurring && data.startsAt && data.endsAt && data.endsAt <= data.startsAt) {
      ctx.addIssue({ code: 'custom', message: 'endsAt must be after startsAt', path: ['endsAt'] });
    }
    if (data.isRecurring && !data.recurrenceRule) {
      ctx.addIssue({
        code: 'custom',
        message: 'recurrenceRule is required when isRecurring is true',
        path: ['recurrenceRule'],
      });
    }
  });

/**
 * PATCH /api/tasks/:id body. Deliberately does NOT re-check `endsAt >
 * startsAt` here: task.service.ts:updateTask validates the range against
 * the MERGED result (a PATCH sending only `endsAt` is checked against the
 * task's EXISTING startsAt from the database) — a stateless edge schema
 * cannot see that existing value, so this invariant has to stay
 * service-side. Confirmed against tasks.test.ts's "should reject a PATCH
 * that would make endsAt <= startsAt" case, which sends `{ endsAt }` alone.
 *
 * `title`, unlike task.service.ts's current sanitizeString-only check on
 * update, DOES reject an empty string here (min(1)) — closing a real gap
 * (PATCH { title: '' } previously succeeded, silently blanking the title;
 * no existing test relies on that).
 */
export const updateTaskSchema = z.object({
  title: title.optional(),
  description: description.optional(),
  dueDate: nullableCoercedDate.optional(),
  assignedTo: z.array(z.string()).optional(),
  priority: priority.optional(),
  category: category.optional(),
  status: status.optional(),
  isRecurring: z.boolean().optional(),
  recurrenceRule: recurrenceRule.optional(),
  startsAt: nullableCoercedDate.optional(),
  endsAt: nullableCoercedDate.optional(),
});

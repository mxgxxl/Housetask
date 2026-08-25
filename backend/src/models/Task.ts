import { Schema, model, Document, Types } from 'mongoose';
import { TaskStatus, TaskPriority, TaskCategory, RecurrenceType } from '../types';
import { jsonSchemaOptions } from '../utils/toJSON';

export interface IRecurrenceRule {
  type: RecurrenceType;
  interval?: number;
  daysOfWeek?: number[];
  dayOfMonth?: number;
}

/**
 * A household task. Indexed by householdId for fast per-household listing.
 * Supports assignment to multiple members and optional recurrence.
 */
export interface ITask extends Document {
  _id: Types.ObjectId;
  householdId: Types.ObjectId;
  title: string;
  description?: string;
  assignedTo: Types.ObjectId[];
  createdBy: Types.ObjectId;
  status: TaskStatus;
  priority: TaskPriority;
  category: TaskCategory;
  dueDate?: Date;
  /**
   * Optional duration (PDR-004): absent = an instantaneous task
   * (retrocompatible with every task created before this feature). A
   * recurring task never carries these — duration + recurrence is out of
   * scope this round, see task.service.ts.
   */
  startsAt?: Date;
  endsAt?: Date;
  completedAt?: Date;
  completedBy?: Types.ObjectId;
  isRecurring: boolean;
  recurrenceRule?: IRecurrenceRule;
  parentTaskId?: Types.ObjectId | null;
  /**
   * Soft delete (TD-009): DELETE marks a task deleted instead of removing the
   * document. Every read path excludes isDeleted:true by default — see
   * task.service.ts's listTasks/updateTask/completeTask — so a deleted task
   * behaves like a hard delete everywhere except the opt-in trash view
   * (`includeDeleted`) and the creator-or-admin restore endpoint.
   */
  isDeleted: boolean;
  deletedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

const recurrenceRuleSchema = new Schema<IRecurrenceRule>(
  {
    type: { type: String, enum: ['daily', 'weekly', 'monthly', 'custom'] },
    interval: { type: Number, default: 1 },
    daysOfWeek: { type: [{ type: Number, min: 0, max: 6 }], default: undefined },
    dayOfMonth: { type: Number, min: 1, max: 31 },
  },
  { _id: false },
);

const taskSchema = new Schema<ITask>(
  {
    householdId: {
      type: Schema.Types.ObjectId,
      ref: 'Household',
      required: true,
      index: true,
    },
    title: { type: String, required: true, trim: true },
    description: { type: String },
    assignedTo: [{ type: Schema.Types.ObjectId, ref: 'User' }],
    createdBy: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    status: { type: String, enum: ['pending', 'completed'], default: 'pending', index: true },
    priority: { type: String, enum: ['low', 'medium', 'high'], default: 'medium' },
    category: {
      type: String,
      enum: ['cleaning', 'cooking', 'shopping', 'maintenance', 'other'],
      default: 'other',
    },
    dueDate: { type: Date },
    startsAt: { type: Date },
    endsAt: { type: Date },
    completedAt: { type: Date },
    completedBy: { type: Schema.Types.ObjectId, ref: 'User' },
    isRecurring: { type: Boolean, default: false },
    recurrenceRule: { type: recurrenceRuleSchema, default: undefined },
    // Links a generated occurrence back to the original recurring task.
    parentTaskId: {
      type: Schema.Types.ObjectId,
      ref: 'Task',
      required: false,
      default: null,
      index: true,
    },
    isDeleted: { type: Boolean, default: false, index: true },
    deletedAt: { type: Date },
  },
  { timestamps: true, ...jsonSchemaOptions },
);

// Matches the listing sort EXACTLY (householdId equality, then status desc,
// dueDate asc, _id desc). Directions must mirror the sort or MongoDB falls back
// to an in-memory sort, which is capped at 32MB and defeats pagination (TD-026).
// It also subsumes the previous { householdId, status, dueDate } index: every
// other query on those fields uses equality on status, where direction is
// irrelevant, so the old one was pure write overhead.
//
// isDeleted sits before dueDate, not after: it is an equality filter on
// EVERY query this index serves (listTasks excludes isDeleted:true by
// default, and the includeDeleted=true trash view still equality-filters on
// it, just for `true` instead) whereas dueDate is only ever a sort/range
// bound. Placing an always-equality field ahead of a range field keeps the
// index's bounds tight per MongoDB's Equality-Sort-Range guidance — a
// prefix that mixed the range field in before it would force a wider scan.
taskSchema.index({ householdId: 1, status: -1, isDeleted: 1, dueDate: 1, _id: -1 });

// Supports the PDR-003 timeline's from/to window query (GET /tasks?from=&to=),
// which filters by dueDate WITHOUT an equality predicate on status (the
// timeline shows pending and completed tasks together). The index above can't
// produce tight bounds for that shape: status sits between householdId and
// dueDate in its key, and a compound index only bounds a field tightly when
// every field before it is equality-matched (ESR rule) — leaving status
// unconstrained forces a bounds-less scan of the whole household on dueDate.
// This is a genuinely different key order, not a prefix of the index above,
// so it is not redundant with it (unlike the index TD-026 already removed).
//
// TD-064 extends it with `_id` so the keyset timeline's total order
// (`dueDate ASC, _id ASC`) is served entirely from the index: without the
// tiebreaker in the key, every page whose boundary falls inside a group of
// tasks sharing a dueDate would need an in-memory sort to resolve it, which
// is exactly where a cursor walk must not lose its footing.
//
// Note for whoever looks at Atlas: Mongoose only CREATES indexes, it never
// drops them, so the two-field `{householdId, dueDate}` version still exists
// there. It is a prefix of this one and therefore redundant — dropping it is
// a safe manual cleanup, not something this schema can do.
taskSchema.index({ householdId: 1, dueDate: 1, _id: 1 });

export const TaskModel = model<ITask>('Task', taskSchema);

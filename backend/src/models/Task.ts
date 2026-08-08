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
  completedAt?: Date;
  completedBy?: Types.ObjectId;
  isRecurring: boolean;
  recurrenceRule?: IRecurrenceRule;
  createdAt: Date;
  updatedAt: Date;
}

const recurrenceRuleSchema = new Schema<IRecurrenceRule>(
  {
    type: { type: String, enum: ['daily', 'weekly', 'monthly', 'custom'] },
    interval: { type: Number },
    daysOfWeek: { type: [Number], default: undefined },
    dayOfMonth: { type: Number },
  },
  { _id: false }
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
    completedAt: { type: Date },
    completedBy: { type: Schema.Types.ObjectId, ref: 'User' },
    isRecurring: { type: Boolean, default: false },
    recurrenceRule: { type: recurrenceRuleSchema, default: undefined },
  },
  { timestamps: true, ...jsonSchemaOptions }
);

// Compound index optimizes the default listing (household + status + dueDate).
taskSchema.index({ householdId: 1, status: 1, dueDate: 1 });

export const TaskModel = model<ITask>('Task', taskSchema);

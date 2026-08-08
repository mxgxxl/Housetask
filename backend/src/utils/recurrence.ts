import { addDays, addWeeks, addMonths } from 'date-fns';

/**
 * Recurrence rule shape accepted by {@link calculateNextDueDate}. Structurally
 * compatible with the `IRecurrenceRule` stored on tasks.
 */
export interface RecurrenceRuleInput {
  type: 'daily' | 'weekly' | 'monthly' | 'custom';
  interval?: number;
  daysOfWeek?: number[]; // 0=Sunday, 1=Monday...
  dayOfMonth?: number;
}

/**
 * Compute the next due date for a recurring task given its current due date
 * and recurrence rule.
 *
 * - `daily`   → advance by `interval` days.
 * - `weekly`  → if `daysOfWeek` is set, jump to the next valid weekday
 *               (wrapping into the following week); otherwise advance by
 *               `interval` weeks.
 * - `monthly` → advance by `interval` months, clamping `dayOfMonth` to the
 *               last valid day of the target month.
 * - `custom`  → advance by `interval` days (fallback).
 */
export function calculateNextDueDate(currentDueDate: Date, rule: RecurrenceRuleInput): Date {
  const base = new Date(currentDueDate);

  switch (rule.type) {
    case 'daily':
      return addDays(base, rule.interval || 1);

    case 'weekly': {
      if (rule.daysOfWeek && rule.daysOfWeek.length > 0) {
        const sortedDays = [...rule.daysOfWeek].sort((a, b) => a - b);
        const currentDay = base.getDay();

        // Next valid weekday later in the same week.
        const nextInWeek = sortedDays.find((d) => d > currentDay);
        if (nextInWeek !== undefined) {
          return addDays(base, nextInWeek - currentDay);
        }
        // Otherwise wrap to the first valid weekday of the following week.
        const daysToAdd = 7 - currentDay + sortedDays[0];
        return addDays(base, daysToAdd);
      }
      return addWeeks(base, rule.interval || 1);
    }

    case 'monthly': {
      if (rule.dayOfMonth) {
        const next = addMonths(base, rule.interval || 1);
        const lastDayOfMonth = new Date(next.getFullYear(), next.getMonth() + 1, 0).getDate();
        next.setDate(Math.min(rule.dayOfMonth, lastDayOfMonth));
        return next;
      }
      return addMonths(base, rule.interval || 1);
    }

    case 'custom':
    default:
      return addDays(base, rule.interval || 1);
  }
}

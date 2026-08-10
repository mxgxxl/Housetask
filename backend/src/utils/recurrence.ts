import { addDays, addWeeks } from 'date-fns';

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
 * Advance a date by whole months, anchoring the day to the rule instead of to
 * the previous (possibly clamped) occurrence.
 *
 * Deriving the day from the previous occurrence is what makes a monthly series
 * decay: a "day 31" task clamped to Feb 28 would then produce Mar 28, Apr 28…
 * and never return to 31. Re-reading the anchor every time means February only
 * borrows the day for one occurrence (TD-025).
 *
 * All arithmetic is UTC (ADR-006): the local-time equivalents would resolve a
 * late-evening due date into the neighbouring day — and therefore the
 * neighbouring month — depending on the server's timezone.
 */
function addMonthsAnchored(base: Date, interval: number, dayOfMonth?: number): Date {
  // Without an explicit anchor the current day is the best available one.
  const anchorDay = dayOfMonth ?? base.getUTCDate();
  const year = base.getUTCFullYear();
  const month = base.getUTCMonth() + interval;

  // Day 0 of the following month is the last day of the target month; Date.UTC
  // normalizes month overflow (e.g. month 13 → February of the next year).
  const lastDayOfTargetMonth = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();

  const next = new Date(base);
  // Setting year/month/day in one call avoids the classic overflow where
  // setting the month first rolls "Jan 31" into March.
  next.setUTCFullYear(year, month, Math.min(anchorDay, lastDayOfTargetMonth));
  return next;
}

/**
 * Advance to the next weekday listed in the rule, anchored to `daysOfWeek`
 * rather than to an offset from the previous occurrence, so the series always
 * lands on the configured days.
 */
function nextWeekday(base: Date, daysOfWeek: number[]): Date {
  const days = [...new Set(daysOfWeek)]
    .filter((d) => Number.isInteger(d) && d >= 0 && d <= 6)
    .sort((a, b) => a - b);

  if (days.length === 0) {
    return addWeeks(base, 1);
  }

  const current = base.getUTCDay();
  const laterThisWeek = days.find((d) => d > current);

  return addDays(base, laterThisWeek !== undefined ? laterThisWeek - current : 7 - current + days[0]);
}

/**
 * Compute the next due date for a recurring task given its current due date
 * and recurrence rule. The time of day is always preserved.
 *
 * - `daily`   → advance by `interval` days.
 * - `weekly`  → if `daysOfWeek` is set, jump to the next listed weekday
 *               (wrapping into the following week); otherwise advance by
 *               `interval` weeks.
 * - `monthly` → advance by `interval` months, anchoring the day to
 *               `dayOfMonth` and clamping to the last day of the target month.
 * - `custom`  → advance by `interval` days (fallback).
 */
export function calculateNextDueDate(currentDueDate: Date, rule: RecurrenceRuleInput): Date {
  const base = new Date(currentDueDate);
  const interval = Number.isInteger(rule.interval) && rule.interval! > 0 ? rule.interval! : 1;

  switch (rule.type) {
    case 'daily':
      return addDays(base, interval);

    case 'weekly':
      return rule.daysOfWeek && rule.daysOfWeek.length > 0
        ? nextWeekday(base, rule.daysOfWeek)
        : addWeeks(base, interval);

    case 'monthly':
      return addMonthsAnchored(base, interval, rule.dayOfMonth);

    case 'custom':
    default:
      return addDays(base, interval);
  }
}

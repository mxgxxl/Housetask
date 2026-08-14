import { calculateNextDueDate } from '../utils/recurrence';

/** Compare only the calendar day, in UTC (ADR-006). */
function day(date: Date): string {
  return date.toISOString().slice(0, 10);
}

/** 09:00 UTC on the given ISO day, so time-of-day preservation is observable. */
function at(isoDay: string): Date {
  return new Date(`${isoDay}T09:00:00.000Z`);
}

describe('calculateNextDueDate — monthly', () => {
  it('should clamp day 31 into February and recover the anchor in March', () => {
    const rule = { type: 'monthly' as const, interval: 1, dayOfMonth: 31 };

    const february = calculateNextDueDate(at('2025-01-31'), rule);
    const march = calculateNextDueDate(february, rule);

    expect(day(february)).toBe('2025-02-28');
    // The anchor is re-read from the rule, so February's clamp is not
    // inherited by every later occurrence (TD-025).
    expect(day(march)).toBe('2025-03-31');
  });

  it('should clamp day 30 into February and recover it in March', () => {
    const rule = { type: 'monthly' as const, interval: 1, dayOfMonth: 30 };

    const february = calculateNextDueDate(at('2025-01-30'), rule);
    const march = calculateNextDueDate(february, rule);

    expect(day(february)).toBe('2025-02-28');
    expect(day(march)).toBe('2025-03-30');
  });

  it('should clamp day 29 to the 28th in a common year and keep it in a leap year', () => {
    const rule = { type: 'monthly' as const, interval: 1, dayOfMonth: 29 };

    expect(day(calculateNextDueDate(at('2025-01-29'), rule))).toBe('2025-02-28');
    expect(day(calculateNextDueDate(at('2028-01-29'), rule))).toBe('2028-02-29');
  });

  it('should honour an interval greater than one and preserve the time of day', () => {
    const rule = { type: 'monthly' as const, interval: 3, dayOfMonth: 15 };

    const next = calculateNextDueDate(at('2025-01-15'), rule);

    expect(day(next)).toBe('2025-04-15');
    expect(next.toISOString()).toBe('2025-04-15T09:00:00.000Z');
  });

  it('should roll the year over when the interval crosses December', () => {
    const rule = { type: 'monthly' as const, interval: 2, dayOfMonth: 31 };

    const next = calculateNextDueDate(at('2025-11-30'), rule);

    expect(day(next)).toBe('2026-01-31');
  });
});

describe('calculateNextDueDate — weekly', () => {
  it('should jump to the next listed weekday and wrap into the following week', () => {
    // 2025-01-06 is a Monday. Rule: Mondays (1) and Thursdays (4).
    const rule = { type: 'weekly' as const, interval: 1, daysOfWeek: [1, 4] };

    const thursday = calculateNextDueDate(at('2025-01-06'), rule);
    const nextMonday = calculateNextDueDate(thursday, rule);
    const nextThursday = calculateNextDueDate(nextMonday, rule);

    expect(day(thursday)).toBe('2025-01-09');
    expect(day(nextMonday)).toBe('2025-01-13');
    expect(day(nextThursday)).toBe('2025-01-16');
  });

  it('should advance by whole weeks when no weekdays are listed', () => {
    const rule = { type: 'weekly' as const, interval: 2 };

    expect(day(calculateNextDueDate(at('2025-01-06'), rule))).toBe('2025-01-20');
  });
});

describe('calculateNextDueDate — daily and custom', () => {
  it('should add exactly `interval` days for a daily rule', () => {
    const next = calculateNextDueDate(at('2025-03-10'), { type: 'daily', interval: 2 });

    expect(day(next)).toBe('2025-03-12');
    expect(next.toISOString()).toBe('2025-03-12T09:00:00.000Z');
  });

  it('should default a missing or invalid interval to 1 day', () => {
    expect(day(calculateNextDueDate(at('2025-03-10'), { type: 'daily' }))).toBe('2025-03-11');
    expect(day(calculateNextDueDate(at('2025-03-10'), { type: 'daily', interval: 0 }))).toBe(
      '2025-03-11',
    );
  });

  it('should treat custom as a daily interval', () => {
    expect(day(calculateNextDueDate(at('2025-03-10'), { type: 'custom', interval: 5 }))).toBe(
      '2025-03-15',
    );
  });
});

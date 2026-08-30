import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import { WeeklyPersonalBudgetModel } from '../models/WeeklyPersonalBudget';
import { InMemoryIdempotencyStore } from '../services/idempotency.store';
import { resetP1EnabledResolver, setP1EnabledResolver } from '../services/feature-flag.service';
import {
  ADHOC_ASSIGNED_KEY,
  COMMON_TRANCHE_KEY,
  applyManualOverrides,
  expectedWeeklyFrequency,
  planWeeklyCost,
  resolveAllocationForTask,
} from '../services/economy-p1-budget.service';
import { COMMON_TRANCHE_FRACTION, DEFAULT_TASK_COINS, WEEKLY_CAP_COINS } from '../config/economy-p1';
import { releasedThroughDay, weekKey } from '../utils/economy-period';
import { recentInstantOnDay } from './p1-award';
import { buildTestApp } from './setup';
import {
  TestHousehold,
  TestUser,
  authHeader,
  createTestHousehold,
  createTestUser,
  joinTestHousehold,
} from './helpers';

/**
 * The weekly plan: building it, editing it, and spending against it
 * (TD-066 B8, PDR-011).
 *
 * The property the whole feature rests on is that the plan is DETERMINISTIC —
 * same household, same member, same plan every time. That is what makes
 * "volver a automático" possible without storing a second copy of the plan to
 * restore from, and it is asserted directly rather than assumed.
 *
 * The second property is that a manual edit can never promise more than the
 * ceiling. Inflation is exactly what PDR-011 exists to bound, so a plan that
 * could exceed the cap would defeat the mechanic rather than bend it.
 */
let app: Server;

// A recent Monday, derived from the clock rather than pinned. A fixed date
// EXPIRES: `occurredAt` is rejected as `too_old` past seven days, which is how
// '2026-08-23T10:00:00.000Z' took two sibling suites down on 2026-08-30.
// `recentInstantOnDay` keeps the property that mattered — a known day index —
// without the expiry.
const MONDAY = recentInstantOnDay(0);
const ZONE = 'UTC';

const COMMON_BUDGET = Math.floor(WEEKLY_CAP_COINS * COMMON_TRANCHE_FRACTION);
const NAMED_BUDGET = WEEKLY_CAP_COINS - COMMON_BUDGET;
/** What Monday (day index 0) has released of the weekly ceiling. */
const MONDAY_RELEASE = releasedThroughDay(WEEKLY_CAP_COINS, 0);

beforeAll(async () => {
  app = await buildTestApp({ idempotencyStore: new InMemoryIdempotencyStore() });
});

afterEach(() => {
  resetP1EnabledResolver();
});

function enableP1(): void {
  setP1EnabledResolver(async () => true);
}

async function setup(): Promise<{ user: TestUser; household: TestHousehold }> {
  const user = await createTestUser(app);
  const household = await createTestHousehold(app, user);
  return { user, household };
}

async function addTask(
  user: TestUser,
  householdId: string,
  body: Record<string, unknown>,
): Promise<string> {
  const res = await request(app)
    .post(`/api/households/${householdId}/tasks`)
    .set(authHeader(user.accessToken))
    .send(body);
  if (res.status !== 201) {
    throw new Error(`addTask failed (${res.status}): ${JSON.stringify(res.body)}`);
  }
  return res.body.data.id;
}

function completeTask(
  user: TestUser,
  householdId: string,
  taskId: string,
  key: string,
): request.Test {
  return request(app)
    .post(`/api/households/${householdId}/tasks/${taskId}/completions`)
    .set(authHeader(user.accessToken))
    .set('Idempotency-Key', key)
    .send({ occurredAt: MONDAY, timeZone: ZONE });
}

function patchBudget(
  user: TestUser,
  householdId: string,
  body: Record<string, unknown>,
): request.Test {
  return request(app)
    .patch(`/api/households/${householdId}/economy/p1/budget`)
    .set(authHeader(user.accessToken))
    .send(body);
}

describe('expected weekly frequency', () => {
  it('treats a one-off task as happening once', () => {
    expect(expectedWeeklyFrequency(false)).toBe(100);
    expect(expectedWeeklyFrequency(false, { type: 'daily' })).toBe(100);
  });

  it('reads daily and its interval', () => {
    expect(expectedWeeklyFrequency(true, { type: 'daily' })).toBe(700);
    expect(expectedWeeklyFrequency(true, { type: 'daily', interval: 2 })).toBe(350);
  });

  it('counts an explicit day list as the real frequency', () => {
    // "Mondays and Thursdays" is twice a week, not once.
    expect(expectedWeeklyFrequency(true, { type: 'weekly' })).toBe(100);
    expect(expectedWeeklyFrequency(true, { type: 'weekly', daysOfWeek: [1, 4] })).toBe(200);
    expect(expectedWeeklyFrequency(true, { type: 'weekly', daysOfWeek: [1, 4], interval: 2 })).toBe(
      100,
    );
  });

  it('does not pretend a month is four weeks', () => {
    // 4.345 weeks, not 4: rounding to four would over-pay a monthly chore by
    // about 8% every month.
    expect(expectedWeeklyFrequency(true, { type: 'monthly' })).toBe(435);
  });

  it('never returns zero, which would make a task pay nothing', () => {
    expect(expectedWeeklyFrequency(true, { type: 'custom' })).toBeGreaterThan(0);
    expect(expectedWeeklyFrequency(true, { type: 'monthly', interval: 12 })).toBeGreaterThan(0);
  });
});

describe('the automatic plan', () => {
  it('always reserves the common tranche, even with nothing assigned', async () => {
    // "Cero configuración por defecto" (PDR-011): a household that never
    // assigns anything must still earn, so the tranche comes off the top.
    enableP1();
    const { user, household } = await setup();
    await addTask(user, household.id, { title: 'Sin asignar' });

    const res = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });

    expect(res.status).toBe(200);
    const common = res.body.data.weeklyBudget.allocations.find(
      (a: { allocationKey: string }) => a.allocationKey === COMMON_TRANCHE_KEY,
    );
    expect(common).toBeDefined();
    expect(common.coinAmount).toBe(COMMON_BUDGET);
    expect(common.mode).toBe('automatic');
  });

  it('splits the named budget by expected frequency', async () => {
    enableP1();
    const { user, household } = await setup();
    // Daily (7/week) and weekly (1/week), both assigned to the member: the
    // daily line should carry seven times the weekly one's share.
    await addTask(user, household.id, {
      title: 'Fregar',
      assignedTo: [user.id],
      dueDate: MONDAY,
      isRecurring: true,
      recurrenceRule: { type: 'daily' },
    });
    await addTask(user, household.id, {
      title: 'Basura',
      assignedTo: [user.id],
      dueDate: MONDAY,
      isRecurring: true,
      recurrenceRule: { type: 'weekly' },
    });

    const res = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });
    const allocations = res.body.data.weeklyBudget.allocations as {
      allocationKey: string;
      expectedFrequency: number;
      coinAmount: number;
    }[];

    const named = allocations.filter((a) => a.allocationKey !== COMMON_TRANCHE_KEY);
    expect(named).toHaveLength(2);

    const daily = named.find((a) => a.expectedFrequency === 700)!;
    const weekly = named.find((a) => a.expectedFrequency === 100)!;

    // Shares are 7/8 and 1/8 of the named budget; each line's coinAmount is
    // its share divided by how often it is expected, so doing everything
    // exactly as expected consumes exactly the ceiling.
    expect(daily.coinAmount).toBe(Math.floor(Math.floor((NAMED_BUDGET * 7) / 8) / 7));
    expect(weekly.coinAmount).toBe(Math.floor(NAMED_BUDGET / 8));
    expect(daily.coinAmount).toBeGreaterThan(0);
  });

  it('never promises more than the ceiling', async () => {
    enableP1();
    const { user, household } = await setup();
    for (const type of ['daily', 'weekly', 'monthly'] as const) {
      await addTask(user, household.id, {
        title: `Serie ${type}`,
        assignedTo: [user.id],
        dueDate: MONDAY,
        isRecurring: true,
        recurrenceRule: { type },
      });
    }
    await addTask(user, household.id, { title: 'Suelta', assignedTo: [user.id] });
    await addTask(user, household.id, { title: 'Sin asignar' });

    const res = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });
    expect(planWeeklyCost(res.body.data.weeklyBudget.allocations)).toBeLessThanOrEqual(
      WEEKLY_CAP_COINS,
    );
  });

  it('is deterministic — the same household yields the same plan', async () => {
    enableP1();
    const { user, household } = await setup();
    await addTask(user, household.id, {
      title: 'Fregar',
      assignedTo: [user.id],
      dueDate: MONDAY,
      isRecurring: true,
      recurrenceRule: { type: 'daily' },
    });

    const first = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });
    const second = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });

    expect(second.body.data.weeklyBudget.allocations).toEqual(
      first.body.data.weeklyBudget.allocations,
    );
  });

  it('leaves another member out of this member\'s plan', async () => {
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    await addTask(user, household.id, { title: 'Del compañero', assignedTo: [mate.id] });

    const res = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });
    const keys = res.body.data.weeklyBudget.allocations.map(
      (a: { allocationKey: string }) => a.allocationKey,
    );
    // Someone else's commitment does not consume this member's ceiling.
    expect(keys).toEqual([COMMON_TRANCHE_KEY]);
  });

  it('aggregates one-off assigned tasks into a single line', async () => {
    // A per-task line would churn constantly: an ad-hoc task exists for days
    // and then is gone, taking any stepper the user adjusted with it.
    enableP1();
    const { user, household } = await setup();
    await addTask(user, household.id, { title: 'Una', assignedTo: [user.id] });
    await addTask(user, household.id, { title: 'Dos', assignedTo: [user.id] });

    const res = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });
    const adhoc = res.body.data.weeklyBudget.allocations.filter(
      (a: { allocationKey: string }) => a.allocationKey === ADHOC_ASSIGNED_KEY,
    );
    expect(adhoc).toHaveLength(1);
    expect(adhoc[0].expectedFrequency).toBe(200);
  });
});

describe('manual edits', () => {
  it('refuses a plan that promises more than the ceiling', async () => {
    enableP1();
    const { user, household } = await setup();
    await addTask(user, household.id, {
      title: 'Fregar',
      assignedTo: [user.id],
      dueDate: MONDAY,
      isRecurring: true,
      recurrenceRule: { type: 'daily' },
    });

    const res = await patchBudget(user, household.id, {
      mode: 'manual',
      timeZone: ZONE,
      // 7 completions a week at 100 coins each is 700, far past the 200 cap.
      allocations: [{ allocationKey: expect.any(String) as unknown as string, coinAmount: 100 }],
    });
    // The key above is a placeholder; use the real one instead.
    expect([400, 200]).toContain(res.status);

    const automatic = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });
    const dailyKey = automatic.body.data.weeklyBudget.allocations.find(
      (a: { expectedFrequency: number }) => a.expectedFrequency === 700,
    ).allocationKey;

    const overshoot = await patchBudget(user, household.id, {
      mode: 'manual',
      timeZone: ZONE,
      allocations: [{ allocationKey: dailyKey, coinAmount: 100 }],
    });

    expect(overshoot.status).toBe(400);
    expect(overshoot.body.error).toMatch(/ceiling/i);
  });

  it('accepts an edit that stays within the ceiling and marks the line manual', async () => {
    enableP1();
    const { user, household } = await setup();
    await addTask(user, household.id, {
      title: 'Fregar',
      assignedTo: [user.id],
      dueDate: MONDAY,
      isRecurring: true,
      recurrenceRule: { type: 'weekly' },
    });

    const automatic = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });
    const key = automatic.body.data.weeklyBudget.allocations.find(
      (a: { allocationKey: string }) => a.allocationKey !== COMMON_TRANCHE_KEY,
    ).allocationKey;

    const edited = await patchBudget(user, household.id, {
      mode: 'manual',
      timeZone: ZONE,
      allocations: [{ allocationKey: key, coinAmount: 12 }],
    });

    expect(edited.status).toBe(200);
    const line = edited.body.data.weeklyBudget.allocations.find(
      (a: { allocationKey: string }) => a.allocationKey === key,
    );
    expect(line.coinAmount).toBe(12);
    expect(line.mode).toBe('manual');
    // Untouched lines stay automatic.
    const common = edited.body.data.weeklyBudget.allocations.find(
      (a: { allocationKey: string }) => a.allocationKey === COMMON_TRANCHE_KEY,
    );
    expect(common.mode).toBe('automatic');
  });

  it('restores the deterministic plan on "volver a automático"', async () => {
    enableP1();
    const { user, household } = await setup();
    await addTask(user, household.id, {
      title: 'Fregar',
      assignedTo: [user.id],
      dueDate: MONDAY,
      isRecurring: true,
      recurrenceRule: { type: 'weekly' },
    });

    const original = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });
    const key = original.body.data.weeklyBudget.allocations.find(
      (a: { allocationKey: string }) => a.allocationKey !== COMMON_TRANCHE_KEY,
    ).allocationKey;

    await patchBudget(user, household.id, {
      mode: 'manual',
      timeZone: ZONE,
      allocations: [{ allocationKey: key, coinAmount: 3 }],
    });

    const restored = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });

    // Recomputed, not restored from a stored copy — which is why no second
    // copy of the plan needs to exist anywhere.
    expect(restored.body.data.weeklyBudget.allocations).toEqual(
      original.body.data.weeklyBudget.allocations,
    );
    expect(
      restored.body.data.weeklyBudget.allocations.every(
        (a: { mode: string }) => a.mode === 'automatic',
      ),
    ).toBe(true);
  });

  it('refuses an unknown allocationKey rather than ignoring it', () => {
    // A silent no-op would let a client believe it had saved a change.
    expect(() =>
      applyManualOverrides(
        [
          {
            allocationKey: COMMON_TRANCHE_KEY,
            expectedFrequency: 100,
            coinAmount: 40,
            mode: 'automatic',
          },
        ],
        [{ allocationKey: 'rule:does-not-exist', coinAmount: 5 }],
      ),
    ).toThrow(/Unknown allocation/);
  });

  it('bumps planVersion on every edit', async () => {
    enableP1();
    const { user, household } = await setup();

    const first = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });
    const second = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });
    const third = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });

    expect(second.body.data.weeklyBudget.planVersion).toBeGreaterThan(
      first.body.data.weeklyBudget.planVersion,
    );
    expect(third.body.data.weeklyBudget.planVersion).toBeGreaterThan(
      second.body.data.weeklyBudget.planVersion,
    );
  });

  it('touches only the week it names', async () => {
    enableP1();
    const { user, household } = await setup();

    const thisWeek = weekKey(new Date(MONDAY), ZONE);
    await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE, weekKey: thisWeek });
    await patchBudget(user, household.id, {
      mode: 'automatic',
      timeZone: ZONE,
      weekKey: '2026-W40',
    });

    const budgets = await WeeklyPersonalBudgetModel.find({ userId: user.id }).lean();
    const keys = budgets.map((b) => b.weekKey).sort();
    expect(keys).toEqual([thisWeek, '2026-W40'].sort());
    // Two documents, so an edit to one cannot reach the other — the unique
    // index on (userId, householdId, weekKey) is what guarantees it.
    expect(budgets).toHaveLength(2);
  });

  it('touches only the caller\'s own plan', async () => {
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });

    const mineOnly = await WeeklyPersonalBudgetModel.find({}).lean();
    expect(mineOnly).toHaveLength(1);
    expect(mineOnly[0].userId.toString()).toBe(user.id);
  });
});

describe('spending against the plan', () => {
  it('pays an assigned recurring task its planned amount', async () => {
    enableP1();
    const { user, household } = await setup();
    const taskId = await addTask(user, household.id, {
      title: 'Fregar',
      assignedTo: [user.id],
      dueDate: MONDAY,
      isRecurring: true,
      recurrenceRule: { type: 'weekly' },
    });

    const res = await completeTask(user, household.id, taskId, 'op-planned');

    const budget = await WeeklyPersonalBudgetModel.findOne({ userId: user.id });
    const line = budget!.allocations.find((a) => a.allocationKey !== COMMON_TRANCHE_KEY)!;
    // The whole named budget goes to this single line, so it is worth 160 —
    // far more than Monday has released, and far more than the flat fallback.
    expect(line.coinAmount).toBe(NAMED_BUDGET);
    // What is actually paid is the smaller of the two: the plan says what the
    // task is worth, the daily release says what can be paid today.
    expect(res.body.data.reward.coins).toBe(MONDAY_RELEASE);
    // And it is emphatically not the flat default, which is what would come
    // out if the plan had been ignored.
    expect(res.body.data.reward.coins).toBeGreaterThan(DEFAULT_TASK_COINS);
  });

  it('pays an unassigned task from the common tranche', async () => {
    enableP1();
    const { user, household } = await setup();
    const taskId = await addTask(user, household.id, { title: 'Sin asignar' });

    const res = await completeTask(user, household.id, taskId, 'op-common');

    const budget = await WeeklyPersonalBudgetModel.findOne({ userId: user.id });
    const common = budget!.allocations.find((a) => a.allocationKey === COMMON_TRANCHE_KEY)!;
    expect(common.coinAmount).toBe(COMMON_BUDGET);
    // Capped by Monday's release, as every payout is.
    expect(res.body.data.reward.coins).toBe(Math.min(COMMON_BUDGET, MONDAY_RELEASE));
  });

  it('pays a member who completes someone else\'s task from the common tranche', async () => {
    // Helping out is still work. The completer is not an assignee, so their
    // own named lines do not apply, but they are not left unpaid either.
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    const taskId = await addTask(user, household.id, {
      title: 'Asignada al dueño',
      assignedTo: [user.id],
    });

    const res = await completeTask(mate, household.id, taskId, 'op-helper');

    const budget = await WeeklyPersonalBudgetModel.findOne({ userId: mate.id });
    const common = budget!.allocations.find((a) => a.allocationKey === COMMON_TRANCHE_KEY)!;
    expect(common.coinAmount).toBe(COMMON_BUDGET);
    expect(res.body.data.reward.coins).toBe(Math.min(common.coinAmount, MONDAY_RELEASE));
  });

  it('pays each of two assignees from their OWN plan, splitting nothing', async () => {
    // Approved decision 3: the reward belongs to whoever COMPLETES the task,
    // not to its assignees. So a task assigned to two people appears in both
    // their plans, and the completer is paid in full from their own line.
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    const first = await addTask(user, household.id, {
      title: 'Compartida A',
      assignedTo: [user.id, mate.id],
    });
    const second = await addTask(user, household.id, {
      title: 'Compartida B',
      assignedTo: [user.id, mate.id],
    });

    const byOwner = await completeTask(user, household.id, first, 'op-shared-1');
    const byMate = await completeTask(mate, household.id, second, 'op-shared-2');

    // Neither payout is halved.
    expect(byOwner.body.data.reward.coins).toBeGreaterThan(0);
    expect(byMate.body.data.reward.coins).toBeGreaterThan(0);
    expect(byOwner.body.data.reward.coins).toBe(byMate.body.data.reward.coins);

    const ownerBudget = await WeeklyPersonalBudgetModel.findOne({ userId: user.id });
    const mateBudget = await WeeklyPersonalBudgetModel.findOne({ userId: mate.id });
    // The task is in BOTH plans, as an ad-hoc assigned line.
    expect(
      ownerBudget!.allocations.some((a) => a.allocationKey === ADHOC_ASSIGNED_KEY),
    ).toBe(true);
    expect(mateBudget!.allocations.some((a) => a.allocationKey === ADHOC_ASSIGNED_KEY)).toBe(true);
  });

  it('honours a manual edit on the next completion', async () => {
    enableP1();
    const { user, household } = await setup();
    const taskId = await addTask(user, household.id, {
      title: 'Fregar',
      assignedTo: [user.id],
      dueDate: MONDAY,
      isRecurring: true,
      recurrenceRule: { type: 'weekly' },
    });

    const automatic = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });
    const key = automatic.body.data.weeklyBudget.allocations.find(
      (a: { allocationKey: string }) => a.allocationKey !== COMMON_TRANCHE_KEY,
    ).allocationKey;
    await patchBudget(user, household.id, {
      mode: 'manual',
      timeZone: ZONE,
      allocations: [{ allocationKey: key, coinAmount: 7 }],
    });

    const res = await completeTask(user, household.id, taskId, 'op-manual-applied');
    expect(res.body.data.reward.coins).toBe(7);
  });

  it('still caps the payout at what the day has released', async () => {
    // The plan says what a task is worth; the daily release says what can be
    // paid today. The smaller of the two wins, or the x/6 schedule would be
    // decorative.
    enableP1();
    const { user, household } = await setup();
    const taskId = await addTask(user, household.id, { title: 'Sin asignar' });

    // Monday releases 33 of 200; the common tranche is worth 40.
    const res = await completeTask(user, household.id, taskId, 'op-capped');
    expect(res.body.data.reward.coins).toBeLessThan(COMMON_BUDGET);
    expect(res.body.data.reward.coins).toBe(33);
  });

  it('falls back to the flat default when no plan covers the task', () => {
    // A member's very first completion, before any plan exists: "we have not
    // planned yet" must not read as "this was worthless".
    expect(
      resolveAllocationForTask([], {
        _id: new Types.ObjectId(),
        parentTaskId: null,
        assignedTo: [],
        isRecurring: false,
      } as never, 'u1'),
    ).toBeNull();
  });
});

describe('flag OFF and authorization', () => {
  it('refuses the PATCH with 409 while P1 is disabled', async () => {
    // Refused rather than silently stored: writing a plan a disabled economy
    // will never read would let a client believe it configured something.
    const { user, household } = await setup();

    const res = await patchBudget(user, household.id, { mode: 'automatic', timeZone: ZONE });

    expect(res.status).toBe(409);
    await expect(WeeklyPersonalBudgetModel.countDocuments({})).resolves.toBe(0);
  });

  it('answers 403 to a non-member', async () => {
    enableP1();
    const { household } = await setup();
    const stranger = await createTestUser(app);

    const res = await patchBudget(stranger, household.id, { mode: 'automatic', timeZone: ZONE });
    expect(res.status).toBe(403);
  });

  it('rejects a malformed body', async () => {
    enableP1();
    const { user, household } = await setup();

    await expect(
      patchBudget(user, household.id, { mode: 'sometimes' }).then((r) => r.status),
    ).resolves.toBe(400);
    await expect(
      patchBudget(user, household.id, { mode: 'automatic', weekKey: 'la semana que viene' }).then(
        (r) => r.status,
      ),
    ).resolves.toBe(400);
    await expect(
      patchBudget(user, household.id, {
        mode: 'manual',
        allocations: [{ allocationKey: COMMON_TRANCHE_KEY, coinAmount: -1 }],
      }).then((r) => r.status),
    ).resolves.toBe(400);
  });
});

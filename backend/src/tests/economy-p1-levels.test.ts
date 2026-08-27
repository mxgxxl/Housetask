import { Server } from 'http';
import { Types } from 'mongoose';
import request from 'supertest';

import * as socketModule from '../config/socket';
import { HouseholdProgressModel } from '../models/HouseholdProgress';
import { PersonalXpLedgerModel } from '../models/PersonalXpLedger';
import { UserProgressModel } from '../models/UserProgress';
import { InMemoryIdempotencyStore } from '../services/idempotency.store';
import { resetP1EnabledResolver, setP1EnabledResolver } from '../services/feature-flag.service';
import {
  HOUSEHOLD_LEVEL_CURVE_FACTOR,
  HOUSEHOLD_LEVEL_UNLOCKS,
  HOUSEHOLD_TASK_MILESTONES,
  PERSONAL_LEVEL_CURVE_FACTOR,
  PERSONAL_LEVEL_UNLOCKS,
  PERSONAL_TASK_MILESTONES,
  TASK_HOUSEHOLD_XP,
  TASK_PERSONAL_XP,
  levelForXp,
  milestoneCrossed,
  unlocksForLevel,
  unlocksUpToLevel,
  xpRequiredForLevel,
} from '../config/economy-p1';
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
 * Levels, milestones and unlocks (TD-066 B7).
 *
 * The mechanic is announced exactly once per threshold, and nothing records
 * "already announced" anywhere. That works because both tracks are monotonic
 * counters the reward transaction advances a single time per task — the
 * `RewardGrant` unique index is what guarantees the "single" — so "was below,
 * is now at or above" is true for one completion and no other.
 *
 * These tests exist to prove that claim rather than restate it: the level
 * boundary is crossed with the XP one point either side of it, and the
 * "granted once" case is exercised by actually retrying.
 */
let app: Server;

let emitToUser: jest.SpyInstance;
let emitToHousehold: jest.SpyInstance;

const MONDAY = '2026-08-24T10:00:00.000Z';
const ZONE = 'UTC';

beforeAll(async () => {
  app = await buildTestApp({ idempotencyStore: new InMemoryIdempotencyStore() });
});

beforeEach(() => {
  emitToUser = jest.spyOn(socketModule, 'emitToUser').mockImplementation(() => undefined);
  emitToHousehold = jest
    .spyOn(socketModule, 'emitToHousehold')
    .mockImplementation(() => undefined);
});

afterEach(() => {
  jest.restoreAllMocks();
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

async function addTask(user: TestUser, householdId: string, title: string): Promise<string> {
  const res = await request(app)
    .post(`/api/households/${householdId}/tasks`)
    .set(authHeader(user.accessToken))
    .send({ title });
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

/** Complete `count` fresh tasks, one per call, with distinct operation ids. */
async function completeMany(
  user: TestUser,
  householdId: string,
  count: number,
  prefix: string,
): Promise<void> {
  for (let i = 0; i < count; i++) {
    const taskId = await addTask(user, householdId, `${prefix}-${i}`);
    await completeTask(user, householdId, taskId, `${prefix}-op-${i}`);
  }
}

function payloadsFor(spy: jest.SpyInstance, event: string): unknown[] {
  return spy.mock.calls.filter((call) => call[1] === event).map((call) => call[2]);
}

describe('pure level arithmetic at the boundary', () => {
  it('does not promote one XP below the threshold, and does at it', () => {
    // Level 2 costs exactly 100 on the personal curve. Landing precisely on a
    // threshold is the common case, not the rare one — every grant is a round
    // number — so it is the case the inversion has to get right.
    const threshold = xpRequiredForLevel(2, PERSONAL_LEVEL_CURVE_FACTOR);
    expect(threshold).toBe(100);
    expect(levelForXp(threshold - 1, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(1);
    expect(levelForXp(threshold, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(2);
    expect(levelForXp(threshold + 1, PERSONAL_LEVEL_CURVE_FACTOR)).toBe(2);
  });

  it('holds at every household threshold too', () => {
    for (let level = 2; level <= 10; level++) {
      const threshold = xpRequiredForLevel(level, HOUSEHOLD_LEVEL_CURVE_FACTOR);
      expect(levelForXp(threshold - 1, HOUSEHOLD_LEVEL_CURVE_FACTOR)).toBe(level - 1);
      expect(levelForXp(threshold, HOUSEHOLD_LEVEL_CURVE_FACTOR)).toBe(level);
    }
  });

  it('reports a milestone only on the completion that crosses it', () => {
    expect(milestoneCrossed(8, 9, PERSONAL_TASK_MILESTONES)).toBeNull();
    expect(milestoneCrossed(9, 10, PERSONAL_TASK_MILESTONES)).toBe(10);
    // Already past it: the next completion must not re-announce.
    expect(milestoneCrossed(10, 11, PERSONAL_TASK_MILESTONES)).toBeNull();
    expect(milestoneCrossed(49, 50, PERSONAL_TASK_MILESTONES)).toBe(50);
  });

  it('accumulates unlocks up to a level, and grants none at a level with no entry', () => {
    expect(unlocksForLevel(1, PERSONAL_LEVEL_UNLOCKS)).toEqual([]);
    expect(unlocksForLevel(4, PERSONAL_LEVEL_UNLOCKS)).toEqual([]);
    expect(unlocksForLevel(2, PERSONAL_LEVEL_UNLOCKS)).toEqual(['title:aprendiz']);

    expect(unlocksUpToLevel(1, PERSONAL_LEVEL_UNLOCKS)).toEqual([]);
    expect(unlocksUpToLevel(3, PERSONAL_LEVEL_UNLOCKS)).toEqual([
      'title:aprendiz',
      'badge:constante',
    ]);
    // Level 4 grants nothing new, so the set is unchanged from level 3.
    expect(unlocksUpToLevel(4, PERSONAL_LEVEL_UNLOCKS)).toEqual(
      unlocksUpToLevel(3, PERSONAL_LEVEL_UNLOCKS),
    );
  });

  it('reuses the Fase A cosmetics for household unlocks (PDR-015)', () => {
    // The art track has produced nothing new, so a household unlock can only
    // point at something that already exists in the shop.
    expect(unlocksUpToLevel(5, HOUSEHOLD_LEVEL_UNLOCKS)).toEqual([
      'cosmetic:hat',
      'cosmetic:scarf',
      'cosmetic:glasses',
    ]);
  });
});

describe('level-up over the wire', () => {
  it('emits economy:level_up to the member alone when they reach level 2', async () => {
    enableP1();
    const { user, household } = await setup();

    // Level 2 costs 100 XP at 10 XP per completion: the tenth is the one.
    await completeMany(user, household.id, 9, 'pre');
    expect(payloadsFor(emitToUser, 'economy:level_up')).toEqual([]);

    const taskId = await addTask(user, household.id, 'La décima');
    await completeTask(user, household.id, taskId, 'op-levelup');

    const levelUps = emitToUser.mock.calls.filter((c) => c[1] === 'economy:level_up');
    expect(levelUps).toHaveLength(1);
    expect(levelUps[0][0]).toBe(user.id);
    expect(levelUps[0][2]).toEqual({
      track: 'personal',
      level: 2,
      previousLevel: 1,
      xp: TASK_PERSONAL_XP * 10,
      unlocks: ['title:aprendiz'],
    });

    // A personal level is the member's own (PDR-017: titles and badges), so
    // it must never be broadcast to the household room.
    expect(payloadsFor(emitToHousehold, 'economy:level_up')).toEqual([]);

    const stored = await UserProgressModel.findOne({ userId: user.id });
    expect(stored?.level).toBe(2);
    expect(stored?.tasksCompleted).toBe(10);
  });

  it('emits household:level_up to the household when it reaches level 2', async () => {
    enableP1();
    const { user, household } = await setup();

    // Household level 2 costs 200 XP at 10 per completion: the twentieth.
    await completeMany(user, household.id, 19, 'hh-pre');
    expect(payloadsFor(emitToHousehold, 'household:level_up')).toEqual([]);

    const taskId = await addTask(user, household.id, 'La vigésima');
    await completeTask(user, household.id, taskId, 'op-hh-levelup');

    const levelUps = emitToHousehold.mock.calls.filter((c) => c[1] === 'household:level_up');
    expect(levelUps).toHaveLength(1);
    expect(levelUps[0][0]).toBe(household.id);
    expect(levelUps[0][2]).toEqual({
      track: 'household',
      level: 2,
      previousLevel: 1,
      xp: TASK_HOUSEHOLD_XP * 20,
      unlocks: ['cosmetic:hat'],
    });

    // Shared by definition — never routed to one member's devices.
    expect(payloadsFor(emitToUser, 'household:level_up')).toEqual([]);
  });

  it('emits nothing on a completion that does not cross a level', async () => {
    enableP1();
    const { user, household } = await setup();
    const taskId = await addTask(user, household.id, 'Una sola');

    await completeTask(user, household.id, taskId, 'op-no-levelup');

    expect(payloadsFor(emitToUser, 'economy:level_up')).toEqual([]);
    expect(payloadsFor(emitToHousehold, 'household:level_up')).toEqual([]);
  });
});

describe('a level is granted once and only once', () => {
  it('does not re-emit when the same completion is retried', async () => {
    enableP1();
    const { user, household } = await setup();
    await completeMany(user, household.id, 9, 'retry-pre');

    const taskId = await addTask(user, household.id, 'La que sube de nivel');
    await completeTask(user, household.id, taskId, 'op-retry');
    expect(payloadsFor(emitToUser, 'economy:level_up')).toHaveLength(1);

    emitToUser.mockClear();

    // Same key: the idempotency middleware replays the stored response and
    // the handler never runs again.
    await completeTask(user, household.id, taskId, 'op-retry');
    // Different key, same task: reaches the service, but the RewardGrant
    // claim is taken, so nothing is incremented and nothing is announced.
    await completeTask(user, household.id, taskId, 'op-retry-other-key');

    expect(payloadsFor(emitToUser, 'economy:level_up')).toEqual([]);

    const stored = await UserProgressModel.findOne({ userId: user.id });
    expect(stored?.level).toBe(2);
    expect(stored?.tasksCompleted).toBe(10);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: user.id })).resolves.toBe(10);
  });

  it('does not re-emit a level already held when later completions arrive', async () => {
    enableP1();
    const { user, household } = await setup();
    await completeMany(user, household.id, 10, 'held');
    expect(payloadsFor(emitToUser, 'economy:level_up')).toHaveLength(1);

    emitToUser.mockClear();
    await completeMany(user, household.id, 3, 'held-more');

    // Still level 2, and level 3 is 300 XP away — nothing to announce.
    expect(payloadsFor(emitToUser, 'economy:level_up')).toEqual([]);
    const stored = await UserProgressModel.findOne({ userId: user.id });
    expect(stored?.level).toBe(2);
  });
});

describe('task-count milestones', () => {
  it('announces the personal milestone on the completion that reaches it', async () => {
    enableP1();
    const { user, household } = await setup();

    await completeMany(user, household.id, 9, 'ms-pre');
    expect(payloadsFor(emitToUser, 'economy:milestone')).toEqual([]);

    const taskId = await addTask(user, household.id, 'La décima');
    await completeTask(user, household.id, taskId, 'op-milestone');

    const milestones = emitToUser.mock.calls.filter((c) => c[1] === 'economy:milestone');
    expect(milestones).toHaveLength(1);
    expect(milestones[0][0]).toBe(user.id);
    expect(milestones[0][2]).toEqual({
      kind: 'tasks_completed',
      value: PERSONAL_TASK_MILESTONES[0],
      total: 10,
    });
  });

  it('does not repeat a milestone once passed', async () => {
    enableP1();
    const { user, household } = await setup();
    await completeMany(user, household.id, 10, 'ms-once');
    expect(payloadsFor(emitToUser, 'economy:milestone')).toHaveLength(1);

    emitToUser.mockClear();
    await completeMany(user, household.id, 5, 'ms-after');

    expect(payloadsFor(emitToUser, 'economy:milestone')).toEqual([]);
  });

  it('announces the household milestone to the household', async () => {
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    // Pooled across members: 13 from one and 12 from the other reaches 25.
    await completeMany(user, household.id, 13, 'hh-ms-a');
    await completeMany(mate, household.id, 11, 'hh-ms-b');
    expect(payloadsFor(emitToHousehold, 'household:milestone')).toEqual([]);

    const taskId = await addTask(mate, household.id, 'La vigésimo quinta');
    await completeTask(mate, household.id, taskId, 'op-hh-milestone');

    const milestones = emitToHousehold.mock.calls.filter(
      (c) => c[1] === 'household:milestone',
    );
    expect(milestones).toHaveLength(1);
    expect(milestones[0][0]).toBe(household.id);
    expect(milestones[0][2]).toEqual({
      kind: 'tasks_completed',
      value: HOUSEHOLD_TASK_MILESTONES[0],
      total: 25,
    });

    const stored = await HouseholdProgressModel.findOne({ householdId: household.id });
    expect(stored?.tasksCompleted).toBe(25);
  });
});

describe('PDR-017 portability', () => {
  it('keeps a member\'s personal XP when they leave the household', async () => {
    // "Tu nivel viaja contigo": leaving a home must not cost a level, which
    // is why PersonalXpLedger carries no householdId at all.
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    await completeMany(mate, household.id, 10, 'leave');
    const before = await UserProgressModel.findOne({ userId: mate.id });
    expect(before?.xp).toBe(TASK_PERSONAL_XP * 10);
    expect(before?.level).toBe(2);

    const removed = await request(app)
      .delete(`/api/households/${household.id}/members/${mate.id}`)
      .set(authHeader(user.accessToken));
    expect(removed.status).toBe(200);

    const after = await UserProgressModel.findOne({ userId: mate.id });
    expect(after?.xp).toBe(TASK_PERSONAL_XP * 10);
    expect(after?.level).toBe(2);
    await expect(PersonalXpLedgerModel.countDocuments({ userId: mate.id })).resolves.toBe(10);
  });

  it('carries personal XP into a different household, and household XP not at all', async () => {
    enableP1();
    const { user, household } = await setup();
    const other = await createTestHousehold(app, user, 'Segunda casa');

    await completeMany(user, household.id, 10, 'first-home');

    // The personal track is one number wherever it is read from.
    const fromFirst = await request(app)
      .get(`/api/households/${household.id}/economy/p1/me?timeZone=UTC`)
      .set(authHeader(user.accessToken));
    const fromSecond = await request(app)
      .get(`/api/households/${other.id}/economy/p1/me?timeZone=UTC`)
      .set(authHeader(user.accessToken));

    expect(fromFirst.body.data.personalProgress.xp).toBe(TASK_PERSONAL_XP * 10);
    expect(fromSecond.body.data.personalProgress.xp).toBe(TASK_PERSONAL_XP * 10);
    expect(fromSecond.body.data.personalProgress.level).toBe(2);

    // The household track stayed where it was earned. The second home has
    // none of it, which is the whole point of the two tracks being separate.
    const firstHousehold = await request(app)
      .get(`/api/households/${household.id}/economy/p1/household`)
      .set(authHeader(user.accessToken));
    const secondHousehold = await request(app)
      .get(`/api/households/${other.id}/economy/p1/household`)
      .set(authHeader(user.accessToken));

    expect(firstHousehold.body.data.householdProgress.xp).toBe(TASK_HOUSEHOLD_XP * 10);
    expect(secondHousehold.body.data.householdProgress.xp).toBe(0);
    expect(secondHousehold.body.data.householdProgress.level).toBe(1);
  });

  it('leaves household XP with the household after the earner departs', async () => {
    enableP1();
    const { user, household } = await setup();
    const mate = await createTestUser(app);
    await joinTestHousehold(app, mate, household.inviteCode);

    await completeMany(mate, household.id, 5, 'stays');
    await request(app)
      .delete(`/api/households/${household.id}/members/${mate.id}`)
      .set(authHeader(user.accessToken));

    const stored = await HouseholdProgressModel.findOne({ householdId: household.id });
    expect(stored?.xp).toBe(TASK_HOUSEHOLD_XP * 5);
  });
});

describe('unlocks are readable, not only announced', () => {
  it('reports every unlock earned so far on the personal read', async () => {
    // An unlock that lives only in a socket event is forgotten on the next
    // app launch, which would make a granted title look like it never was.
    enableP1();
    const { user, household } = await setup();
    await completeMany(user, household.id, 10, 'unlock-read');

    const res = await request(app)
      .get(`/api/households/${household.id}/economy/p1/me?timeZone=UTC`)
      .set(authHeader(user.accessToken));

    expect(res.body.data.personalProgress.level).toBe(2);
    expect(res.body.data.personalProgress.unlocks).toEqual(['title:aprendiz']);
  });

  it('reports household unlocks on the household read', async () => {
    enableP1();
    const { user, household } = await setup();
    await completeMany(user, household.id, 20, 'hh-unlock-read');

    const res = await request(app)
      .get(`/api/households/${household.id}/economy/p1/household`)
      .set(authHeader(user.accessToken));

    expect(res.body.data.householdProgress.level).toBe(2);
    expect(res.body.data.householdProgress.unlocks).toEqual(['cosmetic:hat']);
  });

  it('is empty at level 1', async () => {
    enableP1();
    const { user, household } = await setup();

    const res = await request(app)
      .get(`/api/households/${household.id}/economy/p1/me?timeZone=UTC`)
      .set(authHeader(user.accessToken));

    expect(res.body.data.personalProgress.unlocks).toEqual([]);
  });
});

describe('flag OFF — no level or milestone machinery runs', () => {
  it('emits no level or milestone event however many tasks are completed', async () => {
    // No enableP1(): the shipped state of every household.
    const { user, household } = await setup();

    for (let i = 0; i < 12; i++) {
      const taskId = await addTask(user, household.id, `Fase A ${i}`);
      await completeTask(user, household.id, taskId, `op-off-${i}`);
    }

    expect(payloadsFor(emitToUser, 'economy:level_up')).toEqual([]);
    expect(payloadsFor(emitToUser, 'economy:milestone')).toEqual([]);
    expect(payloadsFor(emitToHousehold, 'household:level_up')).toEqual([]);
    expect(payloadsFor(emitToHousehold, 'household:milestone')).toEqual([]);

    // And no projection was created to hold a level in the first place.
    await expect(UserProgressModel.countDocuments({})).resolves.toBe(0);
    await expect(HouseholdProgressModel.countDocuments({})).resolves.toBe(0);
  });

  it('reports level 1 with no unlocks on the read', async () => {
    const { user, household } = await setup();
    const taskId = await addTask(user, household.id, 'Una');
    await completeTask(user, household.id, taskId, 'op-off-read');

    const res = await request(app)
      .get(`/api/households/${household.id}/economy/p1/me?timeZone=UTC`)
      .set(authHeader(user.accessToken));

    expect(res.body.data.enabled).toBe(false);
    expect(res.body.data.personalProgress.level).toBe(1);
    expect(res.body.data.personalProgress.unlocks).toEqual([]);
  });
});

describe('projections stay reconstructible from their ledgers', () => {
  it('keeps tasksCompleted equal to the number of receipts', async () => {
    enableP1();
    const { user, household } = await setup();
    await completeMany(user, household.id, 7, 'recon');

    const progress = await UserProgressModel.findOne({ userId: user.id });
    const ledgerCount = await PersonalXpLedgerModel.countDocuments({
      userId: new Types.ObjectId(user.id),
    });

    expect(progress?.tasksCompleted).toBe(ledgerCount);
    expect(progress?.xp).toBe(ledgerCount * TASK_PERSONAL_XP);
    expect(progress?.level).toBe(levelForXp(progress!.xp, PERSONAL_LEVEL_CURVE_FACTOR));
  });
});

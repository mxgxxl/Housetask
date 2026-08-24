import { Types } from 'mongoose';

import { HouseholdModel } from '../models/Household';
import { HouseholdMemberModel } from '../models/HouseholdMember';
import {
  backfillHouseholdMembers,
  formatSummary,
} from '../scripts/backfill-household-members';

/**
 * TD-001 phase 1. The backfill only ever runs against real data, once, so its
 * guarantees have to be pinned here: idempotent, non-destructive, and honest
 * about divergences instead of papering over them.
 *
 * Still tested after commit 7 removed `members` from the Household schema,
 * because the script is still the disaster-recovery path: until
 * `unset-household-members.ts` has been applied, it is the only thing that can
 * rebuild memberships from the embedded array. Both it and this fixture now go
 * through the RAW collection, since a typed write can no longer produce the
 * legacy shape they operate on.
 */
const joinedAt = new Date('2026-03-01T09:00:00.000Z');

async function seedHousehold(members: Array<{ user: Types.ObjectId; role: 'admin' | 'member' }>) {
  const _id = new Types.ObjectId();
  await HouseholdModel.collection.insertOne({
    _id,
    name: 'Casa',
    inviteCode: Math.random().toString(36).slice(2, 10).toUpperCase(),
    createdBy: members[0].user,
    members: members.map((m) => ({ ...m, joinedAt })),
    createdAt: new Date(),
    updatedAt: new Date(),
  });
  return { _id };
}

describe('backfillHouseholdMembers', () => {
  it('should report what it would do without writing anything on a dry run',
    async () => {
      const user = new Types.ObjectId();
      await seedHousehold([{ user, role: 'admin' }]);

      const summary = await backfillHouseholdMembers(false);

      expect(summary.created).toBe(1);
      expect(await HouseholdMemberModel.countDocuments({})).toBe(0);
    });

  it('should create one row per embedded member, preserving role and joinedAt',
    async () => {
      const admin = new Types.ObjectId();
      const member = new Types.ObjectId();
      const household = await seedHousehold([
        { user: admin, role: 'admin' },
        { user: member, role: 'member' },
      ]);

      const summary = await backfillHouseholdMembers(true);

      expect(summary.created).toBe(2);
      const rows = await HouseholdMemberModel.find({ householdId: household._id }).lean();
      expect(rows).toHaveLength(2);

      const adminRow = rows.find((r) => r.userId.toString() === admin.toString());
      expect(adminRow!.role).toBe('admin');
      // The date the user actually joined, not the date of the migration.
      expect(adminRow!.joinedAt.toISOString()).toBe(joinedAt.toISOString());
    });

  it('should be idempotent: a second run creates nothing', async () => {
    await seedHousehold([{ user: new Types.ObjectId(), role: 'admin' }]);

    await backfillHouseholdMembers(true);
    const second = await backfillHouseholdMembers(true);

    expect(second.created).toBe(0);
    expect(second.alreadyPresent).toBe(1);
    expect(await HouseholdMemberModel.countDocuments({})).toBe(1);
  });

  it('should never delete a row that has no embedded counterpart', async () => {
    // Non-destructive by construction: the backfill only inserts. A row the
    // embedded array no longer knows about is left alone, because at this
    // phase the array is the authority and losing data would be worse than
    // carrying an extra row.
    const orphan = await HouseholdMemberModel.create({
      householdId: new Types.ObjectId(),
      userId: new Types.ObjectId(),
    });

    await backfillHouseholdMembers(true);

    expect(await HouseholdMemberModel.findById(orphan._id)).not.toBeNull();
  });

  it('should report a divergent role without overwriting it', async () => {
    // A divergence means the dual write has a hole. Silently fixing it would
    // erase the only evidence that something is wrong.
    const user = new Types.ObjectId();
    const household = await seedHousehold([{ user, role: 'admin' }]);
    await HouseholdMemberModel.create({
      householdId: household._id,
      userId: user,
      role: 'member',
    });

    const summary = await backfillHouseholdMembers(true);

    expect(summary.created).toBe(0);
    expect(summary.divergent).toHaveLength(1);
    expect(summary.divergent[0]).toMatchObject({ embedded: 'admin', collection: 'member' });

    const row = await HouseholdMemberModel.findOne({ householdId: household._id, userId: user });
    expect(row!.role).toBe('member');
  });

  it('should format a summary that can be pasted into the TD entry', async () => {
    await seedHousehold([{ user: new Types.ObjectId(), role: 'admin' }]);
    const summary = await backfillHouseholdMembers(true);

    const text = formatSummary(summary, true);

    expect(text).toContain('TD-001 backfill — APPLIED');
    expect(text).toContain('households scanned:   1');
    expect(text).toContain('rows created: 1');
  });

  afterEach(async () => {
    await HouseholdModel.deleteMany({});
    await HouseholdMemberModel.deleteMany({});
  });
});

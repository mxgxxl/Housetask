import mongoose, { Types } from 'mongoose';

import { HouseholdMemberModel } from '../models/HouseholdMember';

/**
 * Schema and index guarantees of the HouseholdMember collection (TD-001).
 *
 * Nothing reads this collection yet — the migration keeps the embedded array
 * as the authority until the cutover — so these tests fix the properties the
 * later phases will lean on, before anything depends on them.
 */
describe('HouseholdMember model', () => {
  const householdId = new Types.ObjectId();
  const userId = new Types.ObjectId();

  it('should default role to member and joinedAt to now', async () => {
    const before = Date.now();

    const member = await HouseholdMemberModel.create({ householdId, userId });

    expect(member.role).toBe('member');
    expect(member.joinedAt.getTime()).toBeGreaterThanOrEqual(before);
  });

  it('should accept an explicit joinedAt so a backfill can keep the real date',
    async () => {
      // The backfill copies joinedAt from the embedded array; if the schema
      // forced it to "now", every migrated membership would claim to have
      // started on migration day.
      const joinedAt = new Date('2026-01-15T10:00:00.000Z');

      const member = await HouseholdMemberModel.create({
        householdId,
        userId,
        joinedAt,
      });

      expect(member.joinedAt.toISOString()).toBe(joinedAt.toISOString());
    });

  it('should reject a role outside admin/member', async () => {
    await expect(
      HouseholdMemberModel.create({
        householdId,
        userId,
        role: 'owner' as unknown as 'admin',
      }),
    ).rejects.toThrow();
  });

  it('should reject a second membership for the same user in the same household',
    async () => {
      // This is what makes joinByInviteCode idempotent by construction rather
      // than by its in-application `alreadyMember` check: a concurrent double
      // join becomes a duplicate-key error instead of a race.
      await HouseholdMemberModel.create({ householdId, userId });
      await HouseholdMemberModel.syncIndexes();

      await expect(
        HouseholdMemberModel.create({ householdId, userId }),
      ).rejects.toThrow(/duplicate key/i);
    });

  it('should allow the same user in a different household', async () => {
    await HouseholdMemberModel.create({ householdId, userId });
    await HouseholdMemberModel.syncIndexes();

    const other = await HouseholdMemberModel.create({
      householdId: new Types.ObjectId(),
      userId,
    });

    expect(other.userId.toString()).toBe(userId.toString());
  });

  it('should declare the indexes the migration depends on', async () => {
    await HouseholdMemberModel.syncIndexes();

    const indexes = await HouseholdMemberModel.collection.indexes();
    const keys = indexes.map((i) => JSON.stringify(i.key));

    // requireMembership runs on every household-scoped request.
    expect(keys).toContain(JSON.stringify({ householdId: 1, userId: 1 }));
    // Replaces the denormalized User.households, socket handshake included.
    expect(keys).toContain(JSON.stringify({ userId: 1 }));
    // Counting admins for Hard Rule 9.
    expect(keys).toContain(JSON.stringify({ householdId: 1, role: 1 }));

    const compound = indexes.find(
      (i) => JSON.stringify(i.key) === JSON.stringify({ householdId: 1, userId: 1 }),
    );
    expect(compound?.unique).toBe(true);
  });

  it('should serialize with a virtual id and without _id/__v', async () => {
    const member = await HouseholdMemberModel.create({ householdId, userId });

    const json = member.toJSON() as Record<string, unknown>;

    expect(json.id).toBe(member._id.toString());
    expect(json._id).toBeUndefined();
    expect(json.__v).toBeUndefined();
  });

  afterEach(async () => {
    await mongoose.connection.collection('householdmembers').deleteMany({});
  });
});

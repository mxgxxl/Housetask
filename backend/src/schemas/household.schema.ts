import { z } from 'zod';

// Mirrors household.service.ts's MAX_HOUSEHOLD_NAME_LENGTH.
const MAX_HOUSEHOLD_NAME_LENGTH = 100;

const name = z
  .string({ error: 'Household name is required' })
  .trim()
  .min(1, 'Household name is required')
  .max(
    MAX_HOUSEHOLD_NAME_LENGTH,
    `Household name must be at most ${MAX_HOUSEHOLD_NAME_LENGTH} characters`,
  );

/** POST /api/households body. */
export const createHouseholdSchema = z.object({ name });

/**
 * No "update household" endpoint exists yet — household.routes.ts has no
 * PATCH/PUT on /:householdId, only create/join/getById/listMembers/
 * removeMember. Defined per TD-028's schema list and ready for that route
 * when it lands, but NOT currently wired to anything.
 */
export const updateHouseholdSchema = createHouseholdSchema.partial();

/**
 * POST /api/households/join body. The Household model only supports
 * join-by-invite-code (household.service.ts's joinHousehold) — there is no
 * email-based "invite a member" endpoint: Household embeds members by
 * ObjectId only and the User model has no username field either. This
 * schema matches the actual endpoint rather than an email/username shape.
 */
export const joinHouseholdSchema = z.object({
  inviteCode: z
    .string({ error: 'Invite code is required' })
    .trim()
    .min(1, 'Invite code is required'),
});

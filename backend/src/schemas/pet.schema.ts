import { z } from 'zod';
import { COSMETICS } from '../config/economy';

// Mirrors pet.service.ts's MAX_PET_NAME_LENGTH.
const MAX_PET_NAME_LENGTH = 50;

/** POST /pet/adopt body. */
export const requestAdoptionSchema = z.object({
  species: z.enum(['cat', 'dog'], { error: 'species must be "cat" or "dog"' }),
  name: z
    .string({ error: 'Pet name is required' })
    .trim()
    .min(1, 'Pet name is required')
    .max(MAX_PET_NAME_LENGTH, `Pet name must be at most ${MAX_PET_NAME_LENGTH} characters`),
});

// COSMETICS is a plain Cosmetic[], not a readonly tuple, so the map's result
// is typed string[] — the cast satisfies z.enum's non-empty-tuple type. Safe
// at runtime: the catalog always has at least one entry.
const cosmeticIds = COSMETICS.map((c) => c.id) as [string, ...string[]];

/** POST /pet/cosmetics/buy and /pet/cosmetics/active bodies — same shape. */
export const cosmeticIdSchema = z.object({
  cosmeticId: z.enum(cosmeticIds, { error: 'Unknown cosmeticId' }),
});

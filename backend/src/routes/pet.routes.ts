import { Router } from 'express';
import * as petController from '../controllers/pet.controller';
import { authMiddleware } from '../middleware/auth.middleware';
import { requireMembership } from '../middleware/membership.middleware';
import { idempotency } from '../middleware/idempotency.middleware';
import { validate } from '../middleware/validate';
import { requestAdoptionSchema, cosmeticIdSchema } from '../schemas/pet.schema';
import { asyncHandler } from '../utils/asyncHandler';

// mergeParams lets us read :householdId from the parent mount path.
const router = Router({ mergeParams: true });

router.use(authMiddleware);
// Every route below is household-scoped; membership is verified once, here.
router.use(requireMembership);

router.get('/', asyncHandler(petController.get));
router.get('/adopt', asyncHandler(petController.getAdoptionRequest));

// Resource-creating (Hard Rule 13): adopt creates an AdoptionRequest, confirm
// creates the Pet — both get Idempotency-Key support like task/household
// creation. validate() runs before idempotency so a malformed body fails
// fast without burning the client's key (TD-028 convention).
router.post(
  '/adopt',
  validate(requestAdoptionSchema),
  idempotency,
  asyncHandler(petController.requestAdopt),
);
// Creates the Pet itself; no body to validate.
router.post('/adopt/confirm', idempotency, asyncHandler(petController.confirmAdopt));
// Deletes the pending request — no new resource, no idempotency needed
// (a repeat DELETE on an already-cancelled request is just a 404).
router.delete('/adopt', asyncHandler(petController.cancelAdopt));

// State mutation on an existing pet, not a new resource — same category as
// PATCH .../complete and .../purchase, which also have no idempotency
// middleware. The cooldown IS the anti-duplicate guard here.
router.post('/feed', asyncHandler(petController.feed));
router.post('/play', asyncHandler(petController.play));

// Creates an EconomyLedger entry (Hard Rule 13) in addition to mutating the
// pet, so it gets Idempotency-Key support like the resource-creating routes
// above.
router.post(
  '/cosmetics/buy',
  validate(cosmeticIdSchema),
  idempotency,
  asyncHandler(petController.buyCosmetic),
);
// Mutates existing state only (which cosmetic is active) — no new resource.
router.post(
  '/cosmetics/active',
  validate(cosmeticIdSchema),
  asyncHandler(petController.setActiveCosmetic),
);

export default router;

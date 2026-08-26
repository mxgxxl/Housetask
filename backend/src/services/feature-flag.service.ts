/**
 * Per-household feature gate for the P1 economy (TD-066 §6).
 *
 * P1 has to ship dark: models and routes land on `main` (and therefore on
 * Railway, which auto-deploys every push) commit by commit, while no
 * household sees a behaviour change until its migration snapshot has been
 * taken and recorded. TD-066-DESIGN §6.1 is explicit — "Desplegar índices y
 * modelos con feature flag apagado" — and §9 lists "apagar flag P1" as the
 * rollback for the double-reward risk.
 *
 * ── Why the source of truth is injected ──────────────────────────────────
 * The eventual authority is `HouseholdEconomyMigration.phase`, which does not
 * exist yet: that model arrives in B2 and is written by the activation script
 * in B11. Rather than have this module import a model it cannot use yet — or,
 * worse, ship an env-var flag now and rewrite every call site later — the
 * gate is a resolver this module owns and B11 registers.
 *
 * That keeps three properties that matter more than the indirection costs:
 *
 *  1. The default is OFF and cannot be anything else. A missing registration
 *     is not a fail-open; it is the shipped state of every commit from B1
 *     until activation.
 *  2. Nothing about the flag's SHAPE changes when the real source lands, so
 *     B3-B10 can call `isP1Enabled` for real and their tests can register a
 *     fake resolver without a database.
 *  3. The kill switch sits above the resolver, so it works even if the
 *     resolver itself is what has gone wrong.
 */

import { logger } from '../utils/logger';

/**
 * Decides whether one household has P1 active. Async because the real
 * implementation reads a collection.
 */
export type P1EnabledResolver = (householdId: string) => Promise<boolean>;

/**
 * The shipped default: nobody has P1.
 *
 * Not a placeholder to be replaced in this commit — this IS the correct
 * behaviour for every deploy between B1 and activation.
 */
const disabledResolver: P1EnabledResolver = async () => false;

let resolver: P1EnabledResolver = disabledResolver;

/**
 * Environment kill switch, checked ahead of the resolver on every call.
 *
 * Read per call rather than cached at import time on purpose: a kill switch
 * whose value is frozen when the module first loads cannot be used to stop an
 * incident in a process that is already running. The cost is one `process.env`
 * lookup and a string compare.
 *
 * Only the exact string `'true'` arms it. A truthy-ish value ('1', 'yes',
 * 'false') does NOT — a kill switch that fires on `'false'` would be worse
 * than no kill switch, and `'0'`/`'no'` failing to disarm it would be worse
 * still, so the comparison is deliberately exact in the one direction that
 * defaults to "not armed".
 */
export function isKillSwitchOn(): boolean {
  return process.env.P1_ECONOMY_KILL_SWITCH === 'true';
}

/**
 * Register the real source of truth. Called once during startup wiring by
 * B11, and by tests that need a household to appear enabled.
 */
export function setP1EnabledResolver(next: P1EnabledResolver): void {
  resolver = next;
}

/**
 * Restore the shipped default. Test-only; production registers once and keeps
 * it for the process's life.
 */
export function resetP1EnabledResolver(): void {
  resolver = disabledResolver;
}

/**
 * Whether the P1 economy is active for this household.
 *
 * Fails CLOSED on every abnormal path — kill switch armed, missing household
 * id, resolver throwing. An economy gate that fails open would start writing
 * personal ledgers for a household whose legacy balance has not been
 * snapshotted, which is precisely the state TD-066-DESIGN §6 exists to make
 * impossible; falling back to Fase A instead is always recoverable.
 */
export async function isP1Enabled(householdId: string): Promise<boolean> {
  if (isKillSwitchOn()) {
    return false;
  }
  if (!householdId) {
    return false;
  }

  try {
    return await resolver(householdId);
  } catch (err) {
    logger.error('P1 feature-flag resolver failed, falling back to disabled', {
      householdId,
      message: (err as Error).message,
    });
    return false;
  }
}

# NEXT_SESSION_MAC

## Decisión activa

- Claude Code sigue siendo herramienta principal en Mac.
- OpenAI Codex es agente secundario:
  - Mac: Codex CLI, commits directos a main, push aprobado por el dueño.
  - Móvil/cloud: Codex app/web, rama + PR + CI + aprobación del dueño.
- gh CLI instalado y autenticado (Claude Code gestiona PRs y merges).
- Piloto Codex cerrado el 2026-08-17 con resultado positivo.

## Reglas de ejecución

- Un solo agente activo en el repo a la vez.
- El dueño no edita archivos: todo cambio va en prompts de agente.
- No tocar TDs abiertos sin instrucción explícita.
- Commits atómicos; push solo con aprobación del dueño.
- CI verde obligatorio para PRs (flujo móvil/cloud).

## Historial

- 2026-08-16: backlog grooming móvil; TD-002 y TD-015 Resolved.
- 2026-08-17: PR #32 config fallback (Codex); PR #33 integración legacy
  (Claude); PR #34 sync (Codex, cerrado como superseded sin merge). Plan free de Codex activo y validado.
  gh instalado; Codex CLI instalado y autenticado.

## Pendientes arrastrados (grooming 2026-08-16)

- TD-040: CI se cuelga en `offline_banner_test.dart` (runs 31932316995 y 31931761644, ~192 s, solo 3 tests completan).
- TD-010: verificar backups en el dashboard de MongoDB Atlas/Railway.
- Top-3 Mac: TD-040, TD-001 y TD-007.

## Siguiente tarea

El check de CI documental quedó implementado el 2026-08-17 (job `docs` +
`scripts/check_docs.sh`, PR #35 fusionado — ver `IMPROVEMENTS.md`), así que no
queda ningún pendiente de proceso bloqueante.

1. **TD-007 — optimistic updates en frontend.** Es el siguiente del Top-3 de
   Mac ahora que TD-040 está cerrado. Toca `TaskCubit` y `ShoppingCubit` y su
   interacción con la cola offline (TD-003 / ADR-010).
2. **TD-001 — migrar `members` embebido a colección separada.** La migración
   más grande del backlog abierto.

### Cerrado en esta sesión

**TD-040 — Resolved (2026-08-17), resultado A: la causa raíz era nuestra, no
del toolchain.** El 4º test de `offline_banner_test.dart` escribía en Hive
(`Box.put()`, escritura real a disco) dentro de la zona fake-async de
`testWidgets`; el callback de finalización queda agendado en el reloj falso,
que deja de bombearse al terminar el cuerpo del test, así que la escritura
nunca completa y el lock de la box no se libera — y el `clearAll()` del
`tearDown` se queda esperándolo para siempre. De ahí el 0% de CPU sin fallo de
aserción. Fix de una línea en el propio test (`tester.runAsync`); los 6 tests
pasan en <1s y la suite completa (234 tests) en verde. Ver `docs/TECH_DEBT.md`.

**Pendiente de aprobación del dueño:** retirar el `continue-on-error` del paso
aislado de `offline_banner_test.dart` en `.github/workflows/ci.yml` y plegarlo
al paso bloqueante. No se tocó `ci.yml` en esta sesión por la regla de
aprobación previa.

### Pendientes menores

- Extender el check de enlaces de docs a `CLAUDE.md` (enlaza `docs/ADRs.md`,
  entre otros). Hoy `scripts/check_docs.sh` solo valida los de `AGENTS.md`.

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

1. **Decidir siguiente tarea del backlog:**
   - ~~Quick-win TD-016 (CORS fail-fast) desde móvil~~ — **descartado: TD-016
     ya está Resolved**, implementado en el PR #22 y verificado el 2026-08-16
     (`utils/env.ts`, `validateProductionEnv`; ver `docs/TECH_DEBT.md` y la
     Hard Rule 15). Figuraba como quick-win en el grooming del 2026-08-16 y
     quedó obsoleto ese mismo día.
   - Top-3 de Mac: TD-040 (cuelgue `offline_banner_test`), TD-001 (migración
     `members`), TD-007 (optimistic updates). Ver "Pendientes arrastrados"
     arriba.

### Pendientes menores

- Extender el check de enlaces de docs a `CLAUDE.md` (enlaza `docs/ADRs.md`,
  entre otros). Hoy `scripts/check_docs.sh` solo valida los de `AGENTS.md`.

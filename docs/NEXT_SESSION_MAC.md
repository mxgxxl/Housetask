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
  (Claude); PR #34 sync (Codex). Plan free de Codex activo y validado.
  gh instalado; Codex CLI instalado y autenticado.

## Siguiente tarea

1. Decidir destino de frontend/android/build.gradle.save
   (artefacto candidato a borrar; valorar *.save en .gitignore).
2. Check de CI documental (enlaces de AGENTS.md, divergencia AGENTS/CLAUDE,
   tabla TDs de CLAUDE vs TECH_DEBT) — requiere aprobación.

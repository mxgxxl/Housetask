# AGENT_FALLBACK

Este documento define cómo usar agentes alternativos a Claude Code en HomeSync.

## Herramienta principal

Claude Code.

## Herramienta secundaria

OpenAI Codex.

## Propósito del fallback

Permitir continuidad operativa cuando Claude Code alcanza límites de sesión o semanales, manteniendo calidad, seguridad y trazabilidad.

## Modelo operativo

- Claude Code se usa para arquitectura, debugging complejo, refactors delicados y decisiones sensibles.
- Codex se usa como fallback para tareas acotadas, mecánicas, tests, documentación, bugs pequeños y PRs validables por CI.
- Las tareas complejas que no puedan dividirse con seguridad se dejan en cola para Claude si Codex no ofrece garantías suficientes.

## Tareas aptas para Codex

- Bugs pequeños y localizados.
- Tests acotados.
- Documentación.
- Renombrados.
- Limpieza mecánica.
- Migraciones simples.
- Cambios de UI simples.
- Tareas con acceptance criteria claro.
- PRs validables por CI.

## Tareas no aptas para Codex sin aprobación

- Arquitectura nueva.
- Refactors transversales.
- Cambios de producto no decididos.
- Modificación de TDs abiertos.
- Añadir dependencias no imprescindibles.
- Cambios en CI/CD.
- Cambios en secretos, despliegue o producción.
- Cambios con riesgo alto o diff grande.

## Flujo de trabajo

### Mac — Codex CLI

1. Trabajar directamente sobre main.
2. Aplicar el cambio mínimo y hacer commits atómicos.
3. El dueño aprueba el push.
4. Sincronizar los archivos de contexto.

### Móvil/cloud — Codex app/web

1. Crear rama desde main.
2. Aplicar el cambio mínimo y hacer commits atómicos.
3. Abrir PR.
4. CI debe pasar.
5. El dueño aprueba el merge.
6. Sincronizar los archivos de contexto.

## Archivos de contexto

- CLAUDE.md
- IMPROVEMENTS.md
- docs/TECH_DEBT.md
- docs/PRODUCT_DECISIONS.md
- docs/ROADMAP.md
- docs/NEXT_SESSION_MAC.md

## Reglas

- No modificar TDs abiertos sin instrucción explícita.
- No introducir cambios fuera del alcance.
- Mantener estilo existente.
- Si se cambia comportamiento de producto, documentarlo.
- Si se añaden tests, deben ser relevantes y estables.
- El push siempre requiere aprobación del dueño.
- CI verde obligatorio antes de merge en el flujo móvil/cloud.

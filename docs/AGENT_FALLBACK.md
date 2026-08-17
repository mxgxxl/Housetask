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

1. Crear rama desde main.
2. Aplicar cambio mínimo.
3. Hacer commits atómicos.
4. Abrir PR.
5. CI debe pasar.
6. El dueño aprueba el merge.
7. Sincronizar archivos de contexto.

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
- No hacer push directo a main durante el pilotaje de Codex.
- CI verde obligatorio antes de merge.

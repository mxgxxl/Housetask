# AGENTS.md

HomeSync usa como fuente principal de contexto el archivo CLAUDE.md.

Cualquier agente que trabaje en este repositorio debe leer antes:

- CLAUDE.md
- docs/AGENT_FALLBACK.md
- docs/PRODUCT_DECISIONS.md
- docs/TECH_DEBT.md
- docs/ROADMAP.md
- docs/NEXT_SESSION_MAC.md

## Reglas críticas

1. No modificar TDs abiertos sin instrucción explícita.
2. Commits atómicos.
3. No añadir dependencias si no es imprescindible.
4. Mantener el estilo existente.
5. No hacer cambios fuera del alcance de la tarea.
6. Si cambia comportamiento de producto, documentar la decisión.
7. Durante el pilotaje de agentes secundarios, trabajar por rama y PR.
8. CI debe pasar antes de merge.
9. El dueño aprueba decisiones, push y merge.

## Flujo esperado

- Crear rama desde main.
- Hacer cambios mínimos.
- Generar commits atómicos.
- Abrir PR.
- Esperar CI verde.
- Esperar aprobación del dueño.

## Tareas aptas para agentes secundarios

- Bugs pequeños y localizados.
- Tests acotados.
- Documentación.
- Refactors mecánicos.
- Cambios de UI simples.
- Tareas con acceptance criteria claro.

## Tareas que requieren aprobación o Claude

- Arquitectura nueva.
- Refactors transversales.
- Cambios de producto no decididos.
- Modificación de TDs abiertos.
- Cambios en CI/CD.
- Cambios en secretos, despliegue o producción.
- Añadir dependencias nuevas.

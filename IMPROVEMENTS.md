# Improvements & Workflow Learnings

Living document capturing operational learnings from the Mac↔Mobile workflow established over the last 3 days (2026-08-13 to 2026-08-16).

---

## Flujo Mac↔Móvil

### Reglas pactadas

- **Mac:** trabajo directo en main, commits atómicos, push normal. Sin ramas ni PRs.
- **Móvil:** rama nueva desde main actualizado por sesión. Reset de rama entre bloques de trabajo. Merge vía PR con CI verde. Sin amend ni force-push.
- **Modelos por tarea:** Sonnet 5 xhigh para features con lógica de negocio; Sonnet 5 medium/high para tareas mecánicas (docs, limpiezas); Sonnet 4 high para docs (40% más barato).

### Anclajes de seguridad en prompts móviles

- "Verifica que main contiene el commit X; si no, DETENTE"
- "Rama + PR, NUNCA mergees"
- "Sin amend/force-push"
- "Máx. 2 iteraciones de fix si CI rojo"

### Overhead de tokens del flujo móvil (~30-50% vs local)

- Setup inicial: lectura CLAUDE.md + verificación HEAD + git checkout/pull/branch (+15-20%)
- Reglas explícitas de seguridad en el prompt (+10-15%)
- Reportes detallados con hashes/drifts/URLs/CI (+20-25%)
- CI monitoring suscrito (+15-30% si sale rojo)
- Rama nueva por bloque para evitar divergencia (+10%)

---

## Lecciones aprendidas

### Migración EU (2026-08-16)

- **Orden crítico:** Sentry primero (decisión permanente), luego Railway (sin downtime), luego Redis.
- **Dependencias:** mover SOLO Railway a EU empeoraría la latencia si Atlas queda en US. Verificar región de Atlas/Redis antes de mover Railway.
- **Ganancia real:** ~60% menos latencia España→Railway Ámsterdam→Mongo París vs España→Railway US→Mongo París.

### Sentry setup (2026-08-16)

- **Data storage location (US/EU) es permanente** — no se puede cambiar después de crear la organización.
- **DSN de frontend NO va en variables de entorno** — entra por `--dart-define=SENTRY_DSN=...` en builds de release, para que builds de debug locales sigan no-op.
- **Alerts recomendados para apps pequeñas:** solo email, sin GitHub issues automáticos (ruido en repo).

### Hipótesis refutadas

- **2026-08-16 (TD-047):** "Home no muestra tareas hasta refresh" → resultó no ser un bug de load inicial; era combinación de dos bugs previos (timeline stale + creación 400). Documentado como "Resolved — hypothesis refuted" en docs/TECH_DEBT.md.
- **Lección:** antes de lanzar fix de hipótesis, verificar con evidencia de runtime (logs, status codes), no solo con análisis de código.

---

## Fricciones conocidas

### TD-040 — cuelgue de offline_banner_test.dart

- Se reproduce incluso ejecutándolo aislado.
- `frontend_server_aot` congela CPU tras 90s+ incluso con build/test_cache limpio.
- Parece host-level stall (¿resource pressure?), no bug de test.
- **Workaround CI:** paso aislado con continue-on-error (TD-044).
- **Pendiente:** investigar con --verbose en Mac idle.

### Bloqueo de npm test desde móvil (proxy MongoDB)

- `mongodb-memory-server` intenta descargar binarios de MongoDB → 403 desde algunas redes.
- **Workaround:** CI valida tests, móvil solo typecheck+lint+build.

---

## Próximas mejoras pendientes

- **IMPROVEMENTS.md mismo:** documentar decisiones de PDR faltantes (002, 003, 005) cuando se creen.
- **README.md update:** añadir mascota, papelera, Sentry, --dart-define, infra EU (pendiente).
- **backend/README.md:** falta por crear (setup + patrón controller/service/model).

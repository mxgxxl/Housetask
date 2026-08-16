# Próxima sesión de Mac

Generado durante el backlog grooming del 2026-08-16 (sesión móvil, `chore/backlog-grooming`). Ver `docs/TECH_DEBT.md` para el registro completo con la columna Priority nueva.

---

## Top 3 TDs para próxima sesión de Mac

1. **TD-040 — investigar el cuelgue de `offline_banner_test.dart`.**
   Requiere CPU libre y un toolchain Flutter local con `--verbose`/`--machine`, no factible desde una sesión móvil sin toolchain. Confirmado de nuevo hoy (ver evidencia abajo): sigue reproduciéndose en CI, no es un falso positivo antiguo.

2. **TD-001 — migrar `members` embebido a una colección `HouseholdMember` separada.**
   Es la migración más grande y arriesgada del backlog abierto (toca modelo, todos los servicios que leen `household.members`, y el frontend). Se beneficia de iteración local sin el overhead de rama+PR+CI por cada paso intermedio que impone el flujo móvil (ver `IMPROVEMENTS.md`).

3. **TD-018 — lifecycle de member-leave (unassign de tareas pendientes + "Former member" en UI).**
   Es el TD abierto de mayor severidad (High) que no requiere toolchain especial, pero sí tocar backend (`household.service.ts`) y frontend (task tiles, assignee selector) de forma coherente en la misma sesión — mejor sin el corte de una PR intermedia. Nota: ya está *parcialmente* mitigado — `task_tile.dart` ya muestra "Ex-miembro" como fallback para `completedBy` (PDR-002), pero el unassign de `assignedTo` en tareas pendientes al salir/ser removido de un hogar sigue sin implementar.

---

## TD-040: pasos concretos

```bash
cd frontend
flutter test test/widgets/offline_banner_test.dart --verbose
# Observar dónde se congela (PID con 0% CPU tras 90s+ = host-level stall)
# Probar con --machine para output estructurado
```

**Evidencia fresca (2026-08-16, verificada en esta sesión):** los últimos 2 runs de CI en `main` (runs `31932316995` y `31931761644`) muestran el mismo patrón exacto:
- Solo 3 tests del archivo completan (`✅ shows the yellow offline banner...`, `✅ no banner at all...`, `✅ shows no pending-count badge...`) y luego el proceso se congela.
- El step muere por el timeout de 3 minutos configurado (`##[error]The action '...' has timed out after 3 minutes.`), no por un fallo de aserción.
- Duración del step en ambos runs: ~192-193s, consistente run a run — no es aleatorio, es un cuelgue reproducible en el mismo punto.
- `continue-on-error: true` mantiene el job verde, así que esto no bloquea nada hoy, pero sigue sin root-causar.

---

## Deuda técnica detectada durante este análisis (no está en TECH_DEBT.md)

1. **`CLAUDE.md`'s "Currently open TDs" table quedará desincronizada con `docs/TECH_DEBT.md`.** Esta sesión marcó TD-002 y TD-015 como Resolved en TECH_DEBT.md (ver más abajo), pero por scope cerrado ("análisis y priorización de backlog") no tocó la tabla resumen de CLAUDE.md, que todavía los lista como abiertos. No hay ningún check automático que mantenga ambas tablas sincronizadas — es un candidato a TD propio ("backlog registry sync") o, más simple, a un lint/script que falle si un ID aparece con status distinto en ambos archivos.

2. **TD-024 (migración SHA-256 de refresh tokens) tiene un status ambiguo ("Script ready... run with --yes during the deploy window of b2c481e") que no dice si esa migración ya se ejecutó realmente en producción.** El commit `b2c481e` es histórico; dado que ha habido múltiples deploys desde entonces (incluyendo el reciente TD-027 breaking-change documentado en CLAUDE.md), probablemente ya corrió, pero esta sesión no tiene forma de verificarlo (requiere acceso a los logs de deploy de Railway o confirmar con quien lo ejecutó). Recomendado: verificar y, si ya corrió, flipear el status a Resolved con la fecha real.

3. **TD-010 (backups de MongoDB Atlas) no se pudo verificar** — la tarea pedía comprobar el dashboard de Railway/Atlas, pero esta sesión no tiene acceso a navegador/dashboard, solo lectura de código y docs. Queda con su status original (Planned) y Priority=High asignada en esta sesión (ver justificación en TECH_DEBT.md: severidad Medium pero blast-radius catastrófico si ocurre). Verificar en la próxima sesión con acceso al dashboard (Mac o móvil con navegador, no hace falta que sea específicamente Mac).

4. **TD-016 (CORS fail-fast en producción) es un fix trivial (unas pocas líneas en `app.ts` + un test de arranque) que quedó con Priority=High en este grooming.** No requiere Mac — es perfectamente abordable desde una sesión móvil normal (rama + PR), se menciona aquí solo porque no entraba en el "Top 3" de items grandes pero es el quick-win de mayor prioridad del backlog abierto.

5. **Ningún TD nuevo de código encontrado** más allá de los puntos anteriores — el análisis fue de verificación (¿ya está implementado lo que dice el registro?), no una auditoría de código nueva.

---

## Resumen de cambios de este grooming

- **TD-002** (paginación) y **TD-015** (`express.json` payload limit) estaban implementados en código pero seguían "Planned" en el registro — flipeados a Resolved con evidencia (archivo/línea).
- **Columna Priority** añadida a `docs/TECH_DEBT.md` (severidad ponderada por frecuencia/impacto actual; solo se asigna a filas abiertas). Tabla reordenada: abiertos (High→Medium→Low) primero, resueltos/cerrados en orden cronológico original después.
- El resto de TDs verificados explícitamente (TD-001, TD-006, TD-007, TD-013, TD-016, TD-018, TD-034, TD-039, TD-040) se confirmaron como genuinamente abiertos — sin cambios de status.

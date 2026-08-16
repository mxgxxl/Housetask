# Roadmap HomeSync

> Última actualización: 2026-08-17

## Recién Completado (últimas 2 semanas)

| Fecha | PR/Commit | Descripción | Impacto |
|-------|-----------|-------------|---------|
| 2026-08-17 | fix/td-050-refresh-race-condition | TD-050 resuelto (Opción A aprobada por el dueño): revocación de replay filtrada por `createdAt < requestStartedAt`, elimina el logout fantasma en refresh concurrente sin debilitar la detección de replay real | Seguridad + UX — cierra el único High-severity abierto del scan de auth |
| 2026-08-16 | PR #25 (857fc1c) | Escaneo seguridad backend auth: rate limit en `/api/auth/refresh` y `/logout` (commit 19521d0), TD-050..TD-054 registrados en TECH_DEBT.md | Seguridad reforzada — cierra el único hueco de rate limiting que quedaba en `/api/auth/*` |
| 2026-08-16 | PR #24 (29fc2d3) | Fix white screen iOS: `NotificationService.init()` colgaba pidiendo permiso Darwin antes de `runApp()` — permiso diferido vía `addPostFrameCallback` | Estabilidad iOS — la app arrancaba en pantalla en blanco en dispositivo físico |
| 2026-08-16 | 4 commits a main (787fc1a, 1425b7a, 69c1181, 8aaf17d, 4c080aa, 2892e72) | Setup Firebase/TD-049: plugin Gradle guardado tras `file('google-services.json').exists()`, `UIBackgroundModes` en Info.plist, docs actualizadas | Push notifications prep — config parcial, aún requiere pasos manuales en Xcode |

## En Progreso (actual)

### Validación PR #24 + limpieza de debugPrints
- **Estado:** pendiente validación en dispositivo físico iOS.
- **Bloqueante:** requiere iPhone real (no reproducible en simulador para el diálogo de permisos nativo).
- **Siguiente paso:** el dueño prueba la app; si confirma que la pantalla en blanco no reaparece, se abre un PR de limpieza que quita los `debugPrint('[bootstrap] ...')` marcados `TODO(tech-debt)` en `main.dart`.

### Fix TD-050 — validación en CI
- **Estado:** código + tests implementados y pusheados a `fix/td-050-refresh-race-condition`; `npm run typecheck` y `npm run lint` pasan limpio.
- **Bloqueante:** la sesión que implementó el fix no pudo correr la suite de Jest localmente (`mongodb-memory-server` bloqueado por política del proxy, mismo problema ya documentado en IMPROVEMENTS.md para sesiones móviles — se confirmó que también aplica aquí). Falta que CI (que sí resuelve el binario) confirme los 300+ tests en verde antes de considerar el PR mergeable.
- **Siguiente paso:** revisar el resultado de GitHub Actions en el PR y, si CI está verde, el dueño decide si mergea.

## Próximas Prioridades (ordenado)

| # | ID | Descripción | Esfuerzo | Bloqueante |
|---|----|-------------|----------|------------|
| 1 | Validación PR #24 | Probar fix white screen en iPhone físico + limpiar debugPrints de diagnóstico | Bajo | Dispositivo físico |
| 2 | TD-050 (CI) | Confirmar CI verde en `fix/td-050-refresh-race-condition` y mergear | Bajo | Ninguno — solo esperar el run de GitHub Actions |
| 3 | TD-051/TD-052/TD-053 | Hardening defensivo: pinning de `algorithms` en `jwt.verify`, assert `JWT_SECRET !== JWT_REFRESH_SECRET`, comparación bcrypt dummy contra timing en login | Bajo | Ninguno — abordable desde cualquier sesión |
| 4 | Ronda 2 escaneo frontend | State management (preparada, no lanzada) | Alto | Ninguno |
| 5 | TD-040 | Investigar cuelgue de `offline_banner_test.dart` en hosts cargados | Medio | Mac + CPU idle |

## Futuro (backlog)

### Funcionalidades
- PDR-007: Stats de hogar (completado).
- PDR-008: Push notifications (setup parcial, TD-049) — pendiente capability de Xcode, APNs key, test end-to-end.
- Cuenta Apple Developer ($99/año) — necesaria para push iOS real y publicación en App Store.
- Self-leave endpoint (gap identificado durante TD-018): hoy solo un admin puede remover a otro miembro; no existe salida voluntaria de un hogar. La lógica de `unassignDepartedMemberTasks` ya está lista para reutilizarse.

### Mejoras Técnicas Diferidas
- TD-001: migrar `members` embebido en Household a una colección `HouseholdMember` separada.
- TD-007: optimistic updates en frontend.
- TD-010: backups de MongoDB Atlas.
- TD-013: recurrencia con timezone por hogar.
- TD-024: verificar si la migración SHA-256 de refresh tokens ya se ejecutó en producción (status ambiguo, ver `docs/NEXT_SESSION_MAC.md`).
- TD-034: versioned API health check / deploy-order safety net.
- TD-039: offline conflict resolution (CRDT/OT) si se reportan ediciones perdidas.
- TD-054: acortar ventana de token de acceso post-logout (bajo impacto, solo si el modelo de amenaza incluye dispositivos compartidos/perdidos).

---

Para el registro completo de deuda técnica con severidad/prioridad/solución propuesta, ver [docs/TECH_DEBT.md](TECH_DEBT.md). Para la lista corta de TDs abiertos, ver la sección homónima en [CLAUDE.md](../CLAUDE.md#-technical-debt-registry).

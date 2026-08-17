# Roadmap HomeSync

> Última actualización: 2026-08-17

## Recién Completado (últimas 2 semanas)

| Fecha | PR/Commit | Descripción | Impacto |
|-------|-----------|-------------|---------|
| 2026-08-17 | scan/frontend-state-management | Ronda 2 de escaneo: auditoría de state management (7 Cubits, repositories, caché offline, socket). 14 hallazgos; 4 High registrados como TD-055..TD-058, 10 Medium/Low documentados en IMPROVEMENTS.md. Sin cambios de código de producción | Calidad — descubre 2 bugs funcionales silenciosos (timeline sin paginar, escritura offline perdida) y 2 de ciclo de vida de sesión |
| 2026-08-17 | PR #28 (fix/td-051-053-explicit-security-configs, mergeado) | TD-051/TD-052/TD-053 resueltos: JWT algorithm explícito (sign+verify), assert `JWT_SECRET !== JWT_REFRESH_SECRET` en producción, comparación bcrypt dummy en login para eliminar el side-channel de timing | Seguridad — cierra los tres Medium restantes del scan de auth, ya no dependen de defaults de dependencias |
| 2026-08-17 | PR #27 (fix/td-050-refresh-race-condition, mergeado) | TD-050 resuelto (Opción A aprobada por el dueño): revocación de replay filtrada por `createdAt < requestStartedAt`, elimina el logout fantasma en refresh concurrente sin debilitar la detección de replay real. CI backend confirmó la suite en verde antes del merge. | Seguridad + UX — cierra el único High-severity abierto del scan de auth |
| 2026-08-16 | PR #25 (857fc1c) | Escaneo seguridad backend auth: rate limit en `/api/auth/refresh` y `/logout` (commit 19521d0), TD-050..TD-054 registrados en TECH_DEBT.md | Seguridad reforzada — cierra el único hueco de rate limiting que quedaba en `/api/auth/*` |
| 2026-08-16 | PR #24 (29fc2d3) | Fix white screen iOS: `NotificationService.init()` colgaba pidiendo permiso Darwin antes de `runApp()` — permiso diferido vía `addPostFrameCallback` | Estabilidad iOS — la app arrancaba en pantalla en blanco en dispositivo físico |
| 2026-08-16 | 4 commits a main (787fc1a, 1425b7a, 69c1181, 8aaf17d, 4c080aa, 2892e72) | Setup Firebase/TD-049: plugin Gradle guardado tras `file('google-services.json').exists()`, `UIBackgroundModes` en Info.plist, docs actualizadas | Push notifications prep — config parcial, aún requiere pasos manuales en Xcode |

## En Progreso (actual)

### Validación PR #24 + limpieza de debugPrints
- **Estado:** pendiente validación en dispositivo físico iOS.
- **Bloqueante:** requiere iPhone real (no reproducible en simulador para el diálogo de permisos nativo).
- **Siguiente paso:** el dueño prueba la app; si confirma que la pantalla en blanco no reaparece, se abre un PR de limpieza que quita los `debugPrint('[bootstrap] ...')` marcados `TODO(tech-debt)` en `main.dart`.

### Fixes de la ronda 2 de frontend (TD-055..TD-058)
- **Estado:** identificados y documentados, **sin implementar** — el escaneo fue de scope cerrado (identificar, no arreglar).
- **Bloqueante:** ninguno para empezar, pero conviene una sesión **con toolchain de Flutter**: el escaneo se hizo por lectura de código (este entorno no tiene `flutter`), así que ningún hallazgo está reproducido en runtime y los fixes necesitan tests que sí se puedan ejecutar.
- **Siguiente paso:** decidir si se abordan agrupados (TD-055+TD-058 comparten fix; TD-056 cierra también el hallazgo F7) — ver "Próximos pasos recomendados" en IMPROVEMENTS.md.

## Próximas Prioridades (ordenado)

| # | ID | Descripción | Esfuerzo | Bloqueante |
|---|----|-------------|----------|------------|
| 1 | Validación PR #24 | Probar fix white screen en iPhone físico + limpiar debugPrints de diagnóstico | Bajo | Dispositivo físico |
| 2 | TD-055 + TD-058 | Listener global de `unauthenticated`: rutar a login al expirar la sesión + resetear los cubits de feature (mismo fix, hacerlos juntos) | Medio | Toolchain Flutter para tests |
| 3 | TD-056 | Sentinel `clearTimelineCursor` en `TaskState.copyWith` — arregla también F7 (errores de vista borrados) | Bajo | Toolchain Flutter para tests |
| 4 | TD-057 | Persistir el remap de ids en la cola offline (pérdida silenciosa de escrituras) | Medio | Toolchain Flutter para tests |
| 5 | F6 (IMPROVEMENTS) | Rebind de listeners del socket — latente hoy, se activa al arreglar TD-055 | Bajo | Hacerlo junto con TD-055 |
| 6 | F10 (IMPROVEMENTS) | Tests para SocketCubit / HouseholdCubit / StatsCubit (hoy sin cobertura) | Medio | Toolchain Flutter |
| 7 | TD-040 | Investigar cuelgue de `offline_banner_test.dart` en hosts cargados | Medio | Mac + CPU idle |
| 8 | TD-054 | Ventana de token de acceso post-logout (bajo impacto, solo si el modelo de amenaza lo requiere) | Bajo | Ninguno — es el único TD del scan de auth backend que sigue abierto |

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

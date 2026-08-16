# Roadmap HomeSync

> Última actualización: 2026-08-17

## Recién Completado (últimas 2 semanas)

| Fecha | PR/Commit | Descripción | Impacto |
|-------|-----------|-------------|---------|
| 2026-08-16 | PR #25 (857fc1c) | Escaneo seguridad backend auth: rate limit en `/api/auth/refresh` y `/logout` (commit 19521d0), TD-050..TD-054 registrados en TECH_DEBT.md | Seguridad reforzada — cierra el único hueco de rate limiting que quedaba en `/api/auth/*` |
| 2026-08-16 | PR #24 (29fc2d3) | Fix white screen iOS: `NotificationService.init()` colgaba pidiendo permiso Darwin antes de `runApp()` — permiso diferido vía `addPostFrameCallback` | Estabilidad iOS — la app arrancaba en pantalla en blanco en dispositivo físico |
| 2026-08-16 | 4 commits a main (787fc1a, 1425b7a, 69c1181, 8aaf17d, 4c080aa, 2892e72) | Setup Firebase/TD-049: plugin Gradle guardado tras `file('google-services.json').exists()`, `UIBackgroundModes` en Info.plist, docs actualizadas | Push notifications prep — config parcial, aún requiere pasos manuales en Xcode |

## En Progreso (actual)

### Validación PR #24 + limpieza de debugPrints
- **Estado:** pendiente validación en dispositivo físico iOS.
- **Bloqueante:** requiere iPhone real (no reproducible en simulador para el diálogo de permisos nativo).
- **Siguiente paso:** el dueño prueba la app; si confirma que la pantalla en blanco no reaparece, se abre un PR de limpieza que quita los `debugPrint('[bootstrap] ...')` marcados `TODO(tech-debt)` en `main.dart`.

### Registro TD-050..TD-054
- **Estado:** completado — las cinco entradas ya están en `docs/TECH_DEBT.md` (commit 7e0555d, mergeado en PR #25) y reflejadas en la tabla corta de CLAUDE.md.
- **Pendiente real:** TD-050 sigue sin fix aplicado — necesita una decisión del dueño sobre el tradeoff seguridad/UX antes de implementar el candidato (`deleteMany({ userId, createdAt: { $lt: requestStartedAt } })`), y esa implementación requiere validación contra MongoDB real (no disponible en sesiones móviles, ver IMPROVEMENTS.md).

## Próximas Prioridades (ordenado)

| # | ID | Descripción | Esfuerzo | Bloqueante |
|---|----|-------------|----------|------------|
| 1 | Validación PR #24 | Probar fix white screen en iPhone físico + limpiar debugPrints de diagnóstico | Bajo | Dispositivo físico |
| 2 | TD-050 | Decisión del dueño + fix de la race condition de refresh concurrente (revocación de familia completa) | Medio | Decisión de producto + sesión con MongoDB real (Mac) |
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

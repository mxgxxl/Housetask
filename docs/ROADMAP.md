# Roadmap HomeSync

> Última actualización: 2026-08-18

## Recién Completado (últimas 2 semanas)

| Fecha | PR/Commit | Descripción | Impacto |
|-------|-----------|-------------|---------|
| 2026-08-18 | TD-057 + TD-060 (round conjunto) | **TD-057 Resolved**: `syncPendingOperations` reescribe la cola antes de retirar el create, así que la traducción local→servidor sobrevive a un break y a un reinicio — cerraba una pérdida silenciosa de escrituras offline. **TD-060 Resolved**: creates optimistas con id `pending-` e intercambio de id en una sola emisión. Sin migración ni cambio de esquema. 290 tests | Corrección de datos — TD-057 era el único High abierto que perdía trabajo del usuario sin avisar |
| 2026-08-18 | TD-007 (parcial) | **Partially resolved**: `completeTask`, `updateTask`, `togglePurchased`, `updateItem`, `deleteTask` y `deleteItem` aplican el cambio a la UI antes de enviar la petición, con guarda de supersesión que no revierte sobre un valor más nuevo. Los creates se cerraron aparte, vía TD-060 | UX — desaparece la espera de round trip en las interacciones frecuentes |
| 2026-08-17 | TD-059 | **Resolved**: los once escritores de Hive de `CacheService` devuelven `Future<void>` y todos sus call sites los esperan, con política de errores dual (propagar en el camino offline, best-effort + Sentry al cachear lo que el servidor ya tiene) | Durabilidad — una escritura offline prometida al usuario ya no puede perderse en silencio |
| 2026-08-17 | TD-040 | **Resolved**: el cuelgue era nuestro, no del toolchain — una escritura real de Hive dentro de la zona fake-async de `testWidgets` bloqueaba el `tearDown`. Fix de una línea (`tester.runAsync`); el paso aislado con `continue-on-error` se plegó al bloqueante | CI — una regresión de tests vuelve a romper el build en vez de pasar en verde |
| 2026-08-17 | PR #32/#33/#35 — capa de proceso | **Cerrada**: flujo definitivo de agentes (Codex como secundario, `AGENTS.md` con las reglas normativas integradas) y check documental en CI (`scripts/check_docs.sh`: enlaces, coherencia de estados de TD entre CLAUDE.md y TECH_DEBT.md, bloques duplicados) | Proceso — la deriva entre documentos pasa a fallar el build en vez de descubrirse por casualidad |
| 2026-08-17 | fix/td-056-taskstate-copywith | TD-056 resuelto, cierra también F7: `TaskState.copyWith` reemplaza la asignación incondicional de campos nullable por el sentinel `clearX` (`error`, `timelineCursor`, `timelineError`, `recurringError`, `trashError`) — solo `offlineNotice` sigue incondicional, por diseño. `clearOfflineNotice()` pasa a ser `emit(state.copyWith())`. Test de timeline reforzado (F11) + 4 tests nuevos. 228 tests frontend en verde (validado localmente) | Calidad — el hallazgo High más sutil de la ronda 2: la timeline "Todas" ya puede paginar de verdad dentro de su ventana |
| 2026-08-17 | fix/td-055-058-session-lifecycle | TD-055 + TD-058 resueltos: nuevo widget `SessionListeners` (app.dart) reacciona a toda transición `unauthenticated` — desconecta el socket, resetea los 5 cubits de dominio, navega a login — sin importar qué página esté en pantalla. `reset()` añadido a Task/Shopping/Pet/Stats cubits. 224 tests frontend en verde (validado localmente con Flutter 3.44.9, no solo en CI) | UX + privacidad — cierra los dos High de mayor visibilidad de la ronda 2 (sesión muerta sin ruta de vuelta; datos de la cuenta anterior visibles tras logout) |
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

### Pruebas manuales de los rounds cerrados
- **Estado:** código en `main` y CI verde; falta la validación en dispositivo de los escenarios que solo se pueden ejercitar con red real.
- **Siguiente paso:** los guiones están en `docs/TD-057-DESIGN.md` §6 y `docs/TD-007-DESIGN.md` §7. Los dos que de verdad validan TD-057 son: (1) crear y editar offline, reconectar a mitad de la sincronización; (2) lo mismo matando la app en vez de cortando la red.

## Próximas Prioridades (ordenado)

| # | ID | Descripción | Esfuerzo | Bloqueante |
|---|----|-------------|----------|------------|
| 1 | TD-001 | Migrar `members` embebido a una colección `HouseholdMember` separada. **Siguiente paso: el documento de diseño**, mismo formato aprobable en bloque que TD-059/TD-007/TD-057. Es el primero del ciclo que toca backend y arrastra migración real en Atlas, con ventana de convivencia de ambos formatos y orden de despliegue obligatorio (ver "Deployment order" en CLAUDE.md) | Alto | Ninguno |
| 2 | Validación PR #24 | Probar fix white screen en iPhone físico + limpiar debugPrints de diagnóstico | Bajo | Dispositivo físico |
| 3 | TD-061 | El logout vacía la cola pendiente sin aviso: un cambio hecho offline y no sincronizado se pierde al cerrar sesión. La resolución probable es avisar, no dejar de limpiar | Bajo | Ninguno |
| 4 | TD-054 | Ventana de token de acceso post-logout (bajo impacto, solo si el modelo de amenaza lo requiere) | Bajo | Ninguno |

### Micro-pendientes

Ninguno bloquea nada; se listan para que no se pierdan.

- **Node 24 en CI**: `actions/checkout@v4` y compañía corren sobre Node 20, ya en deprecación. Además el comentario de `ci.yml:157` sigue diciendo "11 lints preexistentes" cuando son 14 — no se corrigió por la regla de no tocar CI fuera de su propio round. Ver IMPROVEMENTS.md (2026-08-17).
- **Check de enlaces a `CLAUDE.md`**: hoy `scripts/check_docs.sh` solo valida los enlaces de `AGENTS.md`; `CLAUDE.md` enlaza `docs/ADRs.md` y varios más sin verificar.
- **Homogeneizar `copyWith` y evaluar un mixin para el overlay optimista**: `TaskCubit` y `ShoppingCubit` llevan copias duplicadas del andamiaje, y sus estados difieren en si `copyWith` limpia `error` — lo que invierte el orden de emits en el rollback. Homogeneizar el contrato primero vale más que el mixin. Ver IMPROVEMENTS.md (2026-08-18).
- **SPM de `flutter_local_notifications`**: pendiente de revisar, sin registro previo en el repo (el precedente conocido de deriva SPM es TD-038, pero es de `sentry_flutter`, no de este plugin). Requiere que quien lo detectó amplíe el síntoma.
- **`UIScene`**: pendiente de revisar, igualmente sin registro previo en el repo ni entrada en TECH_DEBT.md.

### Limitaciones conocidas (aceptadas, no son bugs)

Documentadas en sus entradas de TECH_DEBT.md para que no se persigan como defectos nuevos.

- **Socket echo (TD-060):** el backend emite `task:created` también a quien creó la tarea, así que entre ese evento y la respuesta HTTP puede verse brevemente una fila duplicada. Se resuelve sola al confirmar. La solución limpia —que el socket haga eco de la `Idempotency-Key`— es un cambio de backend.
- **Recurrentes y Papelera (TD-007):** no reciben la superposición optimista, así que quedan desincronizadas hasta recargar su pestaña.
- **Colas envenenadas (TD-057):** una cola escrita por una versión anterior con un update/delete huérfano no se rescata; el dato ya está perdido en esos dispositivos.

## Futuro (backlog)

### Funcionalidades
- PDR-007: Stats de hogar (completado).
- PDR-008: Push notifications (setup parcial, TD-049) — pendiente capability de Xcode, APNs key, test end-to-end.
- Cuenta Apple Developer ($99/año) — necesaria para push iOS real y publicación en App Store.
- Self-leave endpoint (gap identificado durante TD-018): hoy solo un admin puede remover a otro miembro; no existe salida voluntaria de un hogar. La lógica de `unassignDepartedMemberTasks` ya está lista para reutilizarse.

### Mejoras Técnicas Diferidas
- TD-007: ~~optimistic updates en frontend~~ — Partially resolved 2026-08-18 (updates y deletes); creates cerrados vía TD-060.
- TD-010: backups de MongoDB Atlas.
- TD-013: recurrencia con timezone por hogar.
- TD-024: verificar si la migración SHA-256 de refresh tokens ya se ejecutó en producción (status ambiguo, ver `docs/NEXT_SESSION_MAC.md`).
- TD-034: versioned API health check / deploy-order safety net.
- TD-039: offline conflict resolution (CRDT/OT) si se reportan ediciones perdidas.
- TD-054: acortar ventana de token de acceso post-logout (bajo impacto, solo si el modelo de amenaza incluye dispositivos compartidos/perdidos).

---

Para el registro completo de deuda técnica con severidad/prioridad/solución propuesta, ver [docs/TECH_DEBT.md](TECH_DEBT.md). Para la lista corta de TDs abiertos, ver la sección homónima en [CLAUDE.md](../CLAUDE.md#-technical-debt-registry).

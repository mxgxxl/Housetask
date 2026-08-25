# Roadmap HomeSync

> Última actualización: 2026-08-25

## Recién Completado (últimas 2 semanas)

| Fecha | PR/Commit | Descripción | Impacto |
|-------|-----------|-------------|---------|
| 2026-08-25 | TD-001 | **Resolved**: cutover completo de la membresía a la colección `HouseholdMember`. Cinco fases con seis paradas, ventana de observación cerrada con cero divergencias, y las DOS copias desnormalizadas retiradas —`Household.members` y `User.households`— del esquema y de los datos (`$unset` aplicados el 2026-08-25). El handshake de socket lee ya la misma fuente que el HTTP. El contrato de la API no se movió en ningún despliegue: 130/130 checks idénticos en los seis runs de validación. Se cerró de paso un hueco de atomicidad que podía dejar hogares sin ninguna membresía. 359 tests | Arquitectura — desaparece la última fuente de verdad duplicada del dominio, y con ella el límite de 16MB por documento y el riesgo de divergencia que motivó ADR-005 |
| 2026-08-19 | TD-063 | **Resolved**: `_refreshToken` devuelve tres desenlaces (rotado / rechazado / inalcanzable) en vez de `String?`, que era el root cause. Solo un 401 mata la sesión; sin respuesta, 5xx, 429, 403 y portal cautivo la conservan. Sin reintento, porque la rotación no es idempotente y un reintento dispara la detección de replay del backend. Se arregla además la otra mitad del daño: la escritura en vuelo se encola en vez de perderse. 11 tests | UX + corrección de datos — una desconexión pasajera dejaba al usuario en el login y le borraba la tarea que acababa de crear |
| 2026-08-19 | TD-062 | **Resolved**: la caché de Hive lleva un marcador de propietario (`CacheOwner`, box propia) y `AuthCubit` lo comprueba en toda entrada a sesión —login, register y las dos ramas de `checkAuth`—, vaciándola antes de reclamarla si el usuario cambió (o si no hay marcador). Siempre ANTES de emitir `authenticated`: el orden es el arreglo, como en TD-057. Sin migración; `PendingOperation` intacto. 11 tests, 6 fallan sin el fix | Corrección de datos — la cola offline de una cuenta ya no se reproduce con el token de otra tras una expiración de sesión |
| 2026-08-19 | TD-061 | **Resolved**: el logout sigue vaciando la cola pendiente, pero ya no en silencio — intenta drenarla (tope de 5 s) y, si quedan cambios, avisa nombrando el número y cambia el botón a "Cerrar sesión y descartar". El aviso solo aparece cuando hay algo que perder. 11 tests | UX — deja de perderse trabajo offline sin que el usuario lo sepa; el descarte pasa a ser una decisión suya |
| 2026-08-19 | Node 24 en CI (PR #36) | Acciones de GitHub Actions actualizadas a las versiones que corren sobre Node 24 | Mantenimiento — Node 20 está en deprecación en el runner |
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

Con TD-001 cerrado, el orden de implementación de P0/P1/P2 queda desbloqueado:
**TD-064 → TD-066 → TD-068/069 → TD-070 → TD-071/072**. TD-067 (roles y
administración) puede ir en paralelo a TD-064: ambos son P0 y no dependen entre
sí, y TD-067 construye sobre la autoridad que TD-001 acaba de dejar fijada.

| # | ID | Descripción | Esfuerzo | Bloqueante |
|---|----|-------------|----------|------------|
| 1 | TD-064 | Paginación del timeline: sesiones keyset y caché normalizada en lugar de refetch de ventanas crecientes | Alto | Ninguno |
| 1b | TD-067 | Roles y administración: promoción/degradación, transferencia, salida voluntaria, destrucción del hogar | Alto | Ninguno (paralelo a TD-064) |
| 2 | TD-066 | Refactor de economía P1: wallets personales, XP dual, presupuesto, rachas y hucha. **Desbloqueado**: su única dependencia era el cutover de TD-001 | Alto | Ninguno |
| 3 | TD-068 / TD-069 | Recomendaciones por reglas y reparto inteligente de carga | Medio / Alto | TD-066 |
| 4 | TD-070 | Dashboard de salud del hogar | Alto | TD-066, TD-068, TD-069 |
| 5 | TD-071 / TD-072 | Reconocimiento entre miembros y deep-link de notificación | Medio / Alto | TD-070 (071) · TD-049 (072, push real) |
| 6 | Validación PR #24 | Probar fix white screen en iPhone físico + limpiar debugPrints de diagnóstico | Bajo | Dispositivo físico |
| 7 | Micro-pendientes | Ninguno bloquea nada; ver la lista de abajo | Bajo | Ninguno |
| 8 | TD-054 | Ventana de token de acceso post-logout (bajo impacto, solo si el modelo de amenaza lo requiere) | Bajo | Ninguno |

## Producto — P1 (el cutover de TD-001 ya no lo bloquea)

P1 y los bloques P2/P3 están en scope, pero P1 se cierra antes de decidir los posteriores. La especificación de producto y UX vive en [UX-P1-SPEC.md](UX-P1-SPEC.md); sus decisiones normativas son PDR-010 a PDR-019 en [PRODUCT_DECISIONS.md](PRODUCT_DECISIONS.md).

1. Separar XP y moneda.
2. Presupuesto semanal, reparto automático y ajuste manual opcional.
3. Niveles e hitos.
4. Rachas con hielos.
5. Misiones semanales cooperativas.

La mascota conserva una pista de arte separada y P1 solo incorpora sus ganchos lógicos. P2/P3 quedan diferidos: reparto inteligente, dashboard de salud, recomendaciones, eventos y notificaciones contextuales. No se eliminan ni sustituyen los ítems técnicos ya priorizados en este roadmap.

### Micro-pendientes

Ninguno bloquea nada; se listan para que no se pierdan.

- ~~**Node 24 en CI**~~ — hecho en PR #36 (2026-08-19), incluido el comentario de `ci.yml` que decía "11 lints preexistentes" cuando son 14.
- ~~**Check de enlaces a `CLAUDE.md`**~~ — hecho el 2026-08-19: `check_md_links()` se aplica a los dos archivos. Sus dos enlaces (`docs/ADRs.md`, `docs/TECH_DEBT.md`) ya resolvían, así que no había nada roto que arreglar.
- **Assert del marcador de caché en `syncPendingOperations`** y **test de la rama cacheada de `checkAuth`**: los dos huecos que dejó el round de TD-062, ambos defensa en profundidad. Ver IMPROVEMENTS.md (2026-08-19).
- **Homogeneizar `copyWith` y evaluar un mixin para el overlay optimista**: `TaskCubit` y `ShoppingCubit` llevan copias duplicadas del andamiaje, y sus estados difieren en si `copyWith` limpia `error` — lo que invierte el orden de emits en el rollback. Homogeneizar el contrato primero vale más que el mixin. Ver IMPROVEMENTS.md (2026-08-18).
- **SPM de `flutter_local_notifications`**: pendiente de revisar, sin registro previo en el repo (el precedente conocido de deriva SPM es TD-038, pero es de `sentry_flutter`, no de este plugin). Requiere que quien lo detectó amplíe el síntoma.
- **`UIScene`**: pendiente de revisar, igualmente sin registro previo en el repo ni entrada en TECH_DEBT.md.

### Limitaciones conocidas (aceptadas, no son bugs)

Documentadas en sus entradas de TECH_DEBT.md para que no se persigan como defectos nuevos.

- **Socket echo (TD-060):** el backend emite `task:created` también a quien creó la tarea, así que entre ese evento y la respuesta HTTP puede verse brevemente una fila duplicada. Se resuelve sola al confirmar. La solución limpia —que el socket haga eco de la `Idempotency-Key`— es un cambio de backend.
- **Recurrentes y Papelera (TD-007):** no reciben la superposición optimista, así que quedan desincronizadas hasta recargar su pestaña.
- **Marcador ausente (TD-062):** una caché escrita por una versión anterior no tiene marcador, así que la primera autenticación tras actualizar la vacía una vez. Es el comportamiento a prueba de fallos elegido a propósito, y solo ocurre una vez por dispositivo.
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
- **Pendiente manual de TD-001:** la entrega real por socket con dos clientes. Los tests cubren que el handshake resuelve las salas correctas desde la colección; ninguno cubre el transporte.
- TD-024: verificar si la migración SHA-256 de refresh tokens ya se ejecutó en producción (status ambiguo, ver `docs/NEXT_SESSION_MAC.md`).
- TD-034: versioned API health check / deploy-order safety net.
- TD-039: offline conflict resolution (CRDT/OT) si se reportan ediciones perdidas.
- TD-054: acortar ventana de token de acceso post-logout (bajo impacto, solo si el modelo de amenaza incluye dispositivos compartidos/perdidos).

---

Para el registro completo de deuda técnica con severidad/prioridad/solución propuesta, ver [docs/TECH_DEBT.md](TECH_DEBT.md). Para la lista corta de TDs abiertos, ver la sección homónima en [CLAUDE.md](../CLAUDE.md#-technical-debt-registry).

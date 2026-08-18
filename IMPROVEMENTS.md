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

### CI/CD: path-based skip (2026-08-16)

- **Problema:** PR #15 (docs-only: IMPROVEMENTS.md + PR template) corrió el workflow completo (backend + frontend), gastando ~10 min de CI en verificar código que no cambió.
- **Fix:** job `changes` (dorny/paths-filter@v3) al inicio de `.github/workflows/ci.yml`; los jobs `backend`/`frontend` ahora tienen `needs: changes` + `if: needs.changes.outputs.<job> == 'true'` y se saltan cuando sus paths no cambiaron. El propio `.github/workflows/ci.yml` está incluido en ambos filtros a propósito — un cambio al workflow siempre re-verifica ambas suites en vez de confiar ciegamente en el edit.
- **Lección:** un PR que solo toca `.github/workflows/ci.yml` (como el que introdujo este fix) sigue corriendo el CI completo por ese mismo motivo — no es "instantáneo", es la validación intencional del propio cambio de CI.

### iOS white-screen startup bug (2026-08-16)

- **Síntoma:** `flutter run` en iPhone físico instala la app, la Dart VM arranca, pero la pantalla se queda en blanco (launch screen nativa) — sin ningún print `flutter:` en consola, indicando que `main()` se colgaba antes de `runApp()`.
- **Diagnóstico:** se añadieron `debugPrint` temporales entre cada `await` del bootstrap en `main.dart` (Sentry → Firebase → NotificationService → CacheService → runApp) para aislar qué paso no completaba.
- **Causa raíz:** `NotificationService.init()` llamaba a `FlutterLocalNotificationsPlugin.initialize()` con `DarwinInitializationSettings(requestAlertPermission: true, ...)`, lo que dispara el diálogo de permisos del sistema en iOS. Al mostrarse ese diálogo antes de que Flutter hubiera renderizado el primer frame (`runApp()` no se había llamado todavía), el `await` quedaba bloqueado indefinidamente — de ahí la pantalla en blanco sin logs.
- **Fix:** `requestAlertPermission`/`requestBadgePermission`/`requestSoundPermission` puestos a `false` en `DarwinInitializationSettings` (así `plugin.initialize()` ya no dispara el diálogo), y la petición explícita de permisos (`_requestPermissions()`) se difiere con `WidgetsBinding.instance.addPostFrameCallback`, para que se ejecute después de que el primer frame ya esté en pantalla. `_requestPermissions()` también se envolvió en try/catch, consistente con el resto de llamadas al plugin en este archivo.
- **Nota:** no relacionado con TD-049 (que trata de conectar un proyecto Firebase real para push) — este bug es del plugin de notificaciones locales (`flutter_local_notifications`), independiente de FCM/Firebase.
- **Pendiente:** los `debugPrint('[bootstrap] ...')` añadidos a `main.dart` para el diagnóstico son temporales (marcados con `TODO(tech-debt)`) — quitar una vez el dueño confirme en dispositivo físico que la pantalla en blanco no reaparece.

### Hipótesis refutadas

- **2026-08-16 (TD-047):** "Home no muestra tareas hasta refresh" → resultó no ser un bug de load inicial; era combinación de dos bugs previos (timeline stale + creación 400). Documentado como "Resolved — hypothesis refuted" en docs/TECH_DEBT.md.
- **Lección:** antes de lanzar fix de hipótesis, verificar con evidencia de runtime (logs, status codes), no solo con análisis de código.

### Discrepancia de sesión (2026-08-17, móvil)

- Error de Qwen: asumió que TD-050..TD-054 no estaban registrados en TECH_DEBT.md. Verificación de Claude Code (commit 2fb2028) confirmó que ya estaban registrados desde 7e0555d (PR #25). Lección: verificar estado del repo antes de generar tareas de sincronización.

### Decisión TD-050 (2026-08-17)

- Opción elegida por el dueño: A — aplicar fix `createdAt: {$lt: requestStartedAt}`.
- Razón: riesgo de logout fantasma con conexión inestable > riesgo de replay real en ventana de microsegundos.
- Implementado en: 13d5cc2 (fix) + e941e23 (test)
- **Nota de validación:** el fix se implementó y se cubrió con un test nuevo de refresh concurrente (`auth.test.ts`), pero no se pudo correr la suite de Jest en esta sesión — `mongodb-memory-server` sigue bloqueado por el proxy (`fastdl.mongodb.org` → 403 de policy denial, confirmado también desde este entorno, no solo desde móvil como se documentó antes en este archivo). `npm run typecheck` y `npm run lint` sí pasan limpio sobre el cambio. La validación real de comportamiento (incluida la de concurrencia) queda en manos de CI al abrir el PR — ver `docs/NEXT_SESSION_MAC.md`, que ya señalaba TD-050 como el caso de uso típico de "necesita MongoDB real".

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
- **Confirmado de nuevo (2026-08-16, ronda de scan auth):** `npm ci` sí funciona; lo que falla es la descarga del binario (`https://fastdl.mongodb.org/...` → `CONNECT tunnel failed, response 403`). No hay `mongod` local instalado como alternativa. Consecuencia práctica para sesiones móviles: **un fix cuyo riesgo principal es de comportamiento en runtime (no de tipos) no se puede validar localmente** — solo `npm run typecheck` y `npm run lint`. Esto acota qué fixes es razonable intentar desde móvil con presupuesto de 1 iteración de CI: cambios deterministas y de superficie pequeña sí; cambios sensibles a timing o concurrencia (p. ej. TD-050) conviene dejarlos para una sesión con MongoDB real. Workaround parcial útil: extraer la lógica pura a una función y verificarla con un script `node` suelto (se hizo así con el predicado `skip` del rate limiter global en esta ronda).

### Scan de seguridad backend auth (2026-08-16)

- **Hallazgo principal arreglado:** el limitador global (TD-006) eximía todo el prefijo `/api/auth` asumiendo que esos endpoints ya tenían su propio limitador — cierto solo para `/register` y `/login`. `/refresh` y `/logout` no tenían ninguno, así que la exención los dejaba como **las únicas rutas totalmente sin límite de toda la API**. Lección: una exención escrita por prefijo envejece mal cuando se añaden rutas nuevas bajo ese prefijo; conviene enumerar explícitamente lo que se exime (lista `OWN_LIMITER_PREFIXES`) en vez de confiar en que el prefijo entero comparta la misma propiedad.
- **Lección de proceso:** varios hallazgos Medium (TD-051, TD-052, TD-053) son de tipo "la protección existe pero vive en un default de una dependencia o en una convención, no en una aserción explícita del código". No son bugs hoy y por eso no se arreglaron en una ronda de scope cerrado, pero son exactamente los que se rompen en silencio en un bump de major.
- **Fix no aplicado a propósito (TD-050):** ver la entrada en `docs/TECH_DEBT.md`. Requiere relitigar una decisión de seguridad deliberada (TD-022) y rompería un test existente que la codifica; se documentó con el fix candidato en vez de implementarlo unilateralmente.

### Fixes TD-051, TD-052, TD-053 (2026-08-17)

**Problema:** Protecciones de seguridad dependían de defaults de dependencias externas (jsonwebtoken, comparación de secrets, timing de bcrypt). Riesgo de pérdida silenciosa de protección en major bumps.

**Solución:** Configuraciones hechas explícitas en código:
- TD-051: JWT algorithm explícito en `sign()` (`{ algorithm: 'HS256' }`) y `verify()` (`{ algorithms: ['HS256'] }`) en `utils/jwt.ts`, para las cuatro funciones (access + refresh, sign + verify).
- TD-052: `validateProductionEnv` (`utils/env.ts`) ahora rechaza `JWT_SECRET === JWT_REFRESH_SECRET` en producción, además del chequeo de longitud mínima ya existente.
- TD-053: `login` (`auth.service.ts`) compara contra un hash bcrypt fijo (`DUMMY_PASSWORD_HASH`, calculado una vez al cargar el módulo) cuando el email no existe, para que ambas ramas paguen el mismo coste de `bcrypt.compare` (~80-100ms) y la latencia deje de ser un oráculo de enumeración de cuentas.

**Nota sobre TD-053 (descripción genérica de la tarea vs. registro real):** la tarea que disparó esta ronda describía TD-053 genéricamente como "protección en default de bcrypt (salt rounds/versión)" — eso ya estaba resuelto de antes (`BCRYPT_ROUNDS = 10` como constante explícita en `auth.service.ts` desde antes de esta ronda). El TD-053 real registrado en `docs/TECH_DEBT.md` es distinto: un side-channel de timing en `login` que permite enumeración de cuentas. Se implementó el fix correcto (el que dice el registro), no el que la descripción genérica de la tarea sugería. Misma discrepancia para TD-052: la tarea lo describía como "comparación timing-safe de secrets", pero el TD-052 real es sobre `JWT_SECRET !== JWT_REFRESH_SECRET`. Lección: cuando una tarea da una descripción genérica de un TD y también apunta a `docs/TECH_DEBT.md` como fuente de contexto completo, el registro manda sobre el resumen.

**Archivos modificados:**
- `backend/src/utils/jwt.ts` (TD-051)
- `backend/src/utils/env.ts` (TD-052)
- `backend/src/services/auth.service.ts` (TD-053)
- Tests añadidos en `backend/src/tests/auth.test.ts` (TD-051 ×2, TD-053) y `backend/src/tests/env.test.ts` (TD-052), más el ajuste del test preexistente "everything valid" para usar dos secrets distintos (ya no puede compartir el mismo `VALID_SECRET` para ambos, o dispara el chequeo nuevo).

**Validación:** de nuevo, `mongodb-memory-server` bloqueado en este entorno (ver más arriba) — no se pudo correr la suite de Jest completa. Se verificó la lógica pura de TD-051/TD-052 (sin BD) con un script `ts-node` suelto ejecutando `signAccessToken`/`verifyAccessToken`/`verifyRefreshToken` y `validateProductionEnv` directamente, y la de TD-053 comparando el tiempo de un `bcrypt.compare` contra el hash dummy frente a uno real (~80ms ambos). `npm run typecheck` y `npm run lint` pasan limpio. Validación de comportamiento vía HTTP (los tests de Supertest nuevos) queda en manos de CI.

**Decisión del dueño:** priorizar prevención de bugs silenciosos en futuras actualizaciones de dependencias.

---

## Ronda 2 Escaneo Frontend: State Management (2026-08-17)

**Scope:** auditoría exhaustiva de los 7 Cubits (`auth`, `household`, `task`, `shopping`, `socket`, `pet`, `stats`), sus repositories, `ApiService`, `CacheService`, `ConnectivityService`, `SocketService`, el composition root (`app.dart`/`main.dart`) y las páginas que orquestan carga de datos. Solo identificación y documentación — **no se tocó código de producción** en esta ronda.

**Método y su límite:** revisión de código, no ejecución. Este entorno no tiene toolchain de Flutter (`flutter: command not found`), así que ningún hallazgo se reprodujo en runtime ni se escribió un test que falle para demostrarlo. Cada uno se sostiene sobre la lectura del flujo de datos y está descrito con el escenario concreto que lo dispara, para que sea falsable por quien lo verifique con toolchain. La ronda 1 (backend auth) tuvo la misma limitación por otra causa (proxy bloqueando `mongodb-memory-server`) — ver la sección "Bloqueo de npm test desde móvil".

### Tabla de hallazgos

| # | Categoría | Descripción | Archivo | Sev. | Prio. | Fix propuesto |
|---|-----------|-------------|---------|------|-------|---------------|
| F1 | Error handling / Arquitectura | Expiración de sesión emite `unauthenticated` pero ningún widget montado lo escucha (solo `SplashPage`, ya desmontada) → el usuario se queda en el shell sin tokens | `auth_cubit.dart:104`, `app.dart:81`, `splash_page.dart:46` | **High** | **High** | `BlocListener` global en `app.dart` + navegación vía `Routes.navigatorKey` → **TD-055** |
| F2 | Race / consistencia de estado | `TaskState.timelineCursor` se pone a null en casi todos los `emit` (solo 2 de ~18 lo re-pasan) → la timeline PDR-003 nunca pagina dentro de su ventana | `task_cubit.dart:267` + call sites | **High** | **High** | Sentinel `clearTimelineCursor` estilo `clearError` → **TD-056** |
| F3 | Caché/sync (pérdida de datos) | `idRemap` es local a cada llamada de `syncPendingOperations`; si el create sincroniza y un op posterior corta por red, el update/delete queda apuntando al `local-<uuid>` → 404 → 3 reintentos → descartado | `task_repository.dart:354` (idéntico en `shopping_repository.dart`) | **High** | **High** | Persistir el remap reescribiendo los ops encolados → **TD-057** |
| F4 | Arquitectura / privacidad | Task/Shopping/Pet/Stats cubits conservan los datos de la cuenta anterior tras logout (solo `HouseholdCubit` tiene `reset()`) | `profile_page.dart:240-242` | **High** | **High** | `reset()` en los 4 cubits, llamado desde el listener global de F1 → **TD-058** |
| F5 | Caché/sync | `_wasOnline = true` asume que la app arranca online; si arranca sin red y `connectivity_plus` no reemite el estado actual al suscribirse, el primer `true` de reconexión no dispara `syncPending()` | `task_cubit.dart:328`, `shopping_cubit.dart:123` | Medium | Medium | Sembrar `_wasOnline` desde `await checkConnectivity()` en el constructor |
| F6 | Socket/realtime | `SocketService.connect()` crea un socket NUEVO, pero `_bindListeners()` está guardado por `_listenersBound`, que solo se limpia en `disconnect()` → un segundo `connectAndListen()` sin `disconnect()` deja un socket conectado y unido a la sala pero **sin listeners de dominio** (`onConnect`/`onDisconnect` sí se rebindean, así que la UI muestra "conectado" mientras el realtime está muerto) | `socket_cubit.dart:20,48-59`, `socket_service.dart:19-39` | Medium | Medium | Bindear dentro de `connect()`, o resetear `_listenersBound` en `connectAndListen()`. **Hoy es latente** (todo re-login pasa por `profile_page._logout`, que sí llama `disconnect()`) — pero arreglar F1/TD-055 lo vuelve alcanzable si el fix no desconecta también |
| F7 | Error handling | Misma raíz que F2: `clearOfflineNotice()` (y cualquier `emit` que no los re-pase) borra `timelineError`, `recurringError` y `trashError` → un error visible en Papelera/Recurrentes desaparece al consumir un aviso offline no relacionado | `task_cubit.dart:273,278,283,366` | Medium | Medium | Mismo sentinel de F2 |
| F8 | Race condition | `syncPending()` no tiene guard de reentrada; un parpadeo de conectividad (o un retry manual solapado con el automático) puede lanzar dos replays concurrentes sobre la misma cola Hive. Los creates están protegidos por el `Idempotency-Key` persistido; updates/deletes no. Además el primer `finally` apaga el spinner del segundo run | `task_cubit.dart:352`, `shopping_cubit.dart:146` | Medium | Medium | `bool _syncing` con early-return |
| F9 | Race condition | `load()`/`setFilter()`/`refresh()` no descartan respuestas obsoletas. `MainScaffold` dispara `load` + `catchUpRecurringTasks`(→`load`) en paralelo, y `tasks:batch_created` añade un `refresh()` — dos `load` concurrentes con distinto filtro escriben ambos `activeFilter`, y el más lento gana, pudiendo devolver al usuario a una pestaña que ya abandonó | `task_cubit.dart:379`, `main_scaffold.dart:60-83` | Medium | Medium | Contador de generación de request; descartar respuestas de una generación vieja |
| F10 | Test gap | Cero cobertura para `SocketCubit`, `HouseholdCubit` y `StatsCubit` — exactamente donde viven F1, F6 y F9 | `test/` | Medium | Medium | Añadir `socket_cubit_test.dart`, `household_cubit_test.dart`, `stats_cubit_test.dart` |
| F11 | Test gap | El test de paginación de timeline pasa porque llama `loadTimeline()` y `loadMoreTimeline()` seguidos, sin ningún `emit` intermedio — justo la condición que oculta F2 | `test/task_cubit_test.dart:685` | Medium | Medium | Interponer un `_upsert`/`loadRecurringTasks` en el test |
| F12 | Complejidad / perf | `HouseholdCubit.applyRealtime` hace un GET completo del hogar **y** un `setCurrentHouseholdId` (escritura a disco) por cada evento de miembro | `household_cubit.dart:124-130` | Low | Medium | Aplicar el payload del evento en vez de refetch; no reescribir el id persistido si no cambió |
| F13 | Error handling | `catchUpRecurringTasks` usa `catch (_)` sin log: un fallo real (JSON inesperado, bug de parseo) es invisible, no solo el fallo de red que justifica el swallow | `task_cubit.dart:564` | Low | Low | Dejar el swallow pero añadir un breadcrumb de Sentry |
| F14 | Arquitectura | `MainScaffold._loadForHousehold` orquesta 6 llamadas a cubits desde la capa de widgets | `main_scaffold.dart:60-83` | Low | Low | Aceptable para un shell; anotado, no accionable hoy |

### Análisis por Cubit

- **AuthCubit** — *Responsabilidad:* sesión, login/register/logout, perfil. *Correcto:* breadcrumbs sin PII; `logout()` ordena bien las operaciones (unregister del token FCM **antes** de borrar el access token, wipe de caché documentado). *Problemas:* F1 (el `onSessionExpired` que emite al vacío), F4 (no coordina el reset de los demás cubits). *Recomendación:* que `logout()` y `onSessionExpired` converjan en un único camino de teardown en vez de que `profile_page` haga el suyo a mano.
- **TaskCubit** — *Responsabilidad:* buckets por filtro, timeline PDR-003, recurrentes, papelera, cola offline. Es con diferencia el más grande (≈1000 líneas, 24 campos de estado) y el que concentra F2, F7, F8, F9, F13. *Correcto:* `TaskBucket` por filtro con cursor independiente (bien razonado), `_adjustedTotal` con semántica null correcta, disciplina de re-pasar `TaskBucket.nextCursor` en todos los sitios. *Recomendación:* la misma disciplina que se aplicó a `TaskBucket.nextCursor` falta en `TaskState.timelineCursor` — en vez de replicarla a mano, cambiar el patrón a sentinel (F2). Es candidato razonable a dividirse (timeline/papelera/recurrentes son casi tres cubits dentro de uno), pero eso es refactor grande, fuera del alcance de esta ronda.
- **ShoppingCubit** — *Responsabilidad:* lista única paginada + cola offline. *Correcto:* re-pasa `nextCursor` en `_upsert`/`_remove` (justo lo que falta en la timeline de TaskCubit). *Problemas:* F5, F8; además los handlers `on Failure` (p. ej. `createItem`) no re-pasan `nextCursor`, así que un fallo de creación rompe la paginación — misma clase que F2, menor impacto.
- **SocketCubit** — *Responsabilidad:* puente socket→cubits. *Problemas:* F6, y cero tests (F10). *Correcto:* rejoin de sala en `onConnect`, guard de idempotencia bien intencionado. *Recomendación:* es el único cubit sin cobertura que además tiene estado propio (`_listenersBound`) cuyo ciclo de vida no es obvio — prioritario para tests.
- **HouseholdCubit** — *Responsabilidad:* hogar activo y miembros. *Correcto:* es el único con `reset()`. *Problemas:* F12, sin tests (F10).
- **PetCubit** — *Responsabilidad:* mascota, adopción, economía. *Correcto:* `actionInProgress` previene doble-submit (el guard que a `TaskCubit.load` le falta, F9); guard de hogar en `applyRealtime`; independencia de `AuthCubit` bien argumentada. *Problemas:* F4 (sin `reset()`); recarga completa (2 requests) por cada evento realtime — documentado como deliberado, se deja como nota.
- **StatsCubit** — *Responsabilidad:* stats de hogar (PDR-007). El más simple y limpio; usa el patrón `clearError` que F2/F7 recomiendan generalizar. *Problemas:* F4, sin tests (F10).

### Patrones correctos encontrados

Vale la pena registrarlos porque son la referencia contra la que se miden los hallazgos:

- **Ciclo de vida de widgets impecable:** todos los `StatefulWidget` revisados liberan lo suyo — `TextEditingController`s, `ScrollController`s (incluida la lista completa en `tasks_page.dart`), `TabController`, y el `Timer.periodic` de `_LiveCareStats` con guard `mounted`. **No se encontró ni un solo memory leak de widget**, que era una de las hipótesis principales del encargo.
- **`TaskCubit`/`ShoppingCubit` cancelan su `StreamSubscription` de conectividad en `close()`** — el override de `close()` está bien hecho en ambos.
- **`CacheService.pendingOperationsCount`** es un broadcast stream cacheado con `onListen`/`onCancel` que monta y desmonta el `box.watch()` correctamente, con el tradeoff de replay documentado.
- **Single-flight de refresh en `ApiService`** (`_refreshCompleter`): correcto — el check-and-set no tiene `await` entre medias, así que es atómico en el modelo monohilo de Dart, y `Idempotency-Key` viaja en `RequestOptions` de modo que el retry tras 401 reusa la misma clave (esto es lo que hace el reintento seguro).
- **`Idempotency-Key` persistido junto a la operación encolada** — sobrevive a reinicios de app, no solo a reintentos en memoria. Es más de lo que suele hacerse.
- **`CacheService.saveTasks` preserva entradas no sincronizadas** al reemplazar, con el razonamiento escrito en el propio comentario.
- **Guard de hogar en los cuatro `applyRealtime`** — un evento de otro hogar nunca contamina el estado cargado.
- **Distinción `NetworkFailure` vs. 4xx real** en `_mapDioError`: es lo que permite que "cae a caché / encola" no se dispare ante un rechazo legítimo del servidor.

### Lecciones aprendidas

1. **El patrón "campo nullable de asignación incondicional" en `copyWith` no escala.** Funciona para one-shots genuinos (`error`, `offlineNotice`: se consumen y se van), pero aplicarlo a estado que debe persistir (`timelineCursor`) convierte cada `emit` no relacionado en un borrado silencioso. El proyecto ya tiene el patrón correcto para esto — el sentinel `clearError` de `AuthState`/`HouseholdState`/`StatsState` — solo que no se usó en `TaskState`. F2 y F7 son la misma raíz.
2. **Los tests que ejercitan una secuencia apretada esconden bugs de interleaving.** El test de F11 llama a las dos funciones seguidas; la app real intercala media docena de emits entre ellas. Para cubits con estado compartido, un test debería reproducir el orden real de `MainScaffold`, no el mínimo.
3. **La ronda 1 (backend) encontró sobre todo protecciones implícitas; la ronda 2 encuentra sobre todo estado compartido mal delimitado.** Son dos fallos distintos del mismo tipo: algo correcto por convención en vez de por construcción.
4. **La hipótesis de partida del encargo (memory leaks, cubits sin `close()`) resultó infundada** — esa parte del código está bien. El riesgo real estaba en consistencia de estado y en el ciclo de vida de la *sesión*, no en el de los widgets. Vale la pena anotarlo: el escaneo confirmó salud donde se sospechaba y encontró problemas donde no se buscaba.

### Próximos pasos recomendados (ordenados)

1. **TD-055 + TD-058 juntos** — comparten el fix (un listener global de `unauthenticated` que desconecta el socket y resetea los cubits). Hacerlos por separado significa tocar `app.dart` dos veces, y arreglar TD-055 sin TD-058 deja al usuario B viendo datos de A al aterrizar en login→main.
2. **TD-056 + F7** — misma raíz, un solo cambio de patrón en `TaskState.copyWith` los cierra ambos.
3. **TD-057** — el de mayor impacto real por usuario (pérdida silenciosa de una escritura offline), pero también el que más requiere tests con toolchain para validar; conviene hacerlo en una sesión que pueda correr `flutter test`.
4. **F6 antes o junto con TD-055** — es la trampa que TD-055 arma si se arregla sin mirarla.
5. **F10 (tests de Socket/Household/Stats cubits)** — habilita verificar los anteriores.
6. F5, F8, F9, F12, F13 — mejoras de robustez sin urgencia.

### Fix TD-055 + TD-058: ciclo de vida de sesión (2026-08-17)

**Problema:** `AuthCubit` emitía `unauthenticated` pero ningún widget montado lo escuchaba fuera de `SplashPage`, ya desmontada tras el arranque (TD-055). Los cubits de dominio (Task/Shopping/Pet/Stats) conservaban los datos de la cuenta anterior en memoria tras logout — solo `HouseholdCubit` tenía `reset()` (TD-058).

**Patrón elegido:** un widget dedicado, `SessionListeners` (nuevo archivo `presentation/widgets/session_listeners.dart`), envolviendo `MaterialApp` en `app.dart` — reemplaza el `BlocListener` de un solo propósito (push notifications) que ya vivía ahí por un `MultiBlocListener` con dos listeners sobre `AuthCubit`. Se descartaron las otras dos opciones que planteaba la tarea original:
- **Inyectar los cubits de dominio en AuthCubit:** roto por el orden de construcción — `app.dart` crea `AuthCubit` ANTES que `TaskCubit`/`ShoppingCubit`/`HouseholdCubit`/`PetCubit`/`StatsCubit` (y `SocketCubit`, que ya depende de los cuatro primeros, se crea el último). Invertir ese orden para poder inyectarlos habría sido un cambio de arquitectura mayor de lo que TD-055/058 pedían.
- **Un evento de dominio separado:** el proyecto ya tiene un patrón establecido para "una página coordina varios cubits vía `context.read`" (`SplashPage`/`LoginPage` ya hacen `HouseholdCubit.init()` + `SocketCubit.connectAndListen()` tras `authenticated`) — un widget-listener a nivel de app es la extensión natural de ese mismo patrón para `unauthenticated`, no una abstracción nueva.

Extraerlo a su propio widget (en vez de dejarlo inline en `app.dart`, que habría sido más rápido) tiene una razón concreta: permite un test que ejercita la lógica real contra cubits falsos, sin levantar los repositorios/red/almacenamiento reales de `HomeSyncApp` — `app.dart` no admite inyección de dependencias, así que probarlo inline habría significado o bien no probarlo con fakes, o duplicar la lógica del listener en el test (con riesgo de que diverja del real).

**Cambios:**
- `frontend/lib/presentation/widgets/session_listeners.dart` (nuevo): `SessionListeners`, con los dos `BlocListener<AuthCubit, AuthState>` (push registration en `authenticated`; desconexión de socket + reset de los 5 cubits de dominio + navegación a login en la transición A `unauthenticated`).
- `frontend/lib/app.dart`: usa `SessionListeners` en vez del `BlocListener` inline.
- `frontend/lib/presentation/cubit/{task,shopping,pet,stats}_cubit.dart`: método `reset()` nuevo en cada uno (`household_cubit.dart` ya lo tenía; se le añadió un comentario cruzado).
- `frontend/lib/presentation/pages/splash_page.dart`: su listener local se acota a `authenticated` — el caso `unauthenticated` ahora lo cubre el listener global.
- `frontend/lib/presentation/pages/profile_page.dart`: `_logout()` simplificado a una sola llamada a `AuthCubit.logout()` — ya no hace a mano el `SocketCubit.disconnect()` + `HouseholdCubit.reset()` + navegación que antes solo cubría un cubit de los cinco.
- Tests: `test/widgets/session_listeners_test.dart` (nuevo, 3 tests — expiración de sesión, logout con reset+desconexión, "cuenta nueva no hereda datos"), más tests unitarios de `reset()` en `task_cubit_test.dart` (×2), `shopping_cubit_test.dart`, `pet_cubit_test.dart` (×2).

**Efecto colateral (bueno) sobre F6:** el hallazgo F6 de la ronda 2 ("un segundo `connectAndListen()` sin `disconnect()` de por medio deja un socket sin listeners de dominio") queda mitigado de facto — antes solo `ProfilePage._logout` llamaba `SocketCubit.disconnect()`; ahora TODA transición a `unauthenticated` (incluida la expiración de sesión, que antes no desconectaba nada) pasa por `disconnect()`, así que el próximo `connectAndListen()` siempre parte de `_listenersBound = false`. F6 no se cerró formalmente (no tenía TD propio) pero su escenario de disparo más probable ya no ocurre.

**Fricción de testing encontrada (documentada como lección, no como TD):** `test/widgets/session_listeners_test.dart` inicialmente colgaba de forma determinista (~33s, mismo punto exacto cada vez) al llamar `await authCubit.logout()` dentro de un `testWidgets` con el árbol de widgets ya montado. Causa raíz: `logout()` hace una llamada Dio real (stubbed a nivel HTTP, pero sigue siendo E/S async real), y `testWidgets` ejecuta el cuerpo del test bajo el reloj fake de `AutomatedTestWidgetsFlutterBinding` — I/O real ahí puede colgarse indefinidamente porque nada avanza el reloj salvo `tester.pump()`. `auth_cubit_test.dart` ya evita este problema usando `test()` en vez de `testWidgets()` para su test de logout, pero esta ronda SÍ necesitaba un árbol de widgets montado (para observar la navegación). Fix: `tester.runAsync(() => authCubit.logout())`, que sale temporalmente de la zona fake-async. Efecto secundario del propio fix: `tester.runAsync` expuso un `MissingPluginException` de `connectivity_plus` (la suscripción que `TaskCubit`/`ShoppingCubit` hacen en su constructor a `ConnectivityService()`, normalmente absorbida por el `runZonedGuarded` de `ConnectivityService` sin que el test lo note) — resuelto pasando `connectivity: FakeConnectivityService()` a esos cubits en los tests que usan `runAsync`. Ninguno de los dos problemas apareció al correr los cubits aislados en `test()` puro (como ya hacían `task_cubit_test.dart`/`shopping_cubit_test.dart`), solo en la combinación `testWidgets` + `runAsync` + logout real que esta ronda introdujo por primera vez.

**Validación:** a diferencia de las rondas de backend, esta sí se pudo ejecutar completa — se descargó Flutter 3.44.9 (la versión que fija CI, ver TD-041) en este entorno y se corrieron `flutter analyze` (limpio, solo los `info` preexistentes) y la suite completa de 224 tests (excluyendo `offline_banner_test.dart`, igual que CI por TD-040), todos en verde.

### Fix TD-056: copyWith de TaskState, cierra también F7 (2026-08-17)

**Problema:** `TaskState.copyWith` asignaba incondicionalmente los campos nullable no pasados explícitamente, así que cualquier `emit` que cambiara UN campo (p. ej. `isSyncing`) borraba silenciosamente todos los demás — `timelineCursor` sobrevivía solo 2 de ~18 emits (TD-056). `clearOfflineNotice()`, que solo debía limpiar `offlineNotice`, se llevaba por delante `timelineError`/`recurringError`/`trashError` por el mismo bug (F7).

**Patrón elegido:** réplica exacta del `clearError` que `StatsCubit`/`HouseholdCubit`/`AuthCubit` ya usaban — un bool `clearX` por campo (default `false`), y el campo pasa de `x,` (incondicional) a `clearX ? null : (x ?? this.x)`. Se aplicó a los 5 campos "sticky" que lo necesitaban: `error`, `timelineCursor`, `timelineError`, `recurringError`, `trashError`. `offlineNotice` se dejó **intencionalmente sin tocar** — es genuinamente one-shot por diseño (así lo documenta su propio comentario), y con el resto de campos ya arreglados, `clearOfflineNotice()` se simplifica a `emit(state.copyWith())` sin argumentos: limpia offlineNotice (el único campo incondicional que queda) y no toca nada más.

**El matiz que casi se pasa por alto:** `timelineCursor` (y los demás) no son simplemente "opcional vs. sticky" — a veces el valor NUEVO es legítimamente `null` (el servidor dice "no hay más páginas") y eso SÍ debe sobrescribir, no preservarse como si no se hubiera especificado. `loadTimeline`/`loadMoreTimeline` ahora pasan `clearTimelineCursor: result.nextCursor == null` junto a `timelineCursor: result.nextCursor` para distinguir ambos casos. Es la misma ambigüedad que `TaskBucket.nextCursor` ya resuelve por convención (cada call site lo re-pasa siempre) — se dejó `TaskBucket` sin tocar, fuera del alcance literal de TD-056.

**F11 (test que ocultaba el bug):** el test de `loadMoreTimeline` llamaba `loadTimeline()` y `loadMoreTimeline()` seguidos, sin ningún emit intermedio — exactamente la condición que ocultaba TD-056. Se añadió una llamada a `clearOfflineNotice()` entre ambos (una acción de cubit real, no un `emit()` fabricado) con aserción de que el cursor sobrevive, más un comentario explicando por qué.

**Archivos modificados:**
- `frontend/lib/presentation/cubit/task_cubit.dart`: `copyWith` (5 flags `clearX` nuevos), `clearOfflineNotice()`, y los 4 call sites que antes pasaban `campo: null` para limpiar al empezar una operación (`load`, `loadTimeline`, `loadRecurringTasks`, `loadTrashTasks`) ahora usan su `clearX: true`.
- `frontend/test/task_cubit_test.dart`: test de `loadMoreTimeline` reforzado (F11); 3 tests nuevos de `TaskState.copyWith` (preserva todo salvo `offlineNotice`; cada `clearX` limpia solo lo suyo; un valor nuevo sobrescribe pase lo que pase el flag); 1 test nuevo de `clearOfflineNotice` confirmando que no toca `error`/`timelineCursor`/`timelineError`/`recurringError`/`trashError`.

**Decisión del dueño:** fix inmediato por ser el más sutil de los 4 High y cerrar F7 de paso.

**Lección (ya la señalaba el propio escaneo):** un test genérico "`copyWith()` sin argumentos no pierde nada" habría detectado esta clase de bug antes de que llegara a producción. Se añadió para `TaskState` en esta ronda; **no** se replicó en los otros 6 cubits (fuera de alcance de esta tarea, ver "Deuda técnica NO tocada" abajo) — el mismo patrón de auditoría podría aplicarse a cualquiera que use `copyWith` con campos nullable de asignación incondicional.

**Deuda técnica NO tocada, a propósito:** el escaneo de la ronda 2 (F2) señaló que el mismo patrón de bug podría existir en otros cubits, y las restricciones de esta tarea decían explícitamente no arreglarlos aquí — solo documentar. Verificación de `Shopping/Pet/Stats/Household/Auth/Socket`Cubit al escribir este fix:
- **`ShoppingCubit` tiene el mismo bug que F7, hoy, en producción.** `ShoppingState.copyWith` asigna `error` y `nextCursor` incondicionalmente (igual que `TaskState` antes de este fix). `ShoppingCubit.clearOfflineNotice()` es literalmente `emit(state.copyWith(error: state.error))` — el mismo patrón que tenía `TaskCubit.clearOfflineNotice()` antes de F7 — así que cada vez que se descarta el aviso "guardado offline" en la lista de compras, `nextCursor` se pierde silenciosamente. Efecto práctico: `loadMore()`'s guard (`state.nextCursor == null` → no-op) deja de poder paginar hasta el próximo `load()` completo, aunque `hasMore` siga en `true`. Además, los `on Failure` de `createItem`/`updateItem`/`togglePurchased`/`deleteItem` tampoco re-pasan `nextCursor` en su `emit(state.copyWith(error: f.message))`, así que un fallo de mutación rompe la paginación igual. Candidato directo a un fix idéntico al de esta ronda (mismo `clearError`/`clearNextCursor` sentinel), pero fuera de alcance aquí.
- `Pet`/`Stats`/`Household`/`AuthState` ya usan el patrón `clearError` correcto — no tienen este problema.
- `SocketCubit` no tiene un estado tipo `TaskState`/`ShoppingState` (su estado es un `bool`) — no aplica.

No se abrió ningún TD nuevo por el hallazgo de `ShoppingCubit` — queda documentado aquí como el candidato más concreto para la próxima ronda que toque cubits, ya con el patrón de fix probado en esta.

---

## Próximas mejoras pendientes

- **IMPROVEMENTS.md mismo:** documentar decisiones de PDR faltantes (002, 003, 005) cuando se creen.
- **README.md update:** añadir mascota, papelera, Sentry, --dart-define, infra EU (pendiente).
- **backend/README.md:** falta por crear (setup + patrón controller/service/model).
- **CLAUDE.md, lista corta "Currently open TDs":** TD-002 y TD-015 llevan verificados como Resolved en `docs/TECH_DEBT.md` desde 2026-08-16 (código ya implementado antes de esa verificación) pero la lista corta espejo en CLAUDE.md nunca se actualizó — quedaron fuera del alcance cerrado de esta ronda (solo TD-016/TD-006), pero es una limpieza de una línea pendiente para la próxima sesión que toque CLAUDE.md.

---

## Configuración pendiente

Acciones manuales/externas conocidas, no automatizables desde una sesión de agente — requieren acceso a cuentas, hardware o consolas de terceros.

- **TD-049 — Firebase, configuración manual (requiere Mac/Xcode) — actualizado 2026-08-16:**
  - ✅ `google-services.json` y `GoogleService-Info.plist` ya copiados localmente por el dueño a `android/app/` e `ios/Runner/` (gitignored, confirmado con ambos patrones ya presentes en `frontend/.gitignore` antes de esta ronda).
  - ✅ Plugin `com.google.gms.google-services` aplicado en Gradle: `classpath` en `android/build.gradle` (buildscript) + `apply plugin` al final de `android/app/build.gradle`.
  - ✅ `android/app/src/main/AndroidManifest.xml` ya tenía `POST_NOTIFICATIONS` (añadido en una ronda anterior de TD-049 no reflejada aquí).
  - ✅ `ios/Runner/Info.plist`: `UIBackgroundModes` con `fetch` + `remote-notification` añadido.
  - ⏳ **Pendiente manual en Xcode:** capability "Push Notifications" (esto genera `Runner.entitlements` con `aps-environment` y referencia `CODE_SIGN_ENTITLEMENTS` en el pbxproj automáticamente) + "Background Modes → Remote notifications" ya cubierto por el Info.plist de arriba pero conviene confirmarlo también en la UI de Signing & Capabilities. Deliberadamente no se editó `project.pbxproj` a mano para crear el entitlements file — el riesgo de un pbxproj malformado sin poder verificarlo fuera de Xcode superaba el ahorro de 2 clicks. Pasos: Xcode → Runner target → Signing & Capabilities → "+ Capability" → "Push Notifications".
  - ⏳ APNs key subida a Firebase Console (Project Settings → Cloud Messaging → APNs Authentication Key).
  - ✅ `FIREBASE_SERVICE_ACCOUNT` ya configurado en Railway (confirmado por el dueño, fuera de esta ronda).
  - ⏳ Ejecutar `flutterfire configure` (opcional si los config files ya están colocados a mano, como aquí).
  - ⏳ Test end-to-end en dispositivo físico (push no se puede validar en simulador/emulador).
- **Self-leave endpoint (gap identificado en TD-018, ronda 2026-08-16):** hoy solo un admin puede remover a otro miembro vía `removeMember` (`DELETE /households/:id/members/:userId`). No existe ningún endpoint de autoservicio para que un miembro normal salga voluntariamente del hogar por su cuenta. Candidato razonable para un TD nuevo si el producto lo necesita — la lógica de desasignación de tareas de TD-018 (`unassignDepartedMemberTasks`) ya está lista para reutilizarse desde ese endpoint el día que se cree.

---

## Roadmap futuro

Funcionalidad identificada pero fuera de alcance de las rondas que la mencionaron.

- **Deep-link a tarea específica desde push notification (PDR-008):** hoy tocar una notificación que abrió la app desde background (`onMessageOpenedApp`) solo navega al shell principal (pestaña de tareas) — no existe todavía una ruta de deep-link por tarea, así que no abre la tarea exacta.
- **Background/terminated message handling para push notifications (PDR-008):** hoy `NotificationService` solo maneja foreground (banner local vía `showLocalNotification`) y background→foreground vía tap (`onMessageOpenedApp`). Falta `onBackgroundMessage`/`getInitialMessage` para el caso de mensaje recibido con la app en background o terminada.
- **Recordatorios de tareas próximas vía push (PDR-003):** PDR-003 lo menciona como "futuro" — requiere lógica de scheduling server-side (hoy los recordatorios de `flutter_local_notifications` son solo locales, calculados client-side a partir de `dueDate`/`startsAt`, sin contraparte de push server-driven).

---

## 2026-08-17 — CI: validar que los docs enlazados por AGENTS.md existen

Propuesto por: Codex en PR #32.

Motivo: evitar referencias rotas en el contexto de agentes.

Estado: **Implementado (2026-08-17, PR #35)**. Job `docs` en `.github/workflows/ci.yml` ejecutando `scripts/check_docs.sh` (bash puro, sin dependencias), en todo PR y en push a `main`.

Alcance final, los tres checks:

1. **Enlaces:** todo `[texto](ruta.md)` de `AGENTS.md` debe resolver. Se validan enlaces markdown reales, no menciones en prosa — así `AGENTS.legacy.md`, citado en la nota de decisión y borrado a propósito, no se exige que exista, y la regla no necesita allowlist.
2. **Registro de TDs:** ningún TD de la tabla corta "Currently open TDs" de `CLAUDE.md` puede figurar como Resolved en `docs/TECH_DEBT.md`, y todos deben existir allí. Cubre la ampliación descrita abajo y el caso real de TD-002/TD-015.
3. **Bloques duplicados:** los ocho bloques envueltos en `<!-- sync-start: <slug> -->` / `<!-- sync-end: <slug> -->` deben ser idénticos byte a byte entre `AGENTS.md` y `CLAUDE.md`.

Ampliación (integración AGENTS.legacy.md → AGENTS.md, 2026-08-17): el mismo check cubre un segundo riesgo introducido por esa integración. Las secciones normativas (Hard Rules, convenciones de TypeScript/Dart, modelos de BD, Testing Standards, Git Workflow, seed data) quedaron duplicadas literalmente en `AGENTS.md` y `CLAUDE.md`, así que podían divergir sin que nada avisara. Resuelto por el check 3.

Decisión de diseño: marcadores HTML en vez de un diff por encabezados. Un diff posicional depende de que los encabezados no se renombren, no se re-aniden y no se muevan; cualquiera de esas tres cosas cambiaría en silencio qué se compara. Los marcadores son explícitos, invisibles en markdown renderizado, y convierten un marcador borrado por accidente en un fallo ruidoso en vez de en una comprobación que se salta sin avisar.

El job va fuera del filtro de rutas `changes` a propósito: la deriva que detecta la producen precisamente los cambios solo-docs, que es lo que ese filtro se salta. El coste es de segundos, así que no contradice TD-008.

Pendiente menor: el check 1 solo mira `AGENTS.md`. Extenderlo a los enlaces de `CLAUDE.md` (que apunta a `docs/ADRs.md`, entre otros) es una línea más de script, pero quedó fuera del alcance pedido.

---

## 2026-08-17 — Actualizar actions/checkout@v4 a Node 24

GitHub avisa en logs de CI que `actions/checkout@v4` corre sobre Node 20, pero ya han pasado a Node 24 por defecto. Afecta a los 5 jobs del workflow, hoy no rompe nada. Requiere actualizar las acciones y verificar que todo sigue funcionando. Prioridad baja.

Detectado en el run de CI del PR #35 (mensaje literal: "Node 20 is being deprecated. This workflow is running with Node 24 by default"). Afecta también a `actions/setup-node@v4`, `actions/setup-java@v4`, `actions/cache@v4`, `dorny/paths-filter@v3` y `subosito/flutter-action@v2`, no solo a `checkout`. Ojo al tocar el job `frontend`: TD-041 fija la versión de Flutter a propósito, así que la actualización de acciones no debe arrastrar cambios de pin.

---

## 2026-08-18 — Evaluar un mixin genérico para el andamiaje optimistic

Propuesto durante la implementación de TD-007.

Motivo: `TaskCubit` y `ShoppingCubit` llevan cada uno su propia copia de la superposición optimista (`pendingIds`, `_rollbackSnapshots`, `_optimisticApplied`, `_applyOptimistic`, `_confirmOptimistic`, `_rollbackOptimistic`, `_isSuperseded`, `_findById`, `_rollbackDelete`): ~90 líneas duplicadas con solo el tipo de entidad cambiando. Ambas copias llevan un comentario de cross-ref pidiendo mantenerlas sincronizadas, lo cual funciona hasta que alguien se olvida.

Estado: pendiente, prioridad baja. Se duplicó a propósito por decisión del dueño para no tocar los dos Cubits a la vez en mitad del round.

Ojo al evaluarlo, porque no es un copy-paste puro: las dos copias **difieren en el orden de los emits** del rollback. `ShoppingState.copyWith` asigna `error` de forma incondicional (cada emit lo limpia) mientras que `TaskState` lo preserva, así que en Shopping el error debe emitirse al final y en Task antes del `_upsert`. Un mixin ingenuo que ignore esa diferencia romperá el mensaje de error de uno de los dos, sin fallar la compilación. Homogeneizar primero el contrato de `copyWith` de ambos estados probablemente sea el paso previo, y por sí solo ya vale más que el mixin.

---

## 2026-08-18 — Verificar periódicamente la protección --assume-unchanged de pbxproj

Motivo: CLAUDE.md documenta que `project.pbxproj` es local-only y debe tener `--assume-unchanged`, pero la protección puede perderse sin que nadie se dé cuenta, dejando el Bundle ID personal a un `git add` de colarse en el repo.

Estado: pendiente. Cadencia sugerida: al inicio de cada sesión de Mac, `git ls-files -v | grep pbxproj` debe mostrar `h` minúscula.

Contexto: no es hipotético. Al configurar la firma iOS local se encontró la protección **efectivamente perdida** — `git ls-files -v` no devolvía ninguna `h` minúscula, contra lo que documenta CLAUDE.md — con el fichero en su valor compartido (`com.homesync.app`). Se restauró en esa misma sesión. No hay constancia de cuándo se perdió; la causa más probable es un `git update-index --no-assume-unchanged` temporal (el propio CLAUDE.md documenta ese procedimiento para cambios legítimos) que no se revirtió después.

Candidato natural a automatizarse dentro de `scripts/check_docs.sh`, que ya corre en cada PR: sería una comprobación más de coherencia entre lo que CLAUDE.md afirma y lo que el repo hace. Ojo, sin embargo, a que el flag es **estrictamente local** y no viaja en el repo, así que en CI la comprobación siempre fallaría; solo tiene sentido como script de uso manual o como hook local.

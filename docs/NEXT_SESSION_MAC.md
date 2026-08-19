# NEXT_SESSION_MAC

## Decisión activa

- Claude Code sigue siendo herramienta principal en Mac.
- OpenAI Codex es agente secundario:
  - Mac: Codex CLI, commits directos a main, push aprobado por el dueño.
  - Móvil/cloud: Codex app/web, rama + PR + CI + aprobación del dueño.
- gh CLI instalado y autenticado (Claude Code gestiona PRs y merges).
- Piloto Codex cerrado el 2026-08-17 con resultado positivo.

## Reglas de ejecución

- Un solo agente activo en el repo a la vez.
- El dueño no edita archivos: todo cambio va en prompts de agente.
- No tocar TDs abiertos sin instrucción explícita.
- Commits atómicos; push solo con aprobación del dueño.
- CI verde obligatorio para PRs (flujo móvil/cloud).

## Historial

- 2026-08-16: backlog grooming móvil; TD-002 y TD-015 Resolved.
- 2026-08-17: TD-040 (cuelgue de tests) y TD-059 (durabilidad Hive) cerrados; check documental en CI (PR #35).
- 2026-08-18: TD-007 parcialmente cerrado (updates y deletes optimistic); creates aplazados como TD-060.
- 2026-08-18: round TD-057 + TD-060 cerrado (cola offline sin pérdida de ids, creates optimistas); TD-061 abierto.
- 2026-08-18: TD-001 fases 0-1 — escritura dual desplegada y backfill aplicado en producción (5 hogares, 5 membresías, 0 divergencias).
- 2026-08-19: TD-061 cerrado (aviso al cerrar sesión con cola pendiente); TD-062 abierto. Acciones de CI a Node 24 (PR #36).
- 2026-08-19: TD-062 cerrado (marcador de propietario de la caché; otra cuenta ya no hereda la cola offline). Se abrió TD-063 (un fallo de red en el refresh se trata como sesión muerta).
- 2026-08-19: TD-063 cerrado (solo un 401 mata la sesión; una desconexión ya no expulsa al login ni pierde la escritura en vuelo). Check de enlaces de docs extendido a CLAUDE.md.
- 2026-08-17: PR #32 config fallback (Codex); PR #33 integración legacy
  (Claude); PR #34 sync (Codex, cerrado como superseded sin merge). Plan free de Codex activo y validado.
  gh instalado; Codex CLI instalado y autenticado.

## Pendientes arrastrados (grooming 2026-08-16)

- ~~TD-040: CI se cuelga en `offline_banner_test.dart`~~ — Resolved 2026-08-17 (ver "Fase 1" abajo).
- TD-010: verificar backups en el dashboard de MongoDB Atlas/Railway.
- Top-3 Mac (reordenado por PDR-009): ~~TD-059~~ (Resolved 2026-08-17), ~~TD-007~~ (parcial 2026-08-18) y TD-001 — el único que queda.

## Siguiente tarea

**1. TD-001 sigue en pausa activa de observación.** La fase 2 (lectura dual) se
desplegó el 2026-08-18 (commit `631031d`). Ventana de **48-72 h**: **NO
autorizar el cutover antes del 2026-08-21.**

- **Criterio:** cero divergencias en Sentry (categoría `td001_dual_read`) o en
  los logs de Railway (`dual-read divergence`).
- **Cierre de la ventana:** ejecutar
  `DELETE /households/6a84e3ff6f8391134ebe9dde/members/6a84e33d6f8391134ebe9dd0`
  —la muestra de escritura que quedó reservada— y hacer el grep de logs.
- **Una sola divergencia = investigar antes de seguir.** No es un umbral
  estadístico: significa que la escritura dual tiene un hueco, y el cutover
  haría autoridad a una colección incompleta.

El 2026-08-18 se generaron 30 lecturas household-scoped con
`scripts/td001-sample-traffic.ts` sobre un hogar dedicado ("Muestras TD-001"),
para que la ventana no dependa de que alguien abra la app.

**2. Nada abierto que compita con la ventana.** Cerrados TD-061, TD-062 y
TD-063, no queda ningún TD abierto que toque el ciclo de sesión. Lo que hay
son micro-pendientes, todos de bajo esfuerzo y ninguno bloqueante: homogeneizar
`copyWith` de Task/Shopping y evaluar el mixin del overlay optimista, el SPM de
`flutter_local_notifications`, `UIScene`, y las tres entradas nuevas de
IMPROVEMENTS del round de TD-062 (assert del marcador en
`syncPendingOperations`, y el test que falta de la rama cacheada de
`checkAuth`). Ver la lista en `docs/ROADMAP.md`.

**Pendiente de dispositivo (TD-062 y TD-063).** Se acumulan dos guiones que
solo se pueden ejercitar con red y cuentas reales:

- **TD-062:** arrancar en modo avión con datos cacheados y comprobar que
  **siguen ahí**; y expirar la sesión de A, entrar con B y comprobar que **no
  aparecen descartes en Sentry**. Guiones en `docs/TD-062-DESIGN.md` §6.
- **TD-063:** montaje recomendado, backend local con `JWT_ACCESS_EXPIRES=30s`
  (esperar 15 min por intento contra producción hace la prueba irrepetible).
  Los tres que importan: avión durante el refresh y **no** acabar en el login;
  servidor caído y que la tarea quede **encolada** en vez de revertida; y el
  control negativo —borrar la fila de `refreshtokens` en el Mongo local— que
  **sí** debe llevar al login. Sin el tercero, los otros dos podrían pasar
  simplemente porque la app dejó de cerrar sesión nunca. Guiones en
  `docs/TD-063-DESIGN.md` §6.

Después: fases 3 y 4 de TD-001 (cutover y limpieza).

### Fase 7 — cerrada (TD-063, 2026-08-19)

**Una desconexión ya no es una expiración.** `_refreshToken` devuelve tres
desenlaces —rotado, rechazado, inalcanzable— donde antes devolvía `String?`.
Ese tipo era el root cause, no el `catch (_)`: dos valores para tres
desenlaces, así que "no pude preguntar" se colapsaba contra "el servidor dijo
que no", y un ascensor o un deploy de Railway dejaban al usuario en el login.

Tres decisiones que sostienen el resto:

- **Solo un 401 mata la sesión**, por lista blanca. Sin respuesta, 5xx, 429,
  403 y un 2xx sin tokens (portal cautivo, que no lanza excepción alguna)
  conservan la sesión. El 403 cae del lado seguro porque el backend nunca lo
  devuelve en esa ruta: viene de un proxy o un WAF, no de nosotros.
- **No se reintenta**, y está escrito en el código por qué: la rotación no es
  idempotente, así que reintentar una llamada cuya respuesta no se vio dispara
  la detección de replay del backend, levanta una alerta en el canal del robo
  de tokens y revoca la familia. El reintento útil ya existe gratis — la
  siguiente petición trae su propio 401.
- **La escritura en vuelo también se salvó.** Era la mitad del daño que no
  estaba en la ficha del TD: el 401 propagado no es encolable, así que la tarea
  recién creada se revertía. Ahora el desenlace inalcanzable rechaza sin
  respuesta y la escritura toma el camino offline de ADR-010.

De paso se corrigió una afirmación falsa de CLAUDE.md: `/api/auth/refresh` y
`/api/auth/logout` **no** están exentos del limitador global; la exención solo
cubre `/register` y `/login`.

Cinco commits, suite de 312 a 323 tests. Ver `docs/TD-063-DESIGN.md`.

### Fase 6 — cerrada (TD-062, 2026-08-19)

**La caché ya no cambia de dueño en silencio.** Hive lleva ahora un marcador
`CacheOwner {userId, updatedAt}` en una box propia, y `AuthCubit` lo comprueba
en **toda** entrada a una sesión autenticada —`login`, `register` y las dos
ramas de `checkAuth`—: si no coincide con quien entra, o falta, vacía la caché
antes de reclamarla.

Tres decisiones que sostienen el resto:

- **Cuelga de la autenticación, no del logout ni de la expiración.** Es el
  único momento en que se sabe *quién* va a usar la caché. Limpiar al expirar
  habría destruido la cola del propio usuario cada vez que un refresh fallara
  por red (TD-063).
- **El orden es el arreglo**, igual que en TD-057: se limpia siempre ANTES de
  emitir `authenticated`, porque `SplashPage` carga el hogar desde ese estado y
  el listener de conectividad puede disparar un sync en cualquier momento.
- **Marcador ausente = limpiar.** Lo que no se puede demostrar de nadie tampoco
  es suyo. Cuesta una limpieza única por dispositivo al actualizar.

Queda fijada además la asimetría de producto: el logout explícito descarta la
cola (el usuario lo decidió con el recuento delante, TD-061) y la expiración la
conserva (no decidió nada). **Lo que decide no es el estado técnico, sino si
hubo alguien decidiendo.**

Cuatro commits, suite de 301 a 312 tests. Ver `docs/TD-062-DESIGN.md`.

### Fase 5 — cerrada (TD-061, 2026-08-19)

**Cerrar sesión con cambios sin sincronizar ya avisa.** El logout sigue
vaciándolo todo —la solución es avisar, no dejar de limpiar—, pero el diálogo
tiene ahora tres formas: sin cola, la de siempre; con cola y conexión, intenta
drenar con un tope de 5 s mostrando "Sincronizando N cambios pendientes…" y el
botón bloqueado; y con cola sin drenar, "Tienes N cambios sin sincronizar. Si
cierras sesión ahora, se perderán", con el botón renombrado a "Cerrar sesión y
descartar".

Tres decisiones que sostienen el resto:

- **El aviso aparece solo cuando hay algo que perder.** Uno que apareciera
  siempre se aprendería a ignorar.
- **Se descartó bloquear el logout** con cola pendiente: convertiría un
  problema de datos en uno de seguridad, porque el caso que motiva limpiar el
  dispositivo —perdido, compartido— es justo donde no puedes permitirte fallar.
- **Cancelar no aborta el drenaje en vuelo**, y si ya había una sincronización
  en curso se espera en vez de lanzar otra.

No hizo falta fontanería nueva: `pendingOperationsCountSync` ya existía y ya
alimentaba el badge del `OfflineBanner`.

Cuatro commits, suite de 290 a 301 tests. Ver `docs/TD-061-DESIGN.md`.

### TD-001 fases 0-1 — completadas (2026-08-18)

**Fase 0, escritura dual** (`047f078`, desplegada): las tres operaciones de
membresía escriben en ambos sitios. El array embebido sigue siendo la
autoridad, así que revertir el deploy no deja rastro. `removeMember` es
transaccional para mantener atómica la Hard Rule 9.

**Fase 1, backfill** ejecutado por el dueño en producción:

| Pasada | Hora | Escaneados | Vistos | A crear / creados | Ya presentes | Divergentes |
|---|---|---|---|---|---|---|
| DRY RUN | 21:10:14Z | 5 | 5 | 5 | 0 | 0 |
| **APPLIED** | 21:12:04Z | 5 | 5 | **5** | 0 | 0 |
| DRY RUN | 21:12:09Z | 5 | 5 | 0 | 5 | 0 |

La tercera pasada confirma la idempotencia y las tres confirman **cero
divergencias**: la escritura dual no tiene huecos.

**Sin verificar, y conviene saberlo:** la atomicidad de la Hard Rule 9 está
razonada, no medida. Se intentaron dos vías para demostrar la carrera
(peticiones concurrentes y el fail point de MongoDB) y ninguna consigue la
intercalación; quitar la transacción no rompería ningún test. Detalle completo
al final de `docs/TD-001-DESIGN.md`.

### Fase 4 — cerrada (TD-057 + TD-060, 2026-08-18)

**La cola offline ya no pierde ids, y los creates son optimistas.**

**TD-057** (High, el único de los dos que provocaba pérdida de datos real): una
edición o un borrado hechos offline desaparecían sin avisar cuando su create
sincronizaba en un lote anterior. `syncPendingOperations` reescribe ahora la
cola **antes** de retirar el create que produjo la traducción, así que esta
sobrevive a un `break` y a un reinicio. El orden es el fix: morir en cualquier
punto es seguro porque el create sigue encolado y la Idempotency-Key hace
idempotente el reintento.

Cubría **tres** salidas, no la única documentada: el `break` de red, el `break`
por fallo de escritura en caché que añadió TD-059, y la muerte del proceso —
esta última descartaba de raíz cualquier arreglo basado en memoria.

**TD-060:** `createTask`/`createItem` pintan la fila al instante con id
`pending-<uuid>` y la sustituyen por la real en **una sola emisión**, para que
no parpadee. Las acciones de deslizar quedan deshabilitadas mientras el create
está en vuelo: viven fuera del tile, y un swipe habría enviado un PATCH contra
un id que el servidor nunca vio.

Sin migración ni cambio de esquema en ninguno de los dos: mismo `typeId`,
mismos campos, mismo adapter.

**Dos limitaciones aceptadas, ambas documentadas en sus entradas:** una cola ya
envenenada por una versión anterior no se rescata (decisión D), y un create
optimista puede mostrar brevemente una fila duplicada porque el backend emite
`task:created` también a quien la creó (decisión A) — se resuelve sola al
confirmar.

Se abrió **TD-061**: el logout vacía la cola pendiente sin aviso (decisión C).

Ocho commits, suite de 279 a 290 tests. Ver `docs/TD-057-DESIGN.md`.

### Fase 3 — cerrada parcialmente (TD-007, 2026-08-18)

**Optimistic updates: updates y deletes hechos; creates aplazados.** Seis
mutaciones (`completeTask`, `updateTask`, `togglePurchased`, `updateItem`,
`deleteTask`, `deleteItem`) aplican el cambio a la UI antes de enviar la
petición, reconcilian con la entidad del servidor al confirmar y revierten si la
rechaza.

Tres decisiones que sostienen el resto:

- **Guarda de supersesión:** solo se revierte si la entidad sigue siendo
  idénticamente la que se aplicó. Restaurar sobre un valor más nuevo destruiría
  trabajo del usuario; perder un rollback solo deja la UI adelantada hasta el
  siguiente refresh.
- **Un fallo de red no es un rechazo:** el repositorio lo absorbe y devuelve la
  entidad encolada con `isSynced:false`, que es un éxito y no debe revertirse.
- **"En vuelo" no se persiste:** vive en `pendingIds` del Cubit. Una escritura
  en vuelo que llegara a Hive sería un fantasma que nadie reintentaría, porque
  no hay `PendingOperation` que la respalde — el fallo de TD-059 con los papeles
  cambiados.

Limitación aceptada (decisión C): `recurringTasks` y `trashTasks` no reciben la
superposición y quedan desincronizadas hasta recargar su pestaña.

Ocho commits, suite de 249 a 269 tests. Ver `docs/TD-007-DESIGN.md`.

### Fase 2 — cerrada (TD-059, 2026-08-17)

**Durabilidad de la caché Hive, completada en una sesión (el diseño estimaba
dos).** Los escritores de `CacheService` devuelven `Future<void>` y todos sus
call sites los esperan, bajo la política dual aprobada: los seis helpers
`_createOffline`/`_mutateOffline`/`_deleteOffline` **propagan** el fallo, y el
cacheo de datos que el servidor ya tiene es **best-effort con reporte a
Sentry**. Una escritura offline cuya operación encolada falla tras haber
guardado la entidad se revierte, así que el usuario nunca conserva una entidad
sin sincronizar que jamás podría sincronizarse. Un fallo local ya no se
disfraza de "guardado offline": muestra "No se pudo guardar en este
dispositivo".

Alcance real: **once** métodos, no seis — `saveTask` y `saveShoppingItem`
concentraban la mayoría de los call sites y quedarse en seis habría dejado el
trabajo inútil de cara a TD-007.

Hallazgo principal, ya protegido con tests: estos escritores **no deben tener
cuerpo `async`**. Hive aplica el `put`/`delete` a su keystore en memoria de
forma síncrona y devuelve el `Future` solo para el flush a disco, así que un
cuerpo `async` aplaza la escritura más allá de la siguiente lectura síncrona
del llamador — rompió 6 tests al escribirlo así. La forma correcta es invocar
las operaciones de forma síncrona y devolver `Future.wait`. Los seis hallazgos
completos están en `docs/TD-059-DESIGN.md`.

Diez commits, suite de 234 a 249 tests. Ver `docs/TECH_DEBT.md` y **PDR-009**.

### Fase 1 — cerrada (TD-040, 2026-08-17)

**Resultado A: la causa raíz era nuestra, no del toolchain.** El 4º test de
`offline_banner_test.dart` escribía en Hive (`Box.put()`, escritura real a
disco) dentro de la zona fake-async de `testWidgets`; el callback de
finalización queda agendado en el reloj falso, que deja de bombearse al
terminar el cuerpo del test, así que la escritura nunca completa y el lock de
la box no se libera — y el `clearAll()` del `tearDown` se queda esperándolo
para siempre. De ahí el 0% de CPU sin fallo de aserción.

Evidencia: una sonda con prints mostró el cuerpo completando (`count=1`) y
`tearDown: antes de clearAll` imprimiéndose, mientras `despues de clearAll` no
aparecía nunca; la misma sonda con la escritura envuelta en `tester.runAsync`
pasó con exit 0. Explica por qué solo este archivo se colgaba:
`cache_service_test.dart` golpea la misma box con las mismas escrituras pero
usa `test()` plano, sin zona fake-async. Refuta la lectura anterior de "stall
de host": la compilación ya había terminado, así que el 0% de CPU era el
deadlock esperando.

Cierre: fix de una línea en el test (`tester.runAsync`); los 6 tests pasan en
<1s y la suite completa (234 tests) en verde. `ci.yml` plegado — el paso
aislado con `continue-on-error` se eliminó, así que una regresión vuelve a
romper CI. De paso se corrigió un falso negativo de `scripts/check_docs.sh`,
que no reconocía un estado `**Resolved**` en negrita.

### Pendientes menores

- Extender el check de enlaces de docs a `CLAUDE.md` (enlaza `docs/ADRs.md`,
  entre otros). Hoy `scripts/check_docs.sh` solo valida los de `AGENTS.md`.

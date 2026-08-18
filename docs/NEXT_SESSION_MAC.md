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
- 2026-08-17: PR #32 config fallback (Codex); PR #33 integración legacy
  (Claude); PR #34 sync (Codex, cerrado como superseded sin merge). Plan free de Codex activo y validado.
  gh instalado; Codex CLI instalado y autenticado.

## Pendientes arrastrados (grooming 2026-08-16)

- ~~TD-040: CI se cuelga en `offline_banner_test.dart`~~ — Resolved 2026-08-17 (ver "Fase 1" abajo).
- TD-010: verificar backups en el dashboard de MongoDB Atlas/Railway.
- Top-3 Mac (reordenado por PDR-009): ~~TD-059~~ (Resolved 2026-08-17), ~~TD-007~~ (parcial 2026-08-18) y TD-001.

## Siguiente tarea

**Round conjunto TD-057 + TD-060: la cola offline y los optimistic creates.**

Los dos comparten el mismo terreno —la resolución de ids entre lo local y lo que
el servidor devuelve— y por eso se abordan juntos (decisión A de
`docs/TD-007-DESIGN.md`):

- **TD-057** (High, abierto): la cola offline pierde un update/delete cuyo
  create ya sincronizó, porque `idRemap` es una variable local que se descarta
  entre pasadas de sincronización.
- **TD-060** (Medium, aplazado): `createTask`/`createItem` optimistas, con id
  temporal `pending-` y sustitución por el id real al confirmar.

Resolverlos por separado significaría escribir dos veces la misma lógica de
remapeo, con dos oportunidades de equivocarse. Conviene el mismo formato de
documento de diseño aprobable en bloque que se usó para TD-059 y TD-007.

Después: **TD-001**, migrar `members` embebido a colección separada — la
migración más grande del backlog abierto.

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

# TD-059 — Diseño: durabilidad de la caché Hive

Plan de implementación para TD-059 (ver `docs/TECH_DEBT.md`), secuenciado antes de TD-007 por **PDR-009**. Documento de diseño: no se ha tocado código de producción, tests ni CI al escribirlo.

Todas las rutas y líneas están verificadas contra el árbol en el commit `3bbf78a`.

---

## 1. Inventario completo

Los seis métodos existen, todos en `lib/services/cache_service.dart`. **Ninguno es `async` hoy**: los seis son síncronos y descartan el `Future` que devuelve Hive.

| Método | Firma actual | Operación Hive | ¿async hoy? |
|---|---|---|---|
| `addPendingOperation` | `void addPendingOperation(PendingOperation operation)` (180) | `Box.put` ×1 | No — expresión `=>` |
| `removePendingOperation` | `void removePendingOperation(String id)` (192) | `Box.delete` ×1 | No — expresión `=>` |
| `updatePendingOperation` | `void updatePendingOperation(PendingOperation operation)` (194) | `Box.put` ×1 | No — expresión `=>` |
| `saveTasks` | `void saveTasks(String householdId, List<Task> tasks)` (107) | `Box.delete` ×N + `Box.put` ×M, en bucles | No — cuerpo con bloque |
| `saveShopping` | `void saveShopping(String householdId, List<ShoppingItem> items)` (149) | `Box.delete` ×N + `Box.put` ×M, en bucles | No — cuerpo con bloque |
| `saveHousehold` | `void saveHousehold(Household household)` (173) | `Box.put` ×1 | No — expresión `=>` |

### Hallazgos que modifican el alcance

**H1 — No son seis, son once.** La entrada de TD-059 dice "los seis escritores", pero la misma clase tiene otros cinco métodos con exactamente el mismo defecto, y son los que más se usan:

| Método extra | Línea | Operación | Call sites en producción |
|---|---|---|---|
| `mergeTasks` | 135 | `Box.put` ×N | 1 |
| `saveTask` | 142 | `Box.put` ×1 | **9** |
| `deleteTaskFromCache` | 144 | `Box.delete` ×1 | **3** |
| `saveShoppingItem` | 167 | `Box.put` ×1 | **8** |
| `deleteShoppingItemFromCache` | 169 | `Box.delete` ×1 | **3** |

Dejar estos cinco fuera haría el trabajo inútil: `saveTask` y `saveShoppingItem` son precisamente las escrituras optimistas que TD-007 va a construir encima, y son las que más veces se llaman en todo el repositorio. **Recomendación: el alcance real de TD-059 son once métodos, no seis.** Esto necesita tu visto bueno porque amplía lo aprobado.

**H2 — `saveHousehold` es código muerto.** Cero call sites en producción (`grep -rn '\.saveHousehold(' lib/` fuera de `cache_service.dart` no devuelve nada). Su box `_households` se escribe únicamente desde ahí. Opciones: migrarlo por consistencia (coste casi nulo) o borrarlo. Recomiendo **migrarlo, no borrarlo**, en este round: borrar código muerto es una decisión aparte y mezclarla aquí ensucia el diff.

**H3 — `clearAll` ya es correcto.** `Future<void> clearAll()` (240) sí espera con `Future.wait` sobre los cuatro `Box.clear()`. Es el único escritor que hoy hace lo correcto y sirve de patrón para el resto.

---

## 2. Call sites

Todos los call sites de producción viven en dos archivos: `lib/data/repositories/task_repository.dart` y `lib/data/repositories/shopping_repository.dart`. Ningún Cubit, página o servicio llama directamente a un escritor de Hive: `main_scaffold.dart` solo lee el stream `pendingOperationsCount`, `auth_cubit.dart` solo llama a `clearAll()` (ya `await`-eado, línea 117) y `main.dart` solo a `init()`.

Esto es una buena noticia estructural: **la superficie de cambio está contenida en la capa de repositorios.**

### `addPendingOperation` — 6 call sites

| Archivo:línea | Contexto | ¿Llamador async? | ¿Qué haría un `await` hoy? |
|---|---|---|---|
| `task_repository.dart:178` | `_createOffline(...)` | **No — `Task _createOffline(...)`** | No compila sin cambiar la firma a `Future<Task>`. Ver "llamadores síncronos" abajo. |
| `task_repository.dart:248` | `_mutateOffline(...)` | **No — `Task _mutateOffline(...)`** | Igual. |
| `task_repository.dart:289` | `_deleteOffline(...)` | **No — `Task _deleteOffline(...)`** | Igual. |
| `shopping_repository.dart:114` | `_createOffline(...)` | **No** | Igual. |
| `shopping_repository.dart:182` | `_mutateOffline(...)` | **No** | Igual. |
| `shopping_repository.dart:226` | `_deleteOffline(...)` | **No — `ShoppingItem _deleteOffline(...)`** | Igual. |

### `removePendingOperation` — 4 call sites

| Archivo:línea | Contexto | ¿Llamador async? | ¿Qué haría un `await`? |
|---|---|---|---|
| `task_repository.dart:395` | `syncPendingOperations()`, camino de éxito | Sí | Se propaga sin fricción. |
| `task_repository.dart:404` | `syncPendingOperations()`, descarte tras >3 reintentos | Sí | Igual. |
| `shopping_repository.dart:286` | `syncPendingOperations()`, éxito | Sí | Igual. |
| `shopping_repository.dart:292` | `syncPendingOperations()`, descarte | Sí | Igual. |

### `updatePendingOperation` — 2 call sites

| Archivo:línea | Contexto | ¿Llamador async? | ¿Qué haría un `await`? |
|---|---|---|---|
| `task_repository.dart:412` | `syncPendingOperations()`, rama de reintento (`retryCount+1`) | Sí | Se propaga. Ojo: está dentro de un `catch`. |
| `shopping_repository.dart:300` | `syncPendingOperations()`, rama de reintento | Sí | Igual. |

### `saveTasks` / `saveShopping` — 1 call site cada uno

| Archivo:línea | Contexto | ¿Llamador async? | ¿Qué haría un `await`? |
|---|---|---|---|
| `task_repository.dart:106` | `list()`, primera página sin filtro de status | Sí | Se propaga limpio. |
| `shopping_repository.dart:54` | `list()`, primera página | Sí | Igual. |

### `saveHousehold` — 0 call sites

Ver H2.

### Los cinco métodos de H1 (si se acepta ampliar el alcance)

| Método | Call sites | Contextos síncronos entre ellos |
|---|---|---|
| `mergeTasks` | `task_repository.dart:108` | Ninguno (`list()`, async) |
| `saveTask` | `task_repository.dart:157, 177, 205, 223, 247, 288, 310, 374, 386` | **177** (`_createOffline`), **247** (`_mutateOffline`), **288** (`_deleteOffline`) |
| `deleteTaskFromCache` | `task_repository.dart:272, 372, 391` | Ninguno |
| `saveShoppingItem` | `shopping_repository.dart:93, 113, 139, 158, 181, 225, 269, 277` | **113**, **181**, **225** (los tres `_*Offline`) |
| `deleteShoppingItemFromCache` | `shopping_repository.dart:203, 267, 282` | Ninguno |

### Llamadores síncronos que no pueden `await` sin cambiar firma

Son **seis helpers privados**, y son el nudo del refactor:

| Helper | Archivo:línea | Firma actual | Llamado desde |
|---|---|---|---|
| `_createOffline` | `task_repository.dart:165` | `Task _createOffline(...)` | `create()` líneas 148 y 161 — **ambas `return` dentro de un método `async`** |
| `_mutateOffline` | `task_repository.dart:237` | `Task _mutateOffline(...)` | `update()` línea 211, `complete()` |
| `_deleteOffline` | `task_repository.dart:281` | `Task _deleteOffline(...)` | `delete()` |
| `_createOffline` | `shopping_repository.dart` (~105) | `ShoppingItem _createOffline(...)` | `create()` |
| `_mutateOffline` | `shopping_repository.dart` (~175) | `ShoppingItem _mutateOffline(...)` | `update()`, `purchase()` |
| `_deleteOffline` | `shopping_repository.dart:212` | `ShoppingItem _deleteOffline(...)` | `delete()` |

**Buena noticia:** ninguno es realmente bloqueante. Los seis se llaman **exclusivamente desde métodos que ya son `async`** y siempre en posición `return`. Convertirlos a `Future<Task>` / `Future<ShoppingItem>` y anteponer `await` en los seis sitios de llamada es mecánico y **no cambia ninguna firma pública del repositorio**: `create`, `update`, `complete`, `delete` y `purchase` ya devuelven `Future<...>`.

**No hay ningún call site que quede atrapado en un contexto síncrono irrecuperable.** Es el mejor escenario posible para esta migración y conviene decirlo explícitamente, porque era el riesgo principal que motivaba este diseño.

---

## 3. Estrategia de errores

### Qué significa que falle una escritura a Hive

No es un fallo de red ni de servidor: Hive escribe en el almacenamiento local del dispositivo. Los modos de fallo reales son pocos y todos graves:

1. **Disco lleno.** El escenario realista y no despreciable en móviles.
2. **Box cerrada o corrupta.** Bug nuestro o corrupción del fichero.
3. **Permisos / almacenamiento no disponible.** Muy raro en el sandbox de la app.

La diferencia con un fallo de API es decisiva: **un fallo de red es esperado y transitorio; un fallo de Hive es inesperado y probablemente persistente.** Reintentar una escritura contra un disco lleno no la va a arreglar, y ADR-010 ya reserva la maquinaria de reintentos y backoff para la cola de red.

### Recomendación

**No reintentar. Propagar, registrar en Sentry, y degradar de forma visible solo cuando el usuario ha recibido una promesa de durabilidad.**

Detalle por capa:

- **`CacheService`**: los once métodos pasan a `Future<void>` y hacen `await` de la operación de Hive. **No capturan nada** — el servicio no sabe qué significa el fallo en cada contexto. Es la capa equivocada para decidir.

- **Repositorios, escrituras que respaldan una promesa al usuario** (los seis `_*Offline`, es decir, el par "guardar entidad + encolar operación"): el `await` se deja propagar. Si falla, `create`/`update`/`delete` lanzan en vez de devolver una entidad optimista. **Este es el cambio de comportamiento que importa**: hoy la app dice *"Guardado offline, se sincronizará cuando haya conexión"* aunque la escritura se haya perdido. Con el fix, si no se puede persistir, el usuario recibe un error real en vez de una promesa falsa.
  Dentro de cada `_*Offline` el orden debe ser **primero la entidad, después la `PendingOperation`**, y ambas `await`-eadas. Si la segunda falla tras la primera, queda una entidad `isSynced:false` sin operación encolada — visible en la UI pero nunca sincronizada. Es un estado inconsistente peor que el fallo limpio, así que el `catch` de ese caso debe revertir la escritura de la entidad antes de relanzar. Hive no da transacciones multi-box, y montar un WAL propio es desproporcionado para un fallo que en la práctica significa "disco lleno".

- **Repositorios, escrituras de caché de solo lectura** (`saveTasks`, `mergeTasks`, `saveShopping` en `list()`, y los `saveTask`/`saveShoppingItem` que cachean una respuesta del servidor ya confirmada): aquí el dato **no se pierde** si la escritura falla — el servidor lo tiene. Fallar la llamada a `list()` por no poder cachear sería peor que el problema. Estos van envueltos en `try/catch` que reporta a Sentry y continúa. **Es el único sitio donde se mantiene el comportamiento fire-and-forget de hoy, ahora deliberado y con observabilidad en vez de por accidente.**

- **`syncPendingOperations`**: caso especial y el más delicado. Si el POST al servidor tuvo éxito pero `removePendingOperation` falla, la operación se reproducirá en la siguiente pasada. **Eso ya es seguro hoy**: la Hard Rule 13 obliga a que cada POST lleve `Idempotency-Key`, y el backend devuelve el recurso original con HTTP 200 sin re-emitir eventos de socket. Así que un fallo aquí se registra en Sentry y se rompe el bucle (mismo `break` que el camino de red), dejando el resto de la cola para el siguiente intento. **No** se debe descartar la operación.

### ¿Se notifica al usuario?

Solo en el primer caso (promesa de durabilidad rota). El mensaje debe distinguirse del error de red: algo como *"No se pudo guardar en este dispositivo. Puede que no quede espacio."* Un fallo de caché de solo lectura no se notifica — sería ruido sobre algo que el usuario no puede accionar y que no le ha costado datos.

### ¿Se marca la operación como fallida en la cola?

No hace falta un estado nuevo. `PendingOperation` ya tiene `retryCount` y ADR-010 define el descarte a los 3 intentos. Añadir un estado `failed` a la cola por fallos de Hive mezclaría dos dominios de error (local vs remoto) en el mismo campo, y complicaría TD-057, que ya está trabajando sobre esa cola.

### Trade-offs de la recomendación

| A favor | En contra |
|---|---|
| El usuario deja de recibir promesas falsas: es el fallo que TD-059 existe para cerrar. | `create`/`update`/`delete` pueden lanzar en un camino que hoy nunca lanza: hay que revisar cada Cubit que los llama para que no se quede en un estado de carga colgado. |
| Sin reintentos ni backoff nuevos: nada que ajustar, nada que pueda entrar en bucle. | Un disco lleno se vuelve visible y ruidoso. Es lo correcto, pero es un cambio de UX que conviene que apruebes. |
| Sentry gana una categoría de error hoy completamente invisible. | Volumen de eventos desconocido hasta que llegue el primero: puede haber fallos silenciosos ocurriendo ya. |
| Preserva fire-and-forget donde es seguro, y ahora de forma deliberada. | Dos políticas distintas en la misma clase — hay que documentarlo bien o alguien "unificará" la incoherencia aparente. |

**Alternativa descartada:** hacer que `CacheService` capture y trague todo internamente devolviendo `Future<bool>`. Mantiene los call sites triviales, pero reproduce el problema actual con un tipo de retorno más bonito: nadie comprueba un `bool` que casi siempre es `true`.

---

## 4. Auditoría de tests fake-async que tocan Hive

Superficie real: **23 ficheros de test, de los cuales solo 2 combinan `testWidgets` con `CacheService`/Hive**, y solo **uno** toca Hive de verdad.

| Archivo | `testWidgets` | ¿Hive real? | ¿Usa `runAsync`? | Acción |
|---|---|---|---|---|
| `test/widgets/offline_banner_test.dart` | 6 | **Sí** — `CacheService().init(testDirectory:)` con box real | Sí, desde el fix de TD-040 (línea 137) | **Ninguna acción de refactor.** Al cambiar las firmas, los `addPendingOperation` dentro del `runAsync` pasan a `await`-earse. Mantener el `runAsync`: sigue siendo necesario, porque `runAsync` es lo que hace que el `Future` de Hive pueda completarse dentro de la zona fake-async. |
| `test/widgets/session_listeners_test.dart` | 4 | **No** — usa `FakeCacheService` | Sí (líneas 303, 373), por el mismo motivo aplicado a `logout()` | Ninguna. |

Ficheros que tocan Hive con `test()` plano — **sin zona fake-async, no afectados**: `cache_service_test.dart`, `task_repository_cache_test.dart`, `idempotency_key_test.dart`, `auth_cubit_test.dart`, y el helper `fakes.dart`.

### ¿Refactorizar `offline_banner_test.dart` a `test()` plano?

**No.** Verifica el renderizado de un widget con `StreamBuilder`; necesita `testWidgets`. El `runAsync` es la herramienta correcta, no un parche.

### `FakeCacheService` no necesita cambios

`test/fakes.dart:448` declara `class FakeCacheService implements CacheService` con `noSuchMethod(Invocation) => Future<void>.value()`. Como ya devuelve `Future<void>` para todo lo no implementado explícitamente, **el cambio de `void` a `Future<void>` es compatible sin tocar el fake.** Solo `clearAll()` está implementado a mano y ya es `Future<void>`.

### Guardrail de timeout

Propuesta del diagnóstico de TD-040, y sigo recomendándola: `timeout: Timeout(Duration(seconds: 30))` en los `testWidgets` que tocan Hive real — hoy solo los 6 de `offline_banner_test.dart`.

Razón: un deadlock es peor modo de fallo que un test rojo. TD-040 consumió el presupuesto entero del step de CI durante semanas sin producir ni un mensaje de error. Con timeout explícito, una futura regresión falla en 30s con nombre de test, en vez de a los 3 minutos por matanza del runner. **Coste: una línea por test. No requiere dependencias.**

Nota importante: el timeout es un guardrail, **no** un sustituto de `runAsync`. Convierte un cuelgue en un fallo legible; no evita el cuelgue.

---

## 5. Plan de commits atómicos

Nueve commits. Cada uno deja el repo compilando y con la suite en verde.

El orden es deliberado: **primero las firmas de la capa más baja, luego sus llamadores, y solo entonces la política de errores.** Así ningún commit mezcla "cambiar el tipo" con "cambiar el comportamiento", que es donde se esconden las regresiones.

| # | Título | Alcance | Riesgo |
|---|---|---|---|
| 1 | `refactor(cache): CacheService writers devuelven Future<void>` | Solo `cache_service.dart`: los 11 métodos pasan a `Future<void>` y hacen `await` de la operación Hive. Ningún call site cambia — Dart permite descartar un `Future` en contexto de sentencia, así que todo sigue compilando y comportándose exactamente igual. | **Muy bajo.** Cambio de tipos puro, comportamiento idéntico. El lint `unawaited_futures` podría activarse: si lo hace, se resuelve en el commit 2, no aquí. |
| 2 | `refactor(repos): await de las escrituras de caché en contextos ya async` | `task_repository.dart` + `shopping_repository.dart`: `await` en los call sites cuyo método ya es `async` (los dos `list()`, las cuatro ramas de `syncPendingOperations`, y los `saveTask`/`saveShoppingItem` que cachean respuestas del servidor). Sin tocar los helpers `_*Offline`. | **Bajo.** Introduce puntos de suspensión donde no los había; revisar que ningún bucle dependa de ejecución síncrona. `syncPendingOperations` es el sitio a mirar con lupa. |
| 3 | `refactor(repos): _createOffline/_mutateOffline/_deleteOffline pasan a async` | Los seis helpers privados a `Future<Task>`/`Future<ShoppingItem>`, con `await` dentro, y `await` en sus seis sitios de llamada. **Ninguna firma pública cambia.** | **Bajo-medio.** Mecánico, pero es el corazón del camino offline. Los tests existentes de `task_repository_cache_test.dart` deben seguir verdes sin modificarse: si alguno falla, es señal de acoplamiento a la ejecución síncrona y hay que entenderlo antes de seguir. |
| 4 | `feat(cache): política de errores en escrituras de solo lectura` | `try/catch` + Sentry alrededor de las escrituras de caché que respaldan datos que el servidor ya tiene (`list()`, cacheo de respuestas). Incluye tests que fuerzan el fallo de escritura y verifican que `list()` sigue devolviendo la página. | **Medio.** Hay que simular un fallo de Hive; probablemente con un `CacheService` de prueba que lance. Puede requerir extraer una costura de test. |
| 5 | `feat(repos): fallo de escritura offline deja de prometer durabilidad` | Los `_*Offline` propagan el fallo en vez de devolver la entidad optimista, con el rollback de la entidad si falla el encolado de la `PendingOperation`. Tests de durabilidad: escritura correcta, fallo de la entidad, fallo de la operación con rollback. | **Alto.** Es el único commit que cambia comportamiento observable. Necesita los tests en el mismo commit (regla acordada). Aquí es donde puede aparecer un Cubit que se quede en estado de carga colgado. |
| 6 | `feat(ui): mensaje de error específico para fallo de guardado local` | Cubits + UI: distinguir el fallo de persistencia local del de red, con el texto propuesto en §3. | **Medio.** Cambio de UX visible; depende de que apruebes el mensaje. |
| 7 | `test(frontend): guardrail de timeout en tests que tocan Hive real` | `timeout: Timeout(...)` en los 6 `testWidgets` de `offline_banner_test.dart`. **Commit separado, sin lógica**, como pediste. | **Muy bajo.** |
| 8 | `refactor(cache): eliminar saveHousehold si sigue sin uso` | Solo si decides borrarlo (H2). **Omitir si prefieres conservarlo.** | **Muy bajo.** Cero call sites. |
| 9 | `docs: cerrar TD-059 como Resolved` | `docs/TECH_DEBT.md` a Resolved con fecha y evidencia; fila en la tabla corta de `CLAUDE.md` con estado Resolved + fecha; nota en `IMPROVEMENTS.md` si hay aprendizaje que registrar. | **Ninguno.** `scripts/check_docs.sh` valida la coherencia entre ambos ficheros. |

Los commits 1-3 son puramente mecánicos y podrían ir en una sola sesión con revisión ligera. Los commits 4-6 son los que cambian comportamiento y merecen revisión cuidadosa. **Un punto de parada natural para aprobación intermedia es después del commit 3**: el repo queda con toda la durabilidad *disponible* pero con el comportamiento actual intacto.

---

## 6. Riesgos y rollback

### Qué puede salir mal y cómo se detecta

| Riesgo | Detección |
|---|---|
| **Un `await` nuevo introduce un punto de suspensión donde el código asumía atomicidad.** El sitio crítico es `syncPendingOperations`: entre el `await` de la escritura y el `removePendingOperation` puede colarse otra pasada de sync disparada por el listener de conectividad. | Los tests de `task_repository_cache_test.dart` cubren el replay de la cola. Añadir en el commit 2 un test de dos `syncPendingOperations()` concurrentes. La Idempotency-Key limita el daño real, pero el síntoma sería `processed` contando de más. |
| **Un Cubit se queda en estado de carga colgado** porque ahora `create`/`update`/`delete` lanzan en un camino que antes no lanzaba. | Tests de Cubit del commit 5, más prueba manual (abajo). Sentry mostraría la excepción sin un cambio de estado que la acompañe. |
| **Regresión de tipo TD-040** al escribir un test nuevo. | El guardrail de timeout del commit 7 lo convierte en un fallo legible en 30s. El paso de CI ya está plegado y es bloqueante desde `0f95a98`. |
| **Rollback de la entidad tras fallo del encolado (commit 5) falla a su vez.** | Estado inconsistente residual. Registrar en Sentry con categoría propia; es un fallo de segundo orden en una situación ya degradada (disco lleno) y no merece más maquinaria. |
| **Cambio de rendimiento perceptible.** Hive ya escribía a disco; solo cambia quién espera. Una lista de 200 tareas hace ahora ~200 `await` secuenciales en `saveTasks`. | Medir en el commit 1. Si se nota, `Future.wait` sobre los puts del bucle, igual que ya hace `clearAll`. Anotado como posible ajuste, no como problema previsto. |

### ¿Migración de datos?

**No.** Mismo Hive, mismas boxes, mismos `TypeAdapter`, mismo formato en disco. El cambio es exclusivamente sobre quién espera al `Future` en Dart. Una app actualizada abre las boxes existentes sin conversión, y una versión anterior podría leer las escritas por la nueva. **No hace falta bump de versión de esquema ni ventana de despliegue.**

### Pruebas manuales en dispositivo tras el merge

Todas requieren dispositivo físico con la app instalada en release o profile.

1. **Escritura offline básica.** Modo avión → crear una tarea → confirmar que aparece con el indicador de no sincronizada y que el badge de la cola sube a 1.
2. **App muerta y reabierta — el escenario que TD-059 existe para cerrar.** Modo avión → crear una tarea → **matar la app desde el selector inmediatamente, sin volver al home** → reabrir sin conexión. La tarea y su operación pendiente deben seguir ahí. *Antes del fix este es el caso que podía perder la escritura.*
3. **Sincronización tras reconectar.** Con la cola no vacía, desactivar modo avión → la cola debe drenar sola, el badge llegar a 0 y los indicadores de no sincronizada desaparecer.
4. **Escrituras offline múltiples en ráfaga.** Crear 5 tareas seguidas sin conexión, matar la app, reabrir: las 5 presentes y en orden FIFO.
5. **Completar y borrar offline**, no solo crear: son caminos distintos (`_mutateOffline`, `_deleteOffline`).
6. **Disco lleno (opcional, el más difícil de montar).** Llenar el almacenamiento del dispositivo e intentar una escritura offline. Debe verse el mensaje nuevo de §3, no la promesa falsa de sincronización. Si no es práctico, se cubre con test unitario y se acepta que no hay validación en dispositivo.

Escenarios 2 y 4 son los que de verdad validan TD-059. El resto son regresión.

### Rollback

Cada commit es revertible por separado. El punto de no retorno práctico es el commit 5: es el único con comportamiento observable distinto. Si algo va mal en producción, revertir 5 y 6 devuelve la UX anterior conservando el trabajo de tipos de 1-3.

---

## 7. Tiempo estimado

**Dos sesiones de Mac**, asumiendo que no aparecen sorpresas mayores.

- **Sesión 1 — commits 1-3 y 7.** Trabajo mecánico: cambio de firmas, `await` en call sites, guardrail de timeout. Lo lento no es escribirlo sino verificar que la suite sigue verde en cada paso. Buen punto de parada para tu aprobación antes de cambiar comportamiento.
- **Sesión 2 — commits 4-6, 8 y 9.** La política de errores, sus tests y el mensaje de UI. Más lenta pese a tocar menos líneas: hay que construir la costura para simular fallos de escritura de Hive, que hoy no existe.

Las pruebas manuales en dispositivo son tuyas y van después del merge; no entran en esas dos sesiones.

**Lo que más probablemente rompa la estimación**, en orden de probabilidad: (1) que simular un fallo de Hive obligue a refactorizar `CacheService` para inyectar una costura de test — podría añadir media sesión; (2) que aparezcan Cubits que gestionan mal la nueva excepción y haya que arreglar varios; (3) que el cambio de rendimiento en `saveTasks` con listas grandes obligue a un paso de optimización no previsto.

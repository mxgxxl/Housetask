# TD-057 + TD-060 — Diseño: resolución de ids en la cola offline

Round conjunto para **TD-057** (la cola offline pierde un update/delete cuyo create ya sincronizó) y **TD-060** (optimistic creates). Se abordan juntos por la decisión A de `docs/TD-007-DESIGN.md`: ambos resuelven ids entre lo local y lo que devuelve el servidor, y hacerlos por separado significaría escribir dos veces la misma lógica de remapeo.

Documento de diseño: no se ha tocado código, tests, CI ni TDs al escribirlo. Verificado contra el árbol en `2bf907a`.

---

## 1. Root cause de TD-057

### El mecanismo

`TaskRepository.syncPendingOperations` (y su gemelo en `ShoppingRepository`) construye el mapeo local→servidor como **variable local**:

```dart
final idRemap = <String, String>{};
```

Se rellena cuando un create sincroniza:

```dart
case PendingOperationType.create:
  final serverTask = Task.fromJson(...);
  if (op.entityId != null) {
    idRemap[op.entityId!] = serverTask.id;       // (1) solo en memoria
    await _cache.deleteTaskFromCache(op.entityId!);
    await _cache.saveTask(serverTask);            // (2) la CACHÉ sí se re-keya
  }
  break;
...
await _cache.removePendingOperation(op.id);       // (3) el create sale de la cola
```

Y se consume al resolver cada operación:

```dart
final resolvedEntityId =
    op.entityId == null ? null : (idRemap[op.entityId] ?? op.entityId);
```

Las tres líneas marcadas son el problema: en (2) la caché queda correctamente re-keyada al id del servidor, y en (3) el create desaparece de la cola — pero **la cola conserva el id local en las operaciones que aún la referencian**, y el único sitio donde vive la traducción es (1), una variable que muere con la llamada.

### Escenario exacto de pérdida

Con la cola `[create(local-A), update(local-A, {'title': 'X'})]`:

| Paso | Qué pasa |
|---|---|
| 1 | `create` sincroniza. `idRemap['local-A'] = 'srv-9'`. La caché pasa a `srv-9`. El create sale de la cola. |
| 2 | `update` se procesa. `resolvedEntityId` = `srv-9`. **Si aquí falla con forma de red, el bucle hace `break`.** |
| 3 | El `break` descarta `idRemap`. La cola queda `[update(local-A, …)]` — con el id local intacto. |
| 4 | Siguiente pasada: ya no hay create en la cola, así que nada reconstruye el mapeo. `resolvedEntityId` = `local-A`. |
| 5 | `PATCH /tasks/local-A` → el servidor responde **404**. |
| 6 | 404 **no** es `isOfflineWorthy`, así que entra en la rama de reintentos: `retryCount++`. |
| 7 | Tras 3 pasadas más, `retryCount > 3` → `removePendingOperation` + `SentryService.captureException`. |

**Resultado: la edición que el usuario hizo offline desaparece**, después de que la UI le dijera *"Guardado offline, se sincronizará cuando haya conexión"*. Se reporta a Sentry, pero al usuario no se le dice nada.

### Tres salidas descartan el mapeo, no una

El registro de TD-057 describe el `break` de red. Hay **tres** caminos que pierden `idRemap` con el create ya fuera de la cola, y conviene tenerlos los tres presentes porque el fix debe cubrirlos por igual:

1. **`break` por fallo de red** (`isOfflineWorthy`) — el documentado.
2. **`break` por fallo de escritura en caché** — la rama `catch (e)` añadida en TD-059. Misma consecuencia.
3. **Muerte del proceso** entre el create y las operaciones que lo siguen. No hace falta ningún fallo: basta con que el usuario cierre la app a mitad de una sincronización larga.

El tercero es el que demuestra que el fix **no puede ser "mantener `idRemap` vivo entre llamadas"** (p. ej. subiéndolo a campo de instancia del repositorio): eso taparía 1 y 2 y dejaría 3 abierto. La traducción tiene que sobrevivir a un reinicio, o no sirve.

### Lo que ya está bien y no hay que tocar

- **La caché ya se re-keya** (`deleteTaskFromCache` + `saveTask`). El problema es exclusivamente de la cola.
- **La UI también se recupera sola**: `TaskCubit.syncPending` hace `load()` cuando `processed > 0`, así que la lista se repuebla desde el servidor y los ids locales obsoletos desaparecen de pantalla. El alcance del fix es **la cola, no la UI**.
- **El orden FIFO está garantizado**: `getPendingOperations()` ordena por `timestamp`, así que un create siempre se procesa antes que las operaciones que lo referencian.

---

## 2. Fix de idRemap

### Dónde persistir el mapeo

Dos opciones reales:

| | **A — Box `id_remap` aparte** | **B — Reescribir `entityId` en la cola** |
|---|---|---|
| Qué guarda | `local-A → srv-9`, indefinidamente | Nada: reescribe cada operación pendiente |
| Nuevo adapter Hive | Sí (nuevo `typeId`) | No |
| Migración | Sí, box nueva | **Ninguna** |
| Vida del dato | Indefinida; hay que decidir cuándo purgar | Cero: el mapeo deja de existir en cuanto se aplica |
| Riesgo propio | Una box que crece sin límite si nadie la purga | Reescritura en dos pasos (ver abajo) |

**Recomendación: B.** El mapeo **no tiene vida propia**: en cuanto toda operación encolada que referencia el id local ha sido reescrita, la traducción es basura. Guardarla en una box aparte crea un dato cuyo ciclo de vida hay que gestionar (¿cuándo se purga? ¿qué pasa si se purga antes de tiempo?) para resolver algo que se puede eliminar por construcción. Es además lo que ya propone la entrada de TD-057.

**Y sobre todo: no requiere migración de datos ni tocar el esquema.** `PendingOperation.copyWith` ya acepta `entityId`, el adapter ya persiste ese campo, y `CacheService.updatePendingOperation` ya existe y ya es awaitable desde TD-059. La pieza está entera; solo falta usarla.

### La forma del fix

En la rama de create, **antes** de sacar el create de la cola:

```
1. POST → serverTask
2. Reescribir en la cola TODA operación pendiente con entityId == localId,
   sustituyéndolo por serverTask.id   (updatePendingOperation por cada una)
3. Re-keyar la caché (deleteTaskFromCache(localId) + saveTask(serverTask))
4. removePendingOperation(createOp.id)
```

El orden importa y es el corazón del diseño. Si el proceso muere:

- **entre 1 y 2** → el create sigue en la cola y se reintenta. La Idempotency-Key hace que el servidor devuelva el recurso original con HTTP 200 sin re-emitir eventos de socket (Hard Rule 13), así que el reintento es seguro y el paso 2 se ejecuta entonces.
- **entre 2 y 4** → las operaciones ya apuntan al id del servidor y el create sigue encolado: se reintenta, es idempotente, y el paso 2 se vuelve a ejecutar sin efecto (ya no queda ninguna operación con el id local).

Es decir, **el paso 2 es idempotente y el create solo se retira cuando la reescritura ya está en disco**. Esa es la propiedad que cierra las tres salidas de §1, incluida la muerte del proceso.

`idRemap` sigue existiendo como variable local — sigue siendo útil dentro de una misma pasada para evitar releer la cola — pero deja de ser la fuente de verdad. Pasa a ser una caché de la reescritura ya persistida.

### Compatibilidad con la cola existente

Total, y merece decirse explícitamente porque es lo que hace este fix barato:

- **Sin cambio de esquema**: mismo `typeId: 3`, mismos campos, mismo adapter.
- **Sin migración**: una cola escrita por la versión anterior se lee igual. Sus operaciones con `entityId` local se reescribirán la primera vez que su create sincronice, exactamente como las nuevas.
- **Sin cambio de contrato con el backend.**
- Una cola ya "envenenada" —con un update huérfano cuyo create ya sincronizó en una versión anterior— **no se arregla sola**: su `entityId` local ya no tiene create que lo traduzca. Seguirá dando 404 y se descartará a los 3 reintentos, igual que hoy. **Es aceptable y no merece código de recuperación**: son colas de dispositivos concretos, el dato ya está perdido hoy, y detectar el caso exigiría heurísticas sobre ids que el servidor nunca conoció. Debe quedar dicho en la entrada de TD-057 al cerrarla.

### Un detalle que el fix debe respetar

La reescritura debe tocar **solo operaciones de la misma entidad** (`task` vs `shopping`). Los ids locales llevan un UUID, así que una colisión entre dominios es imposible en la práctica, pero filtrar por `entity` es gratis y evita que el día que se comparta el helper entre los dos repositorios haga algo distinto de lo que aparenta.

---

## 3. Optimistic creates (TD-060)

### El prefijo

Id temporal `pending-<uuid>`, **nunca `local-`**. No es cosmético: `local-` significa hoy *"creado offline y encolado"* y `syncPendingOperations` lo trata como tal. Un id en vuelo online no está encolado — no existe `PendingOperation` que lo respalde — así que reutilizar el prefijo haría que la cola creyera tener trabajo que nadie le dio.

### Reconciliación sin parpadeo

El overlay de TD-007 keya todo por id, y un create es la única mutación donde el id **cambia** al confirmar. Hoy `_confirmOptimistic(id, confirmed)` hace `_upsert(confirmed)`: con un id distinto, eso **añade** una fila en vez de sustituir, dejando dos.

Hace falta una variante de confirmación específica:

```
_confirmCreate(tempId, serverEntity):
    limpiar overlay bajo tempId
    UNA sola emisión que:  quita la fila tempId
                           inserta serverEntity
                           saca tempId de pendingIds
```

**Una sola emisión** es el requisito. `_upsert` y `_remove` emiten cada uno, así que encadenarlos produce un frame intermedio con la lista en un estado que no corresponde a nada — la fila desaparece y reaparece. Habrá que factorizar el cuerpo de `_upsert`/`_remove` en funciones que **calculen** el nuevo mapa de buckets sin emitir, y que la confirmación componga ambas y emita una vez. Es refactor mecánico, pero es el que evita el parpadeo y debe ir en su propio commit.

### La guarda de supersesión con un id que cambia

Es la pregunta más fina del round. La guarda actual es:

```dart
bool _isSuperseded(String id) {
  final applied = _optimisticApplied[id];
  if (applied == null) return true;
  return _findById(id) != applied;      // Equatable
}
```

**La clave: el id temporal sigue siendo la clave del overlay durante toda la vida de la mutación, y la entidad del servidor nunca aterriza bajo ese id.** La confirmación quita `tempId` e inserta `serverId` en la misma emisión, así que mientras el create está en vuelo solo existe la fila `tempId`. La comparación por `Equatable` queda bien definida: compara la fila temporal actual contra la temporal que aplicamos.

Consecuencias, y son las correctas:

- **El usuario edita la fila optimista antes de confirmar** → la fila bajo `tempId` cambia → superseded → si el create falla, **no se retira la fila**. Ver §4.1, que es donde eso deja de ser trivial.
- **Llega un socket `task:created` con el id del servidor** → inserta una fila **distinta** (`serverId`), no toca la de `tempId`, así que la guarda no la ve como supersesión. Correcto para la guarda, pero abre el problema de §4.4.
- **El create falla** → se retira la fila `tempId`. No hay snapshot que restaurar (`previous == null`), que es justo lo que `_rollbackOptimistic` ya hace para ese caso.

No hace falta versionado ni tocar `Equatable`: basta con no reutilizar el id del servidor como clave del overlay hasta que la fila temporal haya desaparecido.

### Encaje con el fix de §2

Un create optimista **online** no toca la cola: si tiene éxito, el id temporal se sustituye por el del servidor y no hubo `PendingOperation` en ningún momento. Si el repositorio cae a offline, lo que vuelve es la entidad `local-…` con `isSynced:false`, y la fila temporal se sustituye por ella con el mismo `_confirmCreate` — es el mismo cambio de id, solo que el destino es un id local en vez de uno del servidor.

Ese es el motivo de fondo por el que los dos TDs comparten round: **`_confirmCreate` es una sola pieza que sirve a los dos caminos**, y el prefijo distinto (`pending-` vs `local-`) es lo que mantiene separados "en vuelo" y "encolado" a lo largo de todo el recorrido.

---

## 4. Casos borde

### 4.1 Create + edición rápida antes de confirmar

El usuario crea una tarea y la renombra antes de que el POST vuelva. La edición se aplica sobre la fila `tempId`.

**Problema:** si el update se envía al servidor con `entityId = tempId`, el servidor no conoce ese id → 404. Y si el create luego confirma, la edición se ha perdido.

**Decisión propuesta: mientras un create está en vuelo, sus ediciones no se envían.** Se aplican a la fila local y se **encolan** como `PendingOperation(update, entityId: tempId)`. Al confirmar el create, el paso 2 de §2 reescribe ese `entityId` a `serverId` exactamente igual que hace con los ids `local-`, y la siguiente pasada de sync lo envía correctamente.

Es la respuesta elegante del round: **el mismo mecanismo que arregla TD-057 resuelve este caso borde de TD-060 sin código adicional**. Requiere que `pending-` participe en la reescritura igual que `local-`, es decir, que el paso 2 case por *"el `entityId` de esta operación es el id temporal que acaba de resolverse"*, sin mirar el prefijo.

Alternativa más simple y también defendible: **bloquear la edición mientras el create está en vuelo**, reutilizando el `isPending` que ya introdujo TD-007 (commit 7). Cuesta cero código nuevo y elimina el caso entero. La pega es que un create con red lenta deja la fila inerte varios segundos, lo que roza el problema que el optimistic update venía a resolver. **Recomiendo empezar bloqueando** y evaluar el encolado solo si la espera resulta molesta en dispositivo.

### 4.2 Create offline + logout/login

`AuthCubit.logout()` llama a `_cache.clearAll()`, que vacía **también** la box de operaciones pendientes. Un create hecho offline y no sincronizado **se pierde en el logout**, sin aviso.

Es comportamiento **actual**, no una regresión de este round, pero está en el camino directo de lo que se está tocando y merece decidirse:

- **Dejarlo como está** y documentarlo. Coherente con "logout limpia el dispositivo", que es una propiedad de seguridad deseable (otro usuario en el mismo teléfono no debe ver ni heredar los datos del anterior).
- **Avisar antes**: si la cola no está vacía, advertir en el logout ("Tienes N cambios sin sincronizar; si cierras sesión se perderán").

**Recomiendo la segunda**, como entrada propia y no dentro de este round: es un cambio de UX con su propia discusión y no depende de la resolución de ids. Anotarlo al cerrar TD-057.

### 4.3 Duplicados por reintento

Cubierto y **no requiere trabajo nuevo**: cada create lleva su `idempotencyKey`, generada una vez en `create()` y reutilizada verbatim en cada reintento. El backend devuelve el recurso original con HTTP 200 sin re-emitir eventos de socket (Hard Rule 13). Un create que llegó al servidor justo antes de perder la conexión se reintenta y resuelve al mismo recurso.

El fix de §2 **mejora** esta propiedad: como el create solo sale de la cola después de reescribir las operaciones que lo referencian, un reintento tras muerte del proceso vuelve a pasar por el paso 2 y converge al mismo estado.

### 4.4 El socket adelanta a la respuesta HTTP — el caso más incómodo

El backend emite `task:created` a la sala del hogar, **incluida la sesión que creó la tarea**. Hoy es inofensivo: `applyRealtime` inserta la fila con el id del servidor y la respuesta HTTP hace `_upsert` del mismo id, y como `_upsert` es idempotente por id no hay duplicado.

**Con creates optimistas deja de serlo.** Si el evento de socket llega antes que la respuesta HTTP, durante ese intervalo hay **dos filas para la misma tarea**: la optimista (`pending-…`) y la del socket (`serverId`). La confirmación quita la temporal, así que se resuelve solo — pero el usuario puede ver el duplicado parpadear.

Opciones:

1. **Aceptarlo y medir.** La ventana es la diferencia entre el socket y el HTTP para la misma petición, típicamente milisegundos. Coste cero.
2. **Que el socket sirva de confirmación**: si llega un `task:created` cuyo `createdBy` es el usuario actual y hay un create en vuelo, tratarlo como la confirmación y retirar la fila temporal. Elimina el parpadeo, pero acopla `TaskCubit` a la identidad del usuario (hoy en `HouseholdCubit`) y adivina la correspondencia sin una clave fiable.
3. **Que el backend haga eco de la `Idempotency-Key`** en el payload del socket. Es la solución limpia —da la correspondencia exacta— pero es un **cambio de backend**, fuera del alcance de este round y de lo aprobado.

**Recomiendo la 1 para este round**, con la 3 anotada como mejora futura. Pero es una **decisión tuya**: es el único efecto visible que este diseño no elimina, y conviene que lo sepas antes de aprobar, no después de verlo en el móvil.

---

## 5. Tests nuevos y plan de commits

### Tests

**TD-057 — la regresión que da nombre al TD:**

| Test | Verifica |
|---|---|
| `un update sobrevive al break de red que sigue a su create` | Cola `[create, update]`; el create sincroniza, el update falla con forma de red y rompe el lote. En la **segunda** pasada el update debe salir contra el id del **servidor**, no contra `local-…` |
| `la reescritura sobrevive a un reinicio` | Igual, pero reconstruyendo el repositorio entre pasadas — nada en memoria puede sostener la traducción |
| `el create solo sale de la cola tras reescribir` | Fuerza el fallo de la escritura de reescritura (costura `FakeBox` de TD-059): el create debe seguir encolado |
| `la reescritura es idempotente` | Dos pasadas seguidas no corrompen la cola |
| `solo se reescriben operaciones de la misma entidad` | Una operación de shopping con el mismo id local no se toca desde el sync de tasks |
| `una cola envenenada preexistente se descarta como hoy` | Fija el comportamiento aceptado, para que nadie lo lea como un bug nuevo |

**TD-060 — creates optimistas:**

| Test | Verifica |
|---|---|
| `la fila aparece antes de que el servidor responda` | Con la compuerta abierta, hay una fila con id `pending-…` |
| `la confirmación sustituye el id en una sola emisión` | Contar emisiones del cubit: **exactamente una** entre el estado optimista y el confirmado, y en ningún estado intermedio hay 0 filas ni 2 |
| `un create rechazado retira la fila` | Sin snapshot que restaurar |
| `un create que cae a offline sustituye pending- por local-` | Y `isSynced:false`, con el aviso de offline |
| `la guarda de supersesión no confunde la fila del servidor con la temporal` | Editar la fila optimista, luego fallar: la edición sobrevive |
| `una edición durante el create se comporta según §4.1` | La opción que se apruebe (bloqueo o encolado) |

Estimación: **~14-16 tests nuevos** sobre los 269 actuales.

### Plan de commits

| # | Título | Alcance | Riesgo | Parada |
|---|---|---|---|---|
| 1 | `refactor(cache): helper para reescribir el entityId de la cola` | `CacheService`: un método que reescriba en bloque las operaciones pendientes que referencian un id, con sus tests. Sin usarlo todavía. | Bajo | |
| 2 | `fix(sync): persistir el remapeo de ids antes de retirar el create (TD-057)` | Los dos `syncPendingOperations` usan el helper en el orden de §2. **Cierra TD-057 por sí solo.** Con los 6 tests de arriba. | **Alto** — es el corazón de la cola offline | **Sí.** TD-057 queda cerrado y verificable en dispositivo antes de tocar nada de TD-060 |
| 3 | `refactor(cubit): separar el cálculo de estado de la emisión en _upsert/_remove` | Extraer las funciones puras que calculan buckets/timeline. Sin cambio de comportamiento. | Bajo | |
| 4 | `feat(cubit): confirmación atómica de un create optimista` | `_confirmCreate` con una sola emisión. Todavía sin conectar. | Bajo | |
| 5 | `feat(tasks): createTask optimista con id pending-` | Una sola mutación, extremo a extremo. | Medio | **Sí**, mismo criterio que TD-007: validar el mecanismo con la superficie mínima |
| 6 | `feat(shopping): createItem optimista` | Simétrico. | Bajo si el 5 salió limpio | |
| 7 | `feat(ui): edición durante un create en vuelo` | La opción aprobada en §4.1. | Bajo | |
| 8 | `docs: cerrar TD-057 y TD-060` | TECH_DEBT + tabla corta + hallazgos + `NEXT_SESSION_MAC`. | Ninguno | |

**Dos paradas, y la primera es la importante.** Tras el commit 2, TD-057 —que es **High** y el único de los dos que provoca pérdida de datos real— queda cerrado y desplegable por sí mismo. Si el round se interrumpe ahí por lo que sea, el valor alto ya está en casa y TD-060 sigue siendo un *nice to have*.

---

## 6. Riesgos, rollback y pruebas manuales

### Riesgos

| Riesgo | Detección |
|---|---|
| **El commit 2 toca el camino que arregla pérdida de datos: un error ahí empeora exactamente lo que viene a arreglar.** | Los 6 tests de TD-057, y sobre todo el de reinicio, que es el que no se puede falsear con estado en memoria. Prueba manual 2. |
| **La reescritura deja la cola a medias** si falla entre operaciones. | Mitigado por el orden de §2: el create no se retira hasta que la reescritura está en disco, así que un reintento converge. El test de idempotencia lo fija. |
| **Duplicado visible por el socket** (§4.4). | Prueba manual 5. Es el único efecto que el diseño no elimina. |
| **Parpadeo en la confirmación del create.** | El test que cuenta emisiones lo detecta antes que el ojo. |
| **Regresión en el orden FIFO** al reescribir: `updatePendingOperation` hace `put` sobre la misma clave y `getPendingOperations` reordena por `timestamp`, que la reescritura no toca. Ordena por un campo que no cambia, así que el orden se preserva — pero conviene aseverarlo. | Test que sincroniza una cola de 3+ operaciones y comprueba el orden de las peticiones. |

### ¿Migración de datos?

**No.** Mismo `typeId`, mismos campos, mismo adapter (§2). Una cola escrita por la versión anterior se lee sin conversión. La única salvedad es la cola ya envenenada, que se comporta como hoy y se documenta.

### Rollback

El commit 2 es autónomo y revertible sin tocar el resto. Los commits 3-7 (TD-060) dependen del 2 pero no al revés, así que revertirlos deja TD-057 arreglado. No hay punto de no retorno ni cambio de formato en disco que impida volver atrás.

### Pruebas manuales en dispositivo

Las dos primeras son las que de verdad validan TD-057; sin ellas el fix no está verificado.

1. **Pérdida clásica.** Modo avión → crear una tarea → editarla → **desactivar el avión y volver a activarlo a los ~2 segundos**, para que el create sincronice y la edición pille el corte. Reconectar. La edición **debe** llegar. *Antes del fix, este es el caso que la pierde.*
2. **Supervivencia al reinicio.** Igual, pero **matando la app** justo después de que el create sincronice, en vez de cortando la red. Reabrir y reconectar: la edición debe aplicarse igual. Es la que descarta cualquier solución basada en memoria.
3. **Borrado en vez de edición.** Mismo guion que 1 pero borrando: el borrado debe llegar y la tarea desaparecer del servidor.
4. **Ráfaga offline.** Crear 3 tareas y editar la primera y la tercera, todo sin red. Reconectar: las 3 creadas y las 2 ediciones aplicadas, en orden.
5. **Create con red lenta** (tras el commit 5): la fila aparece al instante y **no debe verse ninguna fila duplicada** al llegar el id real. Si parpadea, es §4.4 y hay que decidir sobre ella con datos.
6. **Create rechazado**: crear una tarea sin permiso o con el backend devolviendo 4xx; la fila debe desaparecer con su error.
7. **Logout con cola pendiente** (§4.2): crear offline, cerrar sesión, volver a entrar. Confirmar que el cambio se perdió — es el comportamiento actual, y esta prueba sirve para decidir si merece el aviso propuesto.

---

## Decisiones aprobadas

Aprobadas por el dueño el 2026-08-18, antes de empezar la implementación. Resuelven las cuatro dudas abiertas del diseño.

### A. Socket echo: aceptar y medir

Se acepta la opción 1 de §4.4. Un create optimista puede mostrar **una fila duplicada durante el intervalo entre el evento `task:created` del socket y la respuesta HTTP** de la misma petición. La confirmación retira la fila temporal, así que se resuelve solo.

No se implementa ni la correlación client-side (opción 2, que adivinaría la correspondencia sin clave fiable y acoplaría `TaskCubit` a la identidad del usuario) ni el eco de la `Idempotency-Key` en el payload del socket (opción 3, la limpia, pero es un cambio de backend fuera del alcance de este round).

**Debe quedar documentado como limitación conocida en la entrada de TD-060 al cerrarla**, para que quien vea el parpadeo no lo persiga como un defecto nuevo. Si en dispositivo resulta molesto, la opción 3 es la mejora a plantear.

### B. Bloquear la edición durante un create en vuelo

Se toma la alternativa simple de §4.1: mientras un create está en vuelo, la fila **no se puede editar**, reutilizando el `isPending` que ya introdujo TD-007 (commit 7). Cero código nuevo y elimina el caso borde entero.

Queda descartado por ahora el encolado de la edición contra el id temporal. Es más fino y el mecanismo de §2 lo soportaría sin código adicional, pero añade superficie a un round que ya toca la cola offline. Si el bloqueo resulta molesto con red lenta, es lo primero a reconsiderar.

### C. El logout borra la cola pendiente: documentar y abrir TD propio

`AuthCubit.logout()` llama a `CacheService.clearAll()`, que vacía también la box de operaciones pendientes: **un create o una edición hechos offline y no sincronizados se pierden al cerrar sesión, sin ningún aviso.**

Es comportamiento actual y no una regresión de este round, así que **no se arregla aquí**. Se registra como entrada propia (Open, Medium, fuera de este round). La discusión de fondo es un conflicto real entre dos propiedades deseables: "el logout limpia el dispositivo" es una garantía de seguridad —otro usuario del mismo teléfono no debe heredar datos del anterior— y "no perder trabajo del usuario sin avisar" es una garantía de producto. La resolución probable es avisar antes de cerrar sesión cuando la cola no esté vacía, no dejar de limpiar.

### D. Colas ya envenenadas: documentar, sin código de rescate

Una cola escrita por una versión anterior que ya contenga un update/delete huérfano —cuyo create sincronizó y desapareció sin dejar traducción— **no se recupera**. Su `entityId` local ya no tiene create que lo traduzca, seguirá dando 404 y se descartará a los 3 reintentos, igual que hoy.

No se escribe código de recuperación: el dato ya está perdido en esos dispositivos, y detectar el caso exigiría heurísticas sobre ids que el servidor nunca conoció. **Debe quedar dicho en la entrada de TD-057 al cerrarla.**

### Plan de commits resultante

Sin cambios respecto a §5, con la decisión B fijando el contenido del commit 7 y la C añadiendo una entrada más al commit 8. Se mantienen las dos paradas: tras el commit 2 (TD-057 cerrado y desplegable por sí solo) y tras el commit 5.

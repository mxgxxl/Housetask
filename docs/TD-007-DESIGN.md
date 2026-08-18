# TD-007 — Diseño: optimistic updates en frontend

Plan de implementación para TD-007 (ver `docs/TECH_DEBT.md`), desbloqueado por **PDR-009** una vez cerrado TD-059. Documento de diseño: no se ha tocado código de producción, tests ni CI al escribirlo.

Verificado contra el árbol en el commit `e7d1c1a`.

> **Premisa que cambia el encuadre.** TD-007 no consiste en construir optimistic updates desde cero: **ya existen, pero solo en el camino offline.** `_createOffline`/`_mutateOffline`/`_deleteOffline` aplican el cambio a la caché al instante y devuelven la entidad optimista, y `TaskTile` ya pinta el indicador de no sincronizado. Lo que falta es cubrir **la ventana online en vuelo**: hoy, con conexión, el Cubit espera el round-trip completo del servidor antes de tocar la UI. El trabajo es extender el mecanismo existente a esa ventana, no inventar uno nuevo.

---

## 1. Inventario de mutaciones que hoy esperan al servidor

Ocho mutaciones, todas con la misma forma: `await _repo.X(...)` y solo después `_upsert`/`_remove`. En online, la UI no se mueve hasta que el servidor responde.

### TaskCubit (`lib/presentation/cubit/task_cubit.dart`)

| Mutación | Línea | Llamada al repo | Aplicación a UI hoy | Notas |
|---|---|---|---|---|
| `createTask` | 722 | `_repo.create` | `_upsert(task)` tras la respuesta | Devuelve `Task?`; la página lo usa. **Cambia el id** (local → servidor) |
| `updateTask` | 746 | `_repo.update` | `_upsert(task)` tras la respuesta | Reprograma recordatorios locales |
| `completeTask` | 763 | `_repo.complete` | `_upsert(task)` tras la respuesta | **La más frecuente y la más sensible a latencia** |
| `deleteTask` | 789 | `_repo.delete` | `_remove` (online) o `_upsert` marcado (offline) | Asimétrica online/offline |
| `restoreTask` | 691 | `_repo.restore` | `_upsert` + saca de `trashTasks` | Vista de papelera, no listas normales |
| `purgeTrash` | 710 | `_repo.purgeTrash` | Recarga papelera del servidor | **Fuera de alcance**: es una operación masiva cuyo resultado exacto solo conoce el servidor |

### ShoppingCubit (`lib/presentation/cubit/shopping_cubit.dart`)

| Mutación | Línea | Llamada al repo | Aplicación a UI hoy | Notas |
|---|---|---|---|---|
| `createItem` | 225 | `_repo.create` | `_upsert` tras la respuesta | **Cambia el id** |
| `updateItem` | 240 | `_repo.update` | `_upsert` tras la respuesta | |
| `togglePurchased` | 255 | `_repo.purchase` / `_repo.update` | `_upsert` tras la respuesta | **La más frecuente**: es el gesto central de la lista de la compra |
| `deleteItem` | 276 | `_repo.delete` | `_remove` o `_upsert` marcado | Asimétrica online/offline |

### Lo que ya está resuelto y hay que reutilizar, no duplicar

- **`_upsert` es idempotente por id y ya recalcula todo lo derivado**: recoloca la tarea entre los tres buckets según `TaskFilter.matches`, reordena, ajusta el `total` de cada bucket y recalcula el timeline (`_timelineAfterUpsert`). Aplicar un valor optimista y luego el confirmado es simplemente llamarlo dos veces.
- **`isSynced` y el indicador visual ya existen** (`task_tile.dart:153`).
- **La política de errores de TD-059 ya distingue** un fallo de red de un fallo de persistencia local, con `catch` general en las ocho mutaciones.

### Alcance recomendado

Las nueve primeras filas son candidatas; `purgeTrash` queda fuera. Pero **no todas valen lo mismo** y propongo no tratarlas por igual (ver §6):

- **Alto valor, riesgo bajo:** `completeTask`, `togglePurchased`, `updateTask`, `updateItem`. Son las interacciones frecuentes, el id no cambia y el rollback es "restaura el valor anterior".
- **Valor medio, riesgo alto:** `createTask`, `createItem`. Exigen id temporal y swap posterior — el mismo terreno donde vive TD-057.
- **Valor bajo:** `deleteTask`, `deleteItem`, `restoreTask`. El borrado ya se siente inmediato porque la fila desaparece, y `restoreTask` ocurre en una vista secundaria.

---

## 2. Diseño optimistic por mutación

### Mecanismo común

Tres piezas nuevas, todas en el Cubit:

1. **`Set<String> pendingIds` en el estado.** Ids con una mutación en vuelo. Es estado de UI, no de dominio: **no se persiste en Hive** (ver §3) y no sobrevive a un reinicio, que es justo lo correcto — una app que muere a mitad de vuelo no debe resucitar un "en vuelo".
2. **`Map<String, T> _rollbackSnapshots`** (privado, no en el estado). El valor de la entidad **antes** de la mutación, o `null` si no existía (create).
3. **Guarda de supersesión.** Al fallar, solo se revierte si el valor actual en el estado sigue siendo **idénticamente** el que aplicamos de forma optimista. Si algo lo cambió entretanto (otra mutación del usuario, un evento de socket, un refresh), el rollback se descarta y solo se muestra el error. Ver §4.

La distinción con offline importa: `pendingIds` significa *"esperando confirmación del servidor"*; `isSynced:false` significa *"encolado, se enviará cuando haya red"*. **Reutilizar `isSynced` para el vuelo online sería un error**: pintaría el indicador de offline durante cada escritura online de ~200 ms, mintiendo sobre el estado y provocando parpadeo.

### Por mutación

#### `completeTask` / `togglePurchased` — el caso de referencia

| Fase | Qué ocurre |
|---|---|
| **Al momento** | Snapshot del valor actual. `_upsert` con `status:'completed'` (o `isPurchased:true`), `completedAt: DateTime.now()`, `completedBy:` usuario actual. Id añadido a `pendingIds`. La fila salta de bucket, el contador se ajusta, el timeline se recalcula — todo vía `_upsert`. |
| **Confirmación** | `_upsert` con la entidad del servidor (que trae `completedBy` poblado y `completedAt` real). Id fuera de `pendingIds`. Segundo repintado, casi siempre invisible. |
| **Rechazo** | Si no fue superseded: `_upsert` con el snapshot. Id fuera de `pendingIds`. `error` con el mensaje del `Failure`. Si fue superseded: solo el error. |

Es el caso de referencia porque el id no cambia, el cambio es un solo campo y el rollback es un restore exacto.

#### `updateTask` / `updateItem`

Igual, con dos matices:

- El valor optimista es `payload` fusionado sobre la copia actual — **exactamente lo que ya hace `_mutateOffline`**, así que esa lógica de fusión debe extraerse y compartirse, no reescribirse.
- Los **recordatorios locales** (`scheduleTaskReminder`, `scheduleTaskStartReminder`) NO deben programarse en la fase optimista: programan notificaciones reales del sistema y un rollback tendría que cancelarlas. Se dejan en la confirmación, como hoy. Un retraso de 200 ms en programar un recordatorio para dentro de horas no lo nota nadie.

#### `deleteTask` / `deleteItem`

| Fase | Qué ocurre |
|---|---|
| **Al momento** | Snapshot, `_remove(id)` — la fila desaparece al instante. Id en `pendingIds` (aunque ya no esté en la lista, para que un rollback sepa que era suyo). |
| **Confirmación** | Nada visual que hacer. Id fuera de `pendingIds`. |
| **Rechazo** | Reinsertar el snapshot vía `_upsert`. **La reaparición es visualmente brusca**, así que aquí el mensaje de error es obligatorio y debe nombrar la tarea: "No se pudo borrar «Fregar»". |

⚠️ **Asimetría a preservar:** offline, `delete` NO quita la fila; devuelve la entidad marcada `isDeleted:true` para que se vea tachada. La rama optimista solo aplica al camino online. Si el repo acaba yendo por offline, lo que vuelve es la entidad marcada y hay que **sustituir** el `_remove` optimista por un `_upsert` marcado, no dejar la fila desaparecida.

#### `createTask` / `createItem` — el caso delicado

| Fase | Qué ocurre |
|---|---|
| **Al momento** | Construir la entidad con id temporal `pending-<uuid>` y `isSynced:false`, `_upsert`, id temporal en `pendingIds`. |
| **Confirmación** | El servidor devuelve la entidad real con **otro id**. Hay que `_remove(tempId)` y `_upsert(serverEntity)` de forma atómica (una sola emisión de estado, o la fila parpadea). |
| **Rechazo** | `_remove(tempId)`. No hay snapshot: no existía nada. |

**Tres razones para tratarlo aparte y en su propio commit:**

1. Es el único que **cambia el id**, y todo lo que en esta app remapea ids es terreno de TD-057 (que sigue abierto y es High).
2. El prefijo del id temporal **no debe ser `local-`**: ese prefijo ya significa "creado offline y encolado" para `syncPendingOperations`. Un `pending-` distinto evita que un id en vuelo online se confunda con uno encolado. **Esto es una precondición, no un detalle.**
3. Si la app muere entre el optimista y la confirmación, no queda rastro (no se persiste, no hay operación encolada) — correcto, porque el POST puede haber llegado igualmente y la Idempotency-Key protege el reintento. Pero significa que **el usuario puede ver desaparecer una tarea que sí se creó**, hasta el siguiente refresh. Aceptable, y hay que decirlo.

#### `restoreTask`

Optimista sobre `trashTasks` (sacar la fila) más `_upsert` en los buckets. Rollback simétrico. Bajo valor; candidato a omitirse.

#### `purgeTrash` — fuera de alcance

Borrado masivo cuyo alcance exacto (qué filas superan los 30 días) solo lo conoce el servidor. Adivinarlo localmente sería inventar datos. Se queda como está.

---

## 3. Interacción con el offline queue (ADR-010) y con TD-059

### La regla: qué es fuente de verdad y cuándo

| Capa | Contiene | Cuándo se escribe |
|---|---|---|
| **Hive (`CacheService`)** | Estado **confirmado** por el servidor, más escrituras **encoladas offline** | Al confirmar el servidor, o al encolar offline |
| **Estado del Cubit** | Lo anterior, **más** una superposición transitoria de mutaciones en vuelo | En memoria, cada mutación |

**Decisión central: una mutación online en vuelo NO se escribe en Hive.** Solo se persiste cuando se confirma, o cuando pasa a estar encolada offline.

El motivo se ve mejor por el negativo. Si persistiéramos el valor optimista y el proceso muriese antes de la respuesta, quedaría en la caché un valor que **nadie va a reintentar**: no hay `PendingOperation` que lo respalde, porque la operación estaba en vuelo, no encolada. Sería un fantasma indistinguible de un dato real — exactamente el modo de fallo que TD-059 acaba de cerrar, con los papeles cambiados: allí una escritura prometida no llegaba a disco; aquí llegaría a disco una escritura que nunca ocurrió.

Con esta regla, **TD-059 es lo que hace viable a TD-007**, y no solo un prerrequisito de higiene: cuando la confirmación sí llega, la escritura a Hive es esperable y con política de errores explícita, así que "la UI muestra X" y "la caché contiene X" no pueden divergir en silencio. Antes de TD-059, el `saveTask` de confirmación podía fallar sin que nadie se enterase y la superposición optimista habría tapado la divergencia indefinidamente.

### Transición online → offline a mitad de vuelo

Es el caso que une los dos mundos, y hoy ya está medio resuelto: si `create`/`update`/`delete` reciben un fallo de forma de red (`isOfflineWorthy`), el repositorio **no lanza**, sino que cae al camino offline y devuelve la entidad optimista con `isSynced:false`. Para el Cubit eso llega como un **éxito**, no como un rechazo.

Consecuencia para el diseño: la rama de éxito debe distinguir dos confirmaciones distintas:

- `entity.isSynced == true` → confirmada por el servidor. Quitar de `pendingIds`, sin aviso.
- `entity.isSynced == false` → cayó a offline. Quitar de `pendingIds`, aplicar la entidad **y** mostrar `kOfflineNoticeMessage`, exactamente como hoy.

**No hay rollback en este caso**: el cambio no se perdió, cambió de carril. Es lo más fácil de implementar mal y merece test propio.

### Interacción con `applyRealtime`

Un evento de socket sobre una entidad con mutación en vuelo puede llegar antes que la confirmación HTTP. Regla propuesta: **`applyRealtime` gana siempre** — viene del servidor, que es la autoridad — **y además marca la entidad como superseded**, de modo que un rechazo posterior no revierta sobre un valor que el servidor ya confirmó. Coherente con el last-write-wins de ADR-010.

---

## 4. Casos borde

### 4.1 Mutación encolada offline + nueva mutación del mismo ítem

Ya funciona y no debe romperse: `_mutateOffline` fusiona el `payload` sobre la copia cacheada y encola una **segunda** `PendingOperation`; el replay es FIFO. La superposición optimista debe respetar esto: si el ítem ya está `isSynced:false`, el valor base de la fusión es **el valor cacheado actual**, no el último confirmado por el servidor. Reutilizar la fusión de `_mutateOffline` en lugar de reimplementarla lo garantiza por construcción.

### 4.2 Rollback cuando el ítem cambió después — la guarda de supersesión

Escenario: el usuario completa una tarea (optimista), e **inmediatamente** la renombra. El complete falla en el servidor. Un rollback ingenuo restauraría el snapshot previo al complete y **borraría el renombrado**, que era una operación distinta y perfectamente válida.

Regla: revertir **solo si la entidad en el estado sigue siendo exactamente igual a la que aplicamos**. Comparación por igualdad de valor — `Task` y `ShoppingItem` extienden `Equatable`, así que es un `==` directo y no hace falta versionado.

Se marca como superseded por: otra mutación local del mismo id, un `applyRealtime` del mismo id, o un `load`/`refresh` que reemplace la lista. En todos esos casos el rollback se descarta y **solo se muestra el error**. Es la elección conservadora correcta: perder un rollback deja la UI adelantada respecto al servidor hasta el siguiente refresh; aplicarlo mal destruye trabajo del usuario.

### 4.3 Mutaciones concurrentes sobre el mismo ítem

Dos completes seguidos, o complete + update. `pendingIds` es un `Set` de ids, así que no distingue cuántas hay en vuelo. Propuesta: **la última mutación en aplicarse es la dueña del snapshot** (sobrescribe la entrada en `_rollbackSnapshots`). Si falla la primera, la guarda de §4.2 la detecta como superseded y no revierte. Simple, y se comporta bien en el caso realista de dobles toques.

### 4.4 Listas y detalles

`_upsert` cubre los tres buckets **y el timeline** (`_timelineAfterUpsert`). **No cubre** `recurringTasks`, `trashTasks` ni la página de detalle:

- `recurringTasks` (TD-035) y `trashTasks`: se recargan al entrar en su pestaña; una superposición optimista no llega ahí. **Aceptable**, pero hay que anotarlo: completar una tarea desde la lista normal no actualizará la fila equivalente en Recurrentes hasta recargar.
- La página de detalle/formulario recibe el `Task` por parámetro. Si se abre el detalle de una entidad en vuelo y la mutación se rechaza, el detalle muestra un valor ya revertido en la lista. **Recomendación: no permitir editar una entidad con mutación en vuelo**, deshabilitando la acción mientras su id esté en `pendingIds`. Es una línea de UI y elimina toda una familia de incoherencias.

### 4.5 Borrado optimista de una entidad con otra mutación en vuelo

Borrar mientras un update del mismo ítem está en vuelo. El borrado optimista lo quita de la lista; si el update falla después, su rollback intentaría reinsertarlo. La guarda de §4.2 lo cubre: la entidad ya no está donde la dejamos, así que cuenta como superseded y no se reinserta.

---

## 5. Tests nuevos

Todos con `FakeTaskRepository`/`FakeShoppingRepository` más un `Completer` como compuerta, patrón que `offline_banner_test.dart` ya usa (`syncGate`) para observar un estado intermedio. **La costura de TD-059 (`debugInjectBoxes` + `FakeBox`) solo hace falta en los dos casos que tocan la caché**; el resto son puramente de Cubit.

### TaskCubit

| Test | Verifica |
|---|---|
| `completeTask aplica el cambio antes de que el servidor responda` | Con la compuerta abierta: el bucket ya refleja `completed`, el id está en `pendingIds` |
| `completeTask reconcilia con la entidad del servidor al confirmar` | Tras cerrar la compuerta: `completedBy` poblado, `pendingIds` vacío |
| `completeTask revierte al valor previo si el servidor rechaza` | `Failure` no offline-worthy → estado idéntico al inicial + `error` |
| `completeTask NO revierte si la tarea cambió entretanto` | Optimista → `applyRealtime` con otro título → fallo. El título del socket sobrevive; no se restaura el snapshot |
| `un fallo de red NO revierte: cae a offline` | El repo devuelve `isSynced:false` → la fila se mantiene, `offlineNotice` puesto, `pendingIds` vacío |
| `createTask sustituye el id temporal por el del servidor` | Optimista con `pending-…`; tras confirmar, un solo elemento con el id del servidor y **ninguna** fila `pending-` |
| `createTask retira la fila optimista si el servidor rechaza` | La lista vuelve a estar vacía |
| `deleteTask reinserta la fila si el servidor rechaza` | La fila vuelve, en su posición de orden |
| `una mutación en vuelo no se persiste en Hive` | **Usa `FakeBox`**: con la compuerta abierta, la box no tiene la entidad; tras confirmar, sí |

### ShoppingCubit

Los equivalentes de `togglePurchased` (aplicar, reconciliar, revertir, no-revertir-si-superseded), `createItem` (swap de id, retirada en fallo) y `deleteItem` (reinserción). Más uno específico: **`togglePurchased` dos veces seguidas** deja el ítem en el estado del último toque y no revierte al fallar el primero.

### Regresión que hay que preservar explícitamente

Un test que verifique que **una entidad ya `isSynced:false` (encolada offline) sobre la que se hace otra mutación** sigue fusionando sobre el valor cacheado y encolando una segunda operación — el comportamiento de ADR-010 que §4.1 no debe romper.

Estimación: **~18-20 tests nuevos**, sobre los 249 actuales.

---

## 6. Plan de commits atómicos

El orden persigue que el valor llegue pronto y el riesgo tarde. Los commits 1-4 cubren las mutaciones frecuentes sin tocar ids; los 5-6 entran en el terreno de los ids temporales.

| # | Título | Alcance | Riesgo |
|---|---|---|---|
| 1 | `refactor(cubit): extraer la fusión optimista de _mutateOffline` | Sacar de `_mutateOffline` la construcción del valor fusionado a un helper reutilizable, en ambos repos. Sin cambio de comportamiento; los tests existentes deben pasar sin tocarse. | **Bajo.** Refactor puro. |
| 2 | `feat(cubit): superposición de mutaciones en vuelo` | `pendingIds` en ambos estados, `_rollbackSnapshots` privado, helpers `_applyOptimistic`/`_confirm`/`_rollbackIfNotSuperseded`. **Sin conectar a ninguna mutación todavía** — solo el andamiaje y sus tests unitarios. | **Bajo.** No cambia comportamiento observable. |
| 3 | `feat(tasks): completeTask optimista` | Una sola mutación, la más frecuente, de extremo a extremo, con sus 5 tests. **Punto de parada natural**: valida el mecanismo completo con la superficie mínima. | **Medio.** Primer cambio de comportamiento. |
| 4 | `feat(shopping): togglePurchased optimista` + `updateTask`/`updateItem` | Extiende el patrón ya validado a las otras tres mutaciones sin cambio de id. | **Medio.** Mecánico si el 3 salió limpio. |
| 5 | `feat(cubit): deleteTask/deleteItem optimistas` | Retirada inmediata + reinserción en fallo, preservando la asimetría offline. | **Medio-alto.** La reinserción es visualmente brusca; la asimetría online/offline es fácil de romper. |
| 6 | `feat(cubit): createTask/createItem optimistas con id temporal` | Prefijo `pending-`, swap atómico al confirmar. **Punto de parada obligatorio antes de empezarlo.** | **Alto.** Único que cambia ids; vecino de TD-057. |
| 7 | `feat(ui): bloquear edición de una entidad en vuelo` | Deshabilitar acciones mientras el id esté en `pendingIds` (§4.4). | **Bajo.** |
| 8 | `docs: cerrar TD-007 como Resolved` | TECH_DEBT + tabla corta de CLAUDE.md + sección de hallazgos en este documento. | **Ninguno.** `check_docs` valida la coherencia. |

**Dos puntos de parada:** tras el commit 3 (mecanismo validado con una mutación, decidir si el patrón convence antes de extenderlo) y **antes** del commit 6 (los creates son otra categoría de riesgo y merecen una aprobación explícita, o directamente aplazarse a un round posterior).

---

## 7. Riesgos, rollback y pruebas manuales

### Riesgos y detección

| Riesgo | Detección |
|---|---|
| **Parpadeo doble en el caso feliz**: la reconciliación repinta con un valor equivalente. Debería ser invisible, pero si `_upsert` reordena, la fila puede saltar. | Prueba manual 1. Mitigable emitiendo solo si el valor confirmado difiere del optimista. |
| **Rollback que destruye trabajo del usuario** — el fallo más grave posible aquí. | La guarda de §4.2 y su test. Si aparece en producción, es motivo de revert inmediato. |
| **Contadores desincronizados**: `_upsert` ajusta `total` por delta. Optimista + confirmación + rollback pueden desajustarlo. | Tests que asserten `total` en las tres fases, no solo la lista. |
| **Interacción con TD-057** (abierto): el swap de id del commit 6 vive junto al `idRemap` cuya fragilidad describe TD-057. | Aislado en su propio commit y tras un punto de parada. **No se toca TD-057 aquí**; si el commit 6 revelara que ambos deben resolverse juntos, es motivo de parar y reportar. |
| **Recordatorios locales programados sobre un valor revertido.** | Mitigado por diseño: solo se programan en la confirmación. |
| **`recurringTasks`/`trashTasks` desincronizados** (§4.4). | Limitación aceptada y documentada, no un bug. |

### ¿Migración de datos?

**No.** Nada nuevo se persiste: `pendingIds` y los snapshots son memoria del Cubit. El esquema de Hive no cambia.

### Rollback del cambio

Cada commit es revertible por separado. El mecanismo (commit 2) es inerte sin las mutaciones conectadas, así que revertir los commits 3-6 devuelve el comportamiento actual dejando el andamiaje. No hay punto de no retorno.

### Pruebas manuales del dueño en dispositivo

Con red real; varias necesitan latencia visible (red móvil lenta, o el simulador con Network Link Conditioner).

1. **Percepción base.** Completar una tarea con buena conexión: debe tacharse **al instante**, sin spinner intermedio. Es el objetivo entero de TD-007; si no se nota, no compensa el riesgo.
2. **Reconciliación invisible.** La misma acción con red lenta: la fila no debe parpadear ni saltar de sitio cuando llegue la respuesta.
3. **Rechazo real del servidor.** Editar una tarea creada por otro miembro sin ser admin (403 por Hard Rule 17): el cambio debe aplicarse, revertirse y mostrar el error del servidor.
4. **Rollback superseded.** Completar una tarea y renombrarla de inmediato, con el complete condenado a fallar (mismo 403). El renombrado **debe sobrevivir**. Es el escenario que más daño hace si está mal.
5. **Transición a offline a mitad de vuelo.** Activar modo avión justo tras tocar completar: la tarea debe quedarse completada con el indicador de no sincronizada y el aviso de offline — **no revertirse**.
6. **Borrado rechazado.** Borrar sin permiso: la fila desaparece y reaparece con un error que nombre la tarea.
7. **Create con red lenta** (solo si se ejecuta el commit 6): la tarea aparece al instante y no debe duplicarse ni parpadear al llegar el id real.
8. **App muerta a mitad de vuelo** (commit 6): crear una tarea con red lenta y matar la app antes de la respuesta. Al reabrir, la tarea puede estar (el POST llegó) o no. **Lo que no puede pasar es que aparezca dos veces** — lo protege la Idempotency-Key.

Las pruebas 4, 5 y 8 son las que de verdad validan este diseño; el resto son percepción y regresión.

---

## Decisiones aprobadas

Aprobadas por el dueño el 2026-08-18, antes de empezar la implementación. Modifican el plan de §6.

### A. Los creates quedan fuera de este round

`createTask` y `createItem` **no** se hacen optimistas aquí. El **commit 6 del plan de §6 queda cancelado** y se aplaza a un round conjunto con **TD-057**.

Razón: son las dos únicas mutaciones que cambian el id de la entidad, y esa resolución vive en el mismo terreno que el `idRemap` cuya fragilidad describe TD-057 (abierto, High). Resolverlos por separado significaría escribir dos veces la misma lógica de remapeo, con dos oportunidades de equivocarse, y probablemente rehacer la primera al abordar la segunda. El valor añadido es además el menor de las tres familias: una creación ya devuelve rápido y el usuario acaba de salir de un formulario, así que la espera no interrumpe un gesto en curso.

Consecuencia: al cerrar este round, TD-007 queda **Partially resolved**, no Resolved, y se abre una entrada propia para los creates optimistas.

### B. Los deletes entran

`deleteTask` y `deleteItem` **sí** se hacen optimistas, tal y como los describe §2, preservando la asimetría online/offline: offline la fila no desaparece, se marca `isDeleted:true` y se ve tachada.

Se asume el punto señalado en §7: la reinserción tras un rechazo es visualmente brusca. Por eso el mensaje de error de un borrado rechazado **debe nombrar la entidad** ("No se pudo borrar «Fregar»"), para que la reaparición se lea como consecuencia de un fallo y no como un glitch.

### C. `recurringTasks` y `trashTasks` quedan desincronizadas hasta recargar

Aceptado como limitación conocida, no como bug. `_upsert` cubre los tres buckets y el timeline, pero no esas dos listas, que se recargan al entrar en su pestaña.

Efecto observable: completar una tarea desde la lista normal no actualiza la fila equivalente en **Recurrentes** hasta que se recargue esa pestaña; lo mismo para **Papelera** tras un borrado.

Se acepta porque ambas son vistas secundarias a las que se llega deliberadamente, y extender la superposición hasta ellas obligaría a que cada mutación conociera cuatro colecciones en vez de dos — más superficie de desincronización que la que resuelve. **Debe quedar anotado en la entrada de TD-007 al cerrarla**, para que quien vea el síntoma no lo persiga como un defecto nuevo.

### D. Bloqueo de edición durante la ventana en vuelo

Aprobado el commit 7 de §6, con una precisión de forma: **estado `disabled` sutil, sin diálogos de error**.

Mientras el id de una entidad esté en `pendingIds`, sus acciones de edición quedan deshabilitadas. La señal debe ser discreta —el propio estado deshabilitado del control, sin banner, sin snackbar y sin diálogo—, porque la ventana dura típicamente 200 ms y cualquier aviso explícito sería más molesto que el problema que evita. Si la mutación falla, el error ya se muestra por el camino normal de rollback; no hay un segundo mensaje por el bloqueo.

### Plan de commits resultante

| # | Commit | Estado |
|---|---|---|
| 1 | Extraer la fusión optimista de `_mutateOffline` | Se ejecuta |
| 2 | Superposición de mutaciones en vuelo (andamiaje) | Se ejecuta |
| 3 | `completeTask` optimista | Se ejecuta — **punto de parada** |
| 4 | `togglePurchased` + `updateTask`/`updateItem` | Se ejecuta |
| 5 | `deleteTask`/`deleteItem` | Se ejecuta (decisión B) |
| ~~6~~ | ~~`createTask`/`createItem` con id temporal~~ | **Cancelado** (decisión A) |
| 7 | Bloqueo de edición en vuelo | Se ejecuta (decisión D) |
| 8 | Cerrar TD-007 como Partially resolved + abrir entrada de creates | Se ejecuta |

Se mantiene el punto de parada tras el commit 3. El de "antes del commit 6" desaparece con el propio commit 6.

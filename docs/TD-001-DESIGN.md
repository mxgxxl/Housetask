# TD-001 — Diseño: migrar `members` embebido a una colección `HouseholdMember`

Plan para TD-001 (ver `docs/TECH_DEBT.md` y **ADR-005**, que ya marca el embebido como "TO BE MIGRATED"). Es el primer round del ciclo que toca **backend y base de datos**, no solo el cliente, así que arrastra migración real en Atlas y orden de despliegue obligatorio.

Documento de diseño: no se ha tocado código, tests, CI ni TDs al escribirlo. Verificado contra el árbol en `a359ad7`.

---

## 1. Inventario de lecturas y escrituras

### Backend

| Archivo:línea | Operación | Campos usados |
|---|---|---|
| `models/Household.ts:19,25-31,46` | **Esquema**: `memberSchema` (`_id: false`) embebido como `members: [memberSchema]` | `user`, `role`, `joinedAt` |
| `middleware/membership.middleware.ts:34` | **Lectura** — `findById(householdId).select('members').lean()` | todo el array |
| `middleware/membership.middleware.ts:39` | **Lectura** — busca al llamante: `members.find(m => m.user.toString() === userId)` | `user` |
| `middleware/membership.middleware.ts:44-48` | **Lectura** — construye `req.member` | `role`, `joinedAt`, `memberIds` (todos los `user`) |
| `services/household.service.ts:44` | **Lectura** — `serializeHousehold` mapea el array, tolerando ref poblada o `ObjectId` | `user`, `role`, `joinedAt` |
| `services/household.service.ts:80` | **Escritura** — `createHousehold`: `members: [{ user, role:'admin', joinedAt }]` | los tres |
| `services/household.service.ts:97` | **Lectura** — `getHousehold` con `populate('members.user')` | `user` → name/email/avatarUrl |
| `services/household.service.ts:115` | **Lectura** — `joinByInviteCode`: `alreadyMember` (idempotencia) | `user` |
| `services/household.service.ts:117` | **Escritura** — `members.push({...})` | los tres |
| `services/household.service.ts:131,245` | **Lectura** — `populate('members.user', 'name email avatarUrl')` | `user` |
| `services/household.service.ts:211` | **Lectura** — `removeMember`: localiza al objetivo | `user` |
| `services/household.service.ts:219` | **Lectura** — cuenta admins (**Hard Rule 9**, nunca borrar el último admin) | `role` |
| `services/household.service.ts:224` | **Escritura** — `members = members.filter(...)` | `user` |
| `services/household-stats.service.ts:41` | **Lectura** — `populate('members.user', 'name avatarUrl')` | `user` |
| `services/household-stats.service.ts:79` | **Lectura** — `memberStats` mapea el array (PDR-007) | `user`, `role` |
| `services/task.service.ts:31-38` | **Lectura indirecta** — `assertAssignees` valida contra `memberIds` de `req.member` | ids |
| `controllers/household.controller.ts:57` | **Lectura** — `GET /:householdId/members` devuelve `serializeHousehold(h).members` | los tres |
| `types/index.ts:24-33` | **Contrato** — `RequesterMembership { role, joinedAt, memberIds }` | — |
| `scripts/seed.ts` | **Escritura** — datos de demo | los tres |

### Frontend

| Archivo:línea | Operación | Campos usados |
|---|---|---|
| `data/models/household.dart:11,32-36,47` | Modelo: `members: List<Member>`, `fromJson`/`toJson`, en `props` | array completo |
| `data/models/member.dart` | Modelo: `user`, `role`, `joinedAt`; `isAdmin` | los tres |
| `data/models/household_adapter.dart` | **Persistencia Hive** — round-trip vía `toJson`, members incluidos | array completo |
| `data/repositories/household_repository.dart:43` | `GET /households/:id/members` | los tres |
| `data/repositories/household_repository.dart:51` | `DELETE /households/:id/members/:userId` | — |
| `presentation/cubit/household_cubit.dart:123` | Refresca el hogar cuando llegan eventos de join/leave | array completo |
| `presentation/pages/task_form_page.dart:190-191` | Selector de asignados | `user` |
| `presentation/pages/profile_page.dart:104` | Lista de miembros | `user`, `role` |
| `presentation/widgets/task_tile.dart:63` | Conjunto de miembros actuales → "Ex-miembro" (**Hard Rule 16**) | `user.id` |

### Tres hallazgos que condicionan el diseño

**H1 — La relación está duplicada en ambos lados, y el segundo lado es el que usan los sockets.** Además de `Household.members`, existe `User.households: ObjectId[]`, mantenido en paralelo en las mismas tres operaciones (`household.service.ts:83, 123, 227`). **El handshake de socket lee ese lado, no el embebido**: `config/socket.ts:37` hace `UserModel.findById(...).select('households')` y de ahí salen las salas a las que el socket se une (`:43, :130, :133`).

Consecuencia: **TD-001 no es "quitar una desnormalización", son dos.** Un diseño que migre solo `Household.members` deja `User.households` como segunda fuente de verdad, con el mismo problema de consistencia que motivó el TD. Y como los sockets dependen de ella, tocarla no es cosmético.

**H2 — No existen invitaciones como entidad.** El alta es por `inviteCode`, un campo de `Household` (8 chars, único, indexado) contra el que se hace `joinByInviteCode`. No hay documento de invitación, ni estado pendiente, ni caducidad. **No hay nada que migrar en ese frente**, y conviene decirlo para que nadie diseñe una tabla que no hace falta.

**H3 — Solo hay dos roles y una regla dura sobre ellos.** `admin` / `member`, con la **Hard Rule 9** (nunca borrar el último admin), implementada hoy como `members.filter(m => m.role === 'admin').length` en memoria sobre el array ya cargado. Al pasar a colección eso se convierte en un `countDocuments`, y **deja de ser atómico respecto a la eliminación**. Es el punto más delicado de toda la migración (ver §7).

---

## 2. Esquema destino

### Colección `householdmembers`

| Campo | Tipo | Notas |
|---|---|---|
| `householdId` | ObjectId | ref Household, required |
| `userId` | ObjectId | ref User, required |
| `role` | Enum | `admin` / `member`, default `member` |
| `joinedAt` | Date | default `Date.now` |
| `createdAt` / `updatedAt` | Date | `timestamps: true`, como el resto de modelos |

Aplica `jsonSchemaOptions` de `utils/toJSON.ts` como los demás (virtual `id`, sin `_id`/`__v`).

### Índices

| Índice | Para qué | Por qué |
|---|---|---|
| `{ householdId: 1, userId: 1 }` **unique** | El check de pertenencia de `requireMembership`, en cada petición con `:householdId` | Es la consulta más caliente de la app. Y el `unique` da **por construcción** la idempotencia que hoy `joinByInviteCode` implementa a mano con `alreadyMember`: un doble alta pasa a ser un error de clave duplicada en vez de una comprobación que puede correr en paralelo consigo misma |
| `{ userId: 1 }` | "Mis hogares" — sustituye a `User.households` | Es lo que permite eliminar la desnormalización de H1 sin añadir una consulta cara al handshake de socket |
| `{ householdId: 1, role: 1 }` | Contar admins (Hard Rule 9) y listar el hogar | Convierte el conteo de admins en un índice cubierto |

### Roles e invitaciones

Sin cambios: los mismos dos roles, y `inviteCode` se queda donde está, en `Household` (H2). La única diferencia es que la regla del último admin pasa a resolverse con una consulta en vez de con un filtro en memoria.

### Qué pasa con `User.households`

**Recomendación: eliminarla al final del round**, sustituida por una consulta `HouseholdMember.find({ userId })` que el índice `{userId: 1}` hace trivial. Mantenerla sería conservar exactamente el problema que TD-001 viene a resolver, solo que en el otro lado.

Pero **no en el mismo paso**: el handshake de socket depende de ella, así que se retira en la fase de limpieza, después de que la colección nueva sea la autoridad y con su propio despliegue. Ver §3.

### Qué NO cambia: el contrato de la API

**Decisión central del diseño: la forma de las respuestas HTTP no cambia.** `serializeHousehold` sigue devolviendo un `members: [{ user, role, joinedAt }]` embebido en el hogar; lo único que cambia es de dónde salen esos datos.

Es lo que hace que **el frontend sea un no-op completo**: ni el modelo `Household`, ni `Member`, ni el adapter de Hive, ni la caché offline, ni ninguna de las cinco pantallas de §1 se enteran. Dado que la app se publica en tiendas y su despliegue no es reversible a voluntad (ver "Deployment order" en `CLAUDE.md`), evitar tocar el cliente en una migración de base de datos no es comodidad: es lo que permite hacer rollback del backend sin dejar apps en la calle hablando un contrato que ya no existe.

---

## 3. Migración sin downtime

Cinco fases, cada una desplegable y reversible por separado.

### Fase 0 — Modelo y escritura dual

Se crea el modelo y **toda escritura de membresía pasa a hacerse en los dos sitios**: el array embebido (que sigue siendo la autoridad) y la colección nueva.

Puntos de escritura, los tres ya inventariados: `createHousehold` (:80), `joinByInviteCode` (:117) y `removeMember` (:224).

**Las lecturas siguen todas contra el embebido.** Al terminar esta fase la colección existe y se mantiene al día, pero nadie la lee: si algo va mal, se revierte el deploy y no ha pasado nada.

Sin transacciones: Mongo las soporta en réplica, pero introducirlas aquí sería un cambio de infraestructura dentro de una migración. Una divergencia puntual entre ambos lados la corrige el backfill, que es idempotente y se puede volver a ejecutar.

### Fase 1 — Backfill

Script `backend/src/scripts/backfill-household-members.ts`, siguiendo el patrón de `migrate-refresh-tokens.ts` y `purge-trash.ts` (los dos scripts que ya existen).

Requisitos, y el tercero es el aprendizaje de TD-024:

1. **Idempotente**: recorre los hogares y hace `updateOne(..., { upsert: true })` por miembro sobre la clave `{householdId, userId}`. Ejecutarlo dos veces no duplica ni pisa un `role` ya divergente sin decirlo.
2. **`--dry-run` por defecto**, con `--yes` para escribir de verdad — como `migrate-refresh-tokens.ts`.
3. **Deja constancia de haberse ejecutado.** TD-024 quedó con el status *"Script ready… run with --yes during the deploy window of b2c481e"* y **a día de hoy nadie sabe si llegó a correr**; sigue anotado como ambigüedad en `NEXT_SESSION_MAC.md`. Este script debe imprimir un resumen final (hogares vistos, miembros creados, ya existentes, divergencias) y ese resumen debe pegarse en la entrada de TD-001 al cerrarla. Un script que no deja rastro es un script que habrá que volver a razonar dentro de seis meses.
4. **Reporta divergencias sin corregirlas en silencio**: si un miembro ya está en la colección con otro `role`, lo lista y no lo pisa. En esta fase no debería haber ninguna; que aparezcan significa que la escritura dual de la fase 0 tiene un hueco, y eso hay que verlo, no taparlo.

### Fase 2 — Lectura dual con verificación

Las lecturas pasan a la colección nueva, **pero comparando contra el embebido y reportando a Sentry cuando difieran**, sin cambiar el resultado devuelto (que sigue saliendo del embebido).

Es la fase que convierte una migración de fe en una medida. Corre en producción con tráfico real el tiempo que haga falta —días, no minutos— y el criterio para pasar a la fase 3 es **cero divergencias en ese periodo**, no que haya pasado un plazo.

El sitio a instrumentar es `requireMembership`, que se ejecuta en todas las rutas con `:householdId` y por tanto ve todo el tráfico real.

### Fase 3 — Cutover

La colección pasa a ser la autoridad:

- `requireMembership` consulta `HouseholdMember` y deja de cargar `members`.
- `serializeHousehold` compone el array desde la colección, **manteniendo idéntica la forma de la respuesta** (§2).
- `getHousehold` y `household-stats` cambian su `populate('members.user')` por un `find(...).populate('userId')`.
- La escritura sigue siendo dual: el embebido se mantiene actualizado **como red de rollback**.

Es el paso con más riesgo y el que merece su propia ventana de observación.

### Fase 4 — Limpieza

Solo cuando la fase 3 lleve tiempo estable:

1. Deja de escribirse `Household.members`.
2. Se elimina el campo del esquema y se hace `$unset` en los documentos existentes.
3. Se retira `User.households` y el handshake de socket pasa a `HouseholdMember.find({ userId })` (H1).

**Este es el único paso irreversible.** Hasta aquí, volver atrás es un deploy.

### Orden de despliegue y flag

**Sin feature flag.** El repo no tiene infraestructura de flags, y añadirla para esto significaría meter una dependencia y un plano de configuración nuevos en el round más delicado del backlog. Las fases ya son deployables por separado, que es lo que un flag daría; lo que no da es el rollback instantáneo sin deploy. Dado que Railway despliega en minutos desde un push y el rollback es revertir un commit, la diferencia real es pequeña frente al coste.

**El frontend no se despliega en ningún momento de este round** (§2), así que la regla de "backend primero, app después" de `CLAUDE.md` se satisface trivialmente: no hay app que publicar.

---

## 4. Compatibilidad con la caché offline y la cola pendiente

**Respuesta corta: ninguna de las dos se entera, y eso es una decisión, no una casualidad.**

- **`PendingOperation` no referencia miembros.** Su `entity` es `task` o `shopping` (`PendingOperationEntity`), y su `entityId` es el id de una tarea o un artículo. **Ninguna operación de membresía se encola**: `HouseholdRepository.removeMember` (:51) es una llamada directa a la API, sin camino offline ni entrada en la cola. Así que TD-057 y su reescritura de ids no tienen nada que ver con este round.
- **La caché de Hive sí guarda hogares con sus miembros** (`household_adapter.dart`, round-trip vía `toJson`). Como la forma de la respuesta no cambia (§2), **el adapter, el `typeId` y los datos ya cacheados siguen siendo válidos**: sin migración de Hive, sin bump de versión de esquema local, sin invalidación de caché.
- **La durabilidad de TD-059 se aplica igual**: las escrituras de hogar en caché ya devuelven `Future<void>` y sus llamadores las esperan. Nada que revisar.

El único punto de contacto real es indirecto: **`task_tile.dart:63` decide si un asignado es "Ex-miembro"** comparando contra `household.members` (Hard Rule 16). Como la lista llega igual desde la API, la regla sigue funcionando — pero es la comprobación que hay que incluir en las pruebas manuales, porque un fallo ahí es silencioso y visible a la vez.

---

## 5. Sockets

**Los payloads no cambian.** Ambos eventos de membresía ya emiten solo ids:

```js
emitToHousehold(id, 'household:member_joined', { householdId, userId })  // :125
emitToHousehold(id, 'household:member_left',   { householdId, userId })  // :229
```

Y el cliente reacciona recargando el hogar (`household_cubit.dart:123`), no leyendo el payload. Así que ni el contrato de socket ni el cliente necesitan tocarse.

> **Deriva documental detectada.** La tabla "Realtime (Socket.io)" de `CLAUDE.md` describe estos dos eventos como `Member + Household`, pero el código emite `{ householdId, userId }` desde hace tiempo. No es de este round, pero conviene corregirlo al cerrarlo, porque es justo el tipo de dato del que alguien se fiará al diseñar el siguiente cambio.

Lo que sí cambia, en la **fase 4**, es de dónde salen las salas: `config/socket.ts:37` deja de leer `User.households` y pasa a `HouseholdMember.find({ userId })`. Es un cambio de implementación, no de protocolo — el cliente no lo nota. Merece cuidado igualmente: **si esa consulta falla, el socket se conecta sin unirse a ninguna sala** y el usuario pierde el tiempo real sin ningún error visible.

---

## 6. Tests y plan de commits

### Tests

**Fase 0-1 (escritura dual y backfill):**

| Test | Verifica |
|---|---|
| `createHousehold escribe en ambos sitios` | El admin queda en el array y en la colección, con el mismo `role` |
| `joinByInviteCode escribe en ambos sitios` | Y sigue siendo idempotente: dos joins seguidos no duplican |
| `removeMember borra de ambos sitios` | |
| `el backfill es idempotente` | Dos ejecuciones dejan el mismo estado y la segunda reporta 0 creados |
| `el backfill reporta divergencias sin pisarlas` | Un `role` distinto se lista y se respeta |
| `el backfill no toca hogares ya migrados` | |

**Fase 2 (lectura dual):**

| Test | Verifica |
|---|---|
| `una divergencia se reporta a Sentry` | Y **no** altera la respuesta, que sigue saliendo del embebido |
| `sin divergencia no se reporta nada` | Que no genere ruido es parte del diseño |

**Fase 3 (cutover):** aquí la clave es que **la suite de `households.test.ts` (14 usos de `members`) pase sin modificarse**. Si hubiera que tocarla, sería señal de que el contrato cambió, que es exactamente lo que este diseño promete evitar. Se añaden:

| Test | Verifica |
|---|---|
| `la forma de la respuesta es idéntica antes y después` | Comparación del JSON serializado |
| `requireMembership sigue devolviendo 403 a un no-miembro y 404 si el hogar no existe` | |
| `req.member.memberIds sigue alimentando la validación de asignados` | La regla de `task.service.ts:31-38` |
| `no se puede eliminar al último admin` | **Hard Rule 9**, ahora contra la colección |
| `dos eliminaciones concurrentes no pueden dejar el hogar sin admin` | Ver §7 — es el riesgo principal |

### Plan de commits

| # | Título | Alcance | Riesgo | Parada |
|---|---|---|---|---|
| 1 | `feat(backend): modelo HouseholdMember` | Modelo + índices + tests de esquema. Nadie lo usa. | Bajo | |
| 2 | `feat(backend): escritura dual de membresía` | Los tres puntos de escritura. Lecturas intactas. | Medio | **Sí — desplegar y observar.** Es la fase 0 completa |
| 3 | `feat(backend): script de backfill idempotente` | Script + tests + ventana de deploy documentada | Bajo | **Sí — ejecutar en producción** y pegar el resumen |
| 4 | `feat(backend): lectura dual con verificación` | Compara y reporta; no cambia respuestas | Bajo | **Sí — dejar correr con tráfico real** hasta cero divergencias |
| 5 | `refactor(backend): la colección pasa a ser la autoridad` | Cutover de `requireMembership`, `serializeHousehold`, stats | **Alto** | **Sí — el paso más delicado** |
| 6 | `refactor(backend): dejar de escribir el array embebido` | Fin de la escritura dual | Medio | **Sí** — a partir de aquí el rollback deja de ser gratis |
| 7 | `refactor(backend): retirar members del esquema y User.households` | `$unset` + socket por `HouseholdMember` | Medio | |
| 8 | `docs: cerrar TD-001` | TECH_DEBT, tabla corta, ADR-005, corrección de la deriva de sockets de §5 | Ninguno | |

**Seis paradas.** No es exceso de cautela: cada una corresponde a una fase que debe observarse en producción antes de la siguiente, y **entre la 4 y la 5 el criterio de avance es un dato** (cero divergencias), no una decisión de calendario. Este round no se completa en una sesión ni debería intentarlo.

---

## 7. Riesgos, rollback y pruebas manuales

### El riesgo principal: la Hard Rule 9 deja de ser atómica

Hoy la protección del último admin es un filtro en memoria (`:219`) sobre un documento ya cargado, e inmediatamente después se escribe ese mismo documento. No es atómico en sentido estricto, pero la ventana es mínima y una escritura pisa a la otra.

Con la colección pasa a ser `countDocuments` + `deleteOne`: **dos operaciones separadas sobre documentos distintos**. Dos admins eliminándose mutuamente a la vez podrían pasar ambos el conteo y dejar el hogar **sin ningún admin** — un estado del que no hay ruta de recuperación en la UI.

Mitigaciones, en orden de preferencia:

1. **Borrado condicional**: `deleteOne({ householdId, userId, ... })` precedido de una comprobación que forme parte de la misma operación, p. ej. `findOneAndDelete` sobre el objetivo solo si `countDocuments({householdId, role:'admin'}) > 1` **releído tras el borrado**, revirtiendo si quedó en cero. Feo pero sin infraestructura nueva.
2. **Índice parcial único** que impida quedarse sin admin: Mongo no expresa esa restricción.
3. **Transacción**: correcto y directo, pero introduce transacciones en el round más delicado.

**Recomiendo la 1 con un test de concurrencia explícito** (ya listado en §6), y dejar la 3 anotada por si el test demuestra que no basta. Esta es la duda que más me gustaría resolver antes de empezar la fase 3.

### Otros riesgos

| Riesgo | Detección |
|---|---|
| **Coste por petición**: `requireMembership` corre en todas las rutas con `:householdId` y pasa de leer un documento ya cargado a una consulta propia | El índice `{householdId, userId}` la hace cubierta, pero conviene medir. Es además el punto donde `CLAUDE.md` sitúa la caché Redis de membresía de la Phase 2, que este round vuelve claramente más rentable |
| **Divergencia entre ambos lados durante la escritura dual** | Es precisamente lo que mide la fase 2. Por eso existe |
| **El backfill se queda a medias** en un hogar grande | Idempotente: se vuelve a lanzar |
| **El socket deja de unir salas** tras la fase 4 y el usuario pierde el tiempo real sin error visible | Prueba manual 5, y merece un log explícito cuando la consulta devuelva cero salas |
| **Repetir la ambigüedad de TD-024** — nadie sabe si el script corrió | El resumen del backfill pegado en la entrada de TD-001 |

### Rollback: ¿se puede volver a embebido?

**Sí, y sin pérdida de datos, hasta el commit 6.** Mientras la escritura dual esté activa, el array embebido sigue siendo un espejo completo y al día; revertir es desplegar el commit anterior. Esa es toda la razón de que la escritura dual sobreviva al cutover en vez de retirarse con él.

**A partir del commit 7 deja de serlo**: el `$unset` borra el array. Un rollback posterior exigiría un backfill inverso —que sería simétrico y escribible, pero es código que no existiría— más una ventana de escrituras perdidas. Por eso el commit 7 va al final, separado, y después de que la fase 3 lleve tiempo estable.

### ¿Migración de datos? Sí, y es la primera del ciclo

A diferencia de TD-059 y TD-057, que no tocaron esquema, aquí hay datos que mover en Atlas. El volumen actual es pequeño (hogares de 2-6 personas, PDR/ADR-005) y el backfill debería ser cuestión de segundos — lo cual es un argumento para hacerlo **ahora**, mientras el coste de equivocarse es bajo, y no cuando haya usuarios reales.

### Pruebas manuales del dueño

Con dos cuentas y dos dispositivos, o dos sesiones.

1. **Alta por invite code** (tras fase 0): el nuevo miembro aparece en Perfil en ambos dispositivos, y el evento de socket llega al que ya estaba.
2. **Selector de asignados**: crear una tarea y comprobar que el nuevo miembro es asignable (usa `members`, `task_form_page.dart:190`).
3. **Expulsión y "Ex-miembro"**: un admin expulsa al otro miembro; una tarea que tuviera asignada debe mostrar **"Ex-miembro"** y no un avatar roto (Hard Rule 16, `task_tile.dart:63`). Es el punto de contacto real con el frontend (§4).
4. **Último admin**: intentar expulsar al único admin debe fallar con el error del servidor. Repetir **tras el cutover**, que es cuando la regla cambia de implementación.
5. **Tiempo real tras la fase 4**: cerrar y reabrir la app, y comprobar que los cambios de otro dispositivo siguen llegando en vivo — verifica que el handshake sigue uniendo salas con la fuente nueva.
6. **Stats del hogar** (PDR-007): que la lista de miembros y sus contadores sigan saliendo (`household-stats.service.ts:79`).

Las pruebas 3, 4 y 5 son las que de verdad validan este round; el resto son regresión.

---

## Decisiones aprobadas

Aprobadas por el dueño el 2026-08-18, antes de empezar la implementación.

### A. Transacción de MongoDB para la expulsión de admins, desde el inicio

Se descarta el borrado condicional con relectura que proponía §7: no cierra la intercalación, solo la estrecha. La expulsión de un miembro pasa a ejecutarse dentro de una **transacción de MongoDB**, con el conteo de admins y el borrado en la misma unidad atómica, más el **test de concurrencia explícito** ya listado en §6.

> **⚠️ Bloqueante detectado antes de implementarlo.** Las transacciones de MongoDB **exigen un replica set**; no funcionan contra una instancia standalone. Y `src/tests/globalSetup.ts` arranca `MongoMemoryServer.create(...)`, que es **standalone**. Consecuencias:
>
> - En **producción no hay problema**: Atlas es siempre un replica set, incluso en el tier gratuito.
> - En **tests sí**: en cuanto el código de producción abra una sesión transaccional, *todos* los tests que pasen por `removeMember` fallarán con `Transaction numbers are only allowed on a replica set member or mongos`. No es un test nuevo que no se pueda escribir: es la suite existente que se rompe.
> - El arreglo es cambiar `globalSetup.ts` a `MongoMemoryReplSet.create({ replSet: { count: 1 } })`, lo cual **es tocar la infraestructura de tests**, y el dueño pidió expresamente que se reportara antes de hacerlo.
>
> Contexto adicional: **hoy no hay ni una sola transacción en el backend** (`grep -rn 'startSession\|withTransaction' backend/src` no devuelve nada), así que esta sería la primera y el cambio de `globalSetup` no puede romper nada preexistente.
>
> **Pendiente de aprobación** antes del commit que introduzca la transacción. Ver la parada correspondiente.

### B. `User.households` entra en este round

Se retira dentro del round, en la fase 4, junto con el `$unset` del array embebido. El handshake de socket (`config/socket.ts:37`) pasa a resolver las salas con `HouseholdMember.find({ userId })`, apoyado en el índice `{ userId: 1 }`.

Razón: dejarla fuera dejaría TD-001 a medias, conservando en el otro extremo exactamente la inconsistencia que el TD viene a eliminar.

### C. Caché Redis de membresía: aplazada, con plan de medición

No entra en este round. `CLAUDE.md` ya la sitúa en "Performance Patterns" como trabajo de Phase 2, y `requireMembership` seguirá siendo el punto donde se enchufe.

Pero **este round la vuelve claramente más rentable**, porque convierte una lectura de documento ya cargado en una consulta propia por petición. Así que se aplaza con un plan de medición concreto, no con un "ya veremos":

1. **Antes del cutover** (fin de la fase 2), registrar la latencia de `requireMembership` con el tráfico real que ya está observando la lectura dual. Sirve de línea base.
2. **Después del cutover** (fase 3 estable), volver a medir la misma ruta.
3. **Criterio de decisión:** si la diferencia es apreciable en el p95, la caché deja de ser Phase 2 y se convierte en el siguiente round; si no, se queda donde está.
4. Recordar el matiz que ya fija `CLAUDE.md`: la caché **no debe usarse** en operaciones destructivas o críticas de autorización (borrar hogar, expulsar, cambiar rol, comprobar último admin), que deben seguir consultando directamente. Con la colección eso es más fácil de respetar, no menos.

Debe quedar anotado al cerrar TD-001, con las dos mediciones.

### D. Arrancar ahora

Se empieza en esta sesión. Refuerza el argumento de §7: el volumen actual es mínimo (hogares de 2-6 personas), así que el backfill es cuestión de segundos y equivocarse todavía es barato. Hacerlo con usuarios reales sería otra conversación.

Se mantienen las seis paradas de §6 y el criterio de que **entre la fase 2 y la 3 lo que autoriza a avanzar es un dato** —cero divergencias medidas— y no un plazo.

---

## Nota de implementación: la atomicidad de la Hard Rule 9 está razonada, no medida

Añadido el 2026-08-18, al implementar el commit 2.

`removeMember` ejecuta la lectura, el conteo de admins y las tres escrituras dentro de una transacción, exactamente como pedía la decisión A. Lo que **no** se consiguió es demostrar empíricamente que esa transacción sea lo que impide dejar un hogar sin admin.

### Lo que se intentó

1. **Dos peticiones concurrentes vía supertest.** El test pasa **también con la transacción desactivada** (3/3 ejecuciones). Bajo `--runInBand` y con Node monohilo, las dos peticiones no llegan a intercalarse en la ventana entre el conteo y la escritura: ninguna cede el control ahí.
2. **Fail point de MongoDB** (`configureFailPoint` / `failCommand` con `blockConnection`), para retener la escritura de la primera transacción y que la segunda leyera el estado previo. Requiere arrancar el servidor en memoria con `--setParameter enableTestCommands=1`, lo cual **funciona** — el comando responde `ok: 1`. Pero el resultado fue el mismo: **el test sigue pasando sin la transacción**, 3/3. El fail point desplaza el bloqueo sin abrir la ventana.

Ambos experimentos se revirtieron en vez de dejarse como andamiaje muerto: el test de carrera se borró y el flag del harness también, al quedarse sin consumidor.

### Lo que NO se hizo, y por qué

No se añadió una costura en el código de producción —por ejemplo, un retardo inyectable entre el conteo y la escritura— porque introducir un punto de extensión en una ruta crítica únicamente para que un test pueda observarla es un intercambio que merece decidirse a propósito, no colarse dentro de un round de migración. La decisión fue explícita del dueño.

### Cuál es el estado real, dicho sin adornos

- **La protección es correcta por construcción**: las dos transacciones leen y escriben el mismo documento de hogar, así que MongoDB detecta el conflicto de escritura y una de ellas aborta; `withTransaction` la reintenta, la relectura ve un solo admin y la Hard Rule 9 la rechaza.
- **Esa cadena de razonamiento no está verificada por una prueba que falle sin ella.** El test que existe (`household-member-dual-write.test.ts`) afirma el invariante y cazaría una regresión gruesa, pero pasaría igual si alguien quitara la transacción.

Quien retome esto debe saberlo antes de tocar `removeMember`: **quitar la transacción no rompería ningún test**, y eso es precisamente lo que la hace frágil de mantener. Si en algún momento se decide construir la costura, este es el sitio donde apuntar por qué hacía falta.

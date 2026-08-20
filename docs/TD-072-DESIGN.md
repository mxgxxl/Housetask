# TD-072 — Diseño de deep-link de notificación a tarea

> Estado: Open. Prioridad: High. Diseño documental; no implementa código, tests ni CI. Cubre el punto 4 del PDF del dueño y el último ítem de P0. El siguiente identificador libre confirmado en `docs/TECH_DEBT.md` es TD-072.

## 0. Alcance y criterio de evidencia

Este diseño define cómo un tap sobre una notificación FCM abre la tarea exacta dentro de la app. No conecta Firebase/APNs en dispositivos reales, no añade un URL scheme externo y no implementa todavía los destinos futuros de misión o reconocimiento.

- **Causa confirmada:** comportamiento, ausencia o contrato visto directamente en el código actual.
- **Hipótesis:** consecuencia inferida cuyo resultado final depende del sistema operativo, de Firebase o de una carrera no reproducida.
- **Pregunta abierta:** decisión que este prompt, el código y los PDR no cierran; no se decide aquí.

El payload es una pista de navegación no confiable. La autorización y la existencia de hogar y tarea se vuelven a comprobar en el servidor antes de abrir el destino.

## 1. Estado actual

### Backend y payload emitido

**Causa confirmada:** `sendPushNotification` admite un `data?: Record<string, string>` y lo entrega a FCM junto con título y cuerpo. Los únicos productores actuales están en `task.service.ts`:

- `notifyTaskAssigned`, al asignar una tarea a otro miembro;
- `notifyTaskCompleted`, al completar otra persona una tarea creada por el destinatario.

**Causa confirmada:** ambos construyen hoy exactamente `{ type: 'task', taskId }`. No incluyen `householdId`, por lo que el cliente no puede resolver de forma inequívoca el hogar que debe activar.

**Causa confirmada:** no existen productores de push de misión ni reconocimiento. TD-071 los diseña, pero su modelo, API y notificación todavía no están implementados.

### Recepción y tap en Flutter

**Causa confirmada:** `NotificationService.initPushNotifications()` se ejecuta después de autenticar. Registra `FirebaseMessaging.onMessage` para mostrar una notificación local en foreground y `FirebaseMessaging.onMessageOpenedApp` para taps que devuelven una app en background a foreground.

**Causa confirmada:** `showLocalNotification()` serializa `message.data` como `payload` de `flutter_local_notifications`, pero la inicialización del plugin no registra `onDidReceiveNotificationResponse`. Por tanto, el payload se conserva al pintar el banner local, pero no existe código que procese su tap.

**Causa confirmada:** `_handleNotificationTap` solo reconoce `type == 'task'` y ejecuta `pushNamedAndRemoveUntil(Routes.main, ...)`. No lee `taskId`, no valida el payload y no carga la tarea.

**Causa confirmada:** no hay llamada a `FirebaseMessaging.instance.getInitialMessage()`. Un tap que arranca una app terminada no entra en el único handler actual.

**Causa confirmada:** no existe un handler común para foreground, background y terminated. `onMessage` muestra, `onMessageOpenedApp` navega de forma genérica y el arranque terminado no se procesa.

**Hipótesis:** al tocar el banner local generado en foreground, la app se limita a volver o permanecer visible sin navegar. La ausencia del callback está confirmada; el efecto exacto por plataforma debe verificarse en dispositivo.

**Hipótesis:** al arrancar desde terminated se pierde el destino y se sigue el arranque ordinario. La ausencia de `getInitialMessage` está confirmada; la entrega real no se puede comprobar hasta cerrar la configuración operativa de TD-049.

### Routing y acceso a una tarea individual

**Causa confirmada:** `Routes` solo declara splash, login, register y main. Las pantallas de feature se abren con `MaterialPageRoute` y argumentos de constructor; no existe una ruta nombrada para una tarea específica.

**Causa confirmada:** `MainScaffold` empieza con `_index = 0`, que corresponde a **Inicio**. La pestaña **Tareas** ocupa el índice 1. Por ello, el tap actual aterriza en Inicio, aunque PDR-008 y comentarios anteriores describan el shell como si su pestaña inicial mostrara Tareas.

**Causa confirmada:** `TaskFormPage(task: task)` es la única superficie individual actual y es un formulario de edición, no una vista de detalle. La lista ya debe tener el objeto `Task` para abrirla.

**Causa confirmada:** el backend no expone `GET /households/:householdId/tasks/:taskId`; el router de tareas solo lista páginas y ofrece create/update/complete/delete/restore. `TaskRepository` tampoco tiene un `getById`. Buscar una tarea mediante el listado paginado no garantiza encontrarla.

**Causa confirmada:** todas las rutas de tareas existentes están detrás de `authMiddleware` y `requireMembership`. Ese middleware responde 404 si el hogar no existe y 403 si la persona ya no pertenece; es el precedente server-authoritative que debe conservar el nuevo lookup individual.

**Causa confirmada:** si un refresh de sesión es rechazado, `SessionListeners` resetea los Cubits y navega a login. No existe hoy una cola de intención de navegación que sobreviva a esa transición.

## 2. Decisiones aprobadas

1. **D1 — Navegación interna por payload FCM.** V1 usa `taskId`, `householdId` y `type` para navegar dentro de Flutter. No añade universal links, app links ni URL scheme externo.
2. **D2 — Payload mínimo obligatorio.** `taskId`, `householdId` y `type` deben existir y superar validación. Si falta cualquiera, se abre la pantalla de Tareas como fallback.
3. **D3 — Un solo handler.** Foreground, background y terminated normalizan el tap y lo entregan al mismo handler de navegación profunda; ninguna fuente implementa reglas propias de destino.
4. **D4 — Destino inválido seguro.** Si la tarea no existe, fue eliminada o la persona no tiene acceso, se abre Tareas y se muestra un aviso explicativo. Nunca se deja una pantalla vacía, un spinner indefinido ni un crash.
5. **D5 — Dispatcher extensible por tipo.** `type` decide la familia de destino: tarea, misión o reconocimiento. Nuevos tipos se añaden como casos explícitos del dispatcher, no como rutas construidas desde texto sin validar.
21. **D21 — Superficie de detalle dedicada.** La tarea se abre en la ruta interna `/tasks/:taskId`, respaldada por un endpoint individual household-scoped. No se usa un modal. La misma pantalla de detalle sustituye la apertura directa del formulario desde las listas; editar queda como una acción explícita y sujeta a permisos.
22. **D22 — Replay durable tras login.** El deep-link pendiente se persiste y se reproduce después de un login exitoso. La autenticación no deja al usuario en Inicio: al recuperar sesión, el coordinador revalida el destino y continúa al detalle o a su fallback autoritativo.
23. **D23 — Política offline con frescura.** Si la tarea exacta existe en la caché local del usuario y hogar, se muestra con un indicador visible de frescura. Si no está cacheada, se abre Tareas y se muestra el toast exacto **«sin conexión, reintentar»**.
24. **D24 — Último tap prevalece.** Los taps dentro de una ventana corta y configurable se deduplican con semántica last-write-wins: la intención más reciente invalida cualquier resolución anterior todavía en vuelo.
25. **D25 — Identificador por tipo.** El esquema extensible es `type + householdId + identificador específico del tipo`. V1 solo implementa `taskId`; `missionId` y `recognitionId` quedan reservados para P3 y no activan todavía ningún destino.

Copy exacto común para D4:

> **No pudimos abrir esa tarea. Te mostramos tus tareas.**

Copy exacto cuando la validación local detecta que el payload está incompleto o corrupto:

> **La notificación no tiene un destino válido. Te mostramos tus tareas.**

## 3. Modelo del payload FCM

### Contrato v1 para tarea

FCM exige valores string en `data`. El contrato mínimo es:

```json
{
  "type": "task",
  "householdId": "<ObjectId del hogar>",
  "taskId": "<ObjectId de la tarea>"
}
```

Campos opcionales admitidos sin convertirlos en autoridad:

| Campo | Tipo FCM | Uso |
|-------|----------|-----|
| `schemaVersion` | string | Versión del parser; valor inicial recomendado `"1"`. Ausencia se interpreta como contrato v1 mientras dure la migración. |
| `action` | string enum | Analítica y copy: `assigned` o `completed`. No decide permisos ni destino. |
| `eventId` | string | Deduplicación transversal si el backend dispone de una identidad durable del evento. |

No se incluyen token, rol, email, nombre, título de tarea ni permiso de edición en `data`. El título y el cuerpo visibles pueden seguir llevando el copy actual, pero nunca sustituyen la lectura canónica del recurso.

### Validación cliente

`NotificationIntent.fromMap` realiza una validación pura antes de cualquier navegación o petición:

1. el mapa existe y sus claves obligatorias son strings no vacíos;
2. `type` pertenece al enum admitido;
3. para `type: task`, `householdId` y `taskId` tienen formato ObjectId válido;
4. los campos opcionales desconocidos se ignoran; no se interpolan como nombres de ruta;
5. payload inválido produce el fallback de D2 y el copy correspondiente, no una excepción.

La validación sintáctica ahorra peticiones corruptas, pero no demuestra pertenencia ni existencia. El servidor repite el control sobre identificadores y membresía.

### Generación backend

Se propone un constructor tipado central, por ejemplo `buildNotificationData`, para que cada productor entregue el mismo contrato:

| `type` | Productor backend | Identidad canónica | Estado actual |
|--------|-------------------|--------------------|---------------|
| `task` | `task.service.ts`, en asignación y completado | `task._id` y `task.householdId` leídos del documento persistido | Existe, pero debe añadir `householdId` y centralizar la forma. |
| `mission` | Futuro servicio de misiones | `householdId` + `missionId` canónicos | `missionId` queda reservado para P3; no existe productor ni ruta de destino. |
| `recognition` | Futuro servicio de reconocimiento de TD-071 | `householdId` + `recognitionId` canónicos | `recognitionId` queda reservado para P3; no existe productor ni ruta de destino. |

El productor crea el payload después de tener el recurso canónico. No acepta `householdId`, el identificador de destino o `type` aportados por el cliente para reenviarlos sin contraste. D2 describe el contrato implementado en v1 para `type: task`; D25 extiende la forma futura sin sobrecargar `taskId`. Hasta P3, cualquier `type: mission` o `type: recognition` cae en el fallback porque sus handlers no existen.

## 4. Handler unificado de navegación profunda

### Separación entre transporte y navegación

`NotificationService` debe limitarse a recibir y normalizar:

1. **Foreground:** `onMessage` muestra el banner local con el mismo `data` serializado. `onDidReceiveNotificationResponse` decodifica ese payload cuando se toca.
2. **Background:** `onMessageOpenedApp` aporta el `RemoteMessage` tocado.
3. **Terminated:** `getInitialMessage()` se consume una sola vez al arrancar.
4. Las tres fuentes llaman a `handleNotificationTap(rawData, source, messageId)`; no navegan directamente.

El handler publica una `NotificationIntent` a un coordinador conectado a la composición raíz. Si `MaterialApp`, la sesión o el shell todavía no están listos, el coordinador persiste el mínimo validado (`type`, `householdId`, identificador de destino, identidad de deduplicación y `receivedAt`) y lo procesa cuando se cumplen esas condiciones. No persiste título, cuerpo ni nombres. Así `NotificationService` no intenta leer Cubits ni usar un `BuildContext` inexistente durante bootstrap, y D22 sobrevive al proceso de login.

Cada intención lleva una identidad de deduplicación: primero `eventId`, después `RemoteMessage.messageId` y, como fallback, un hash estable de `(type, householdId, identificador, sentTime)`. Dentro de la ventana corta configurable de D24, repetir la misma identidad es no-op y una identidad distinta sustituye a la anterior. El `navigationRequestId` de la intención nueva invalida las respuestas en vuelo de la anterior.

### Resolución de una tarea

El caso `type: task` sigue este flujo server-authoritative:

1. Parsear y validar el contrato. Si falla, seleccionar Tareas, mostrar el copy de payload inválido y terminar.
2. Esperar a que `AuthCubit` determine la sesión. Si se requiere login, conservar la intención durable de D22; nunca navegar a un recurso household-scoped desde `AuthStatus.unknown` o `unauthenticated`.
3. Capturar un `navigationRequestId`. Cualquier respuesta posterior solo puede cambiar hogar o ruta si esa solicitud sigue vigente; esta guarda evita el mecanismo de respuesta tardía confirmado en TD-065 F0-01.
4. Resolver `householdId` mediante el backend. Si difiere del hogar activo y la persona todavía pertenece, activarlo, persistirlo como hogar actual, abandonar la sala anterior y unirse a la nueva sala autorizada.
5. Resolver la tarea mediante el nuevo `GET /api/households/:householdId/tasks/:taskId`. El endpoint queda detrás de auth y `requireMembership`, restringe el query al mismo `householdId` y excluye `isDeleted: true`.
6. Solo una respuesta válida abre la ruta interna de detalle con argumentos tipados. La tarea recibida se incorpora a la caché/Cubit mediante upsert; no se recorre el listado paginado para encontrarla.
7. Ante 400, 403 o 404, descartar cualquier resultado parcial del hogar solicitado, seleccionar la pantalla Tareas del hogar válido vigente y mostrar el copy D4. 403 y 404 comparten copy para no revelar si el recurso existe.
8. Ante error de red, consultar la caché del propietario de sesión y del mismo hogar. Si contiene la tarea, abrir `/tasks/:taskId` con el indicador **«Sin conexión · datos guardados {hace X}»**, derivado de un `cachedAt` persistido; no se presenta como dato actual. Si no existe, abrir Tareas y mostrar el toast exacto **«sin conexión, reintentar»**. Un 5xx conserva una superficie útil y retry; nunca presenta un spinner sin salida.

### Endpoint individual y permisos

Contrato propuesto:

```text
GET /api/households/:householdId/tasks/:taskId
Authorization: Bearer <access token>

200 { success: true, data: <Task poblada> }
```

El middleware valida autenticación y membresía antes del servicio. El servicio valida ambos ObjectId, consulta por hogar y tarea, excluye borradas y devuelve 404 si no hay coincidencia. Cualquier miembro actual puede **ver** la tarea, coherente con el listado actual. Editar o eliminar sigue restringido al creador o admin por Hard Rule 17; el payload nunca concede esa capacidad.

**Causa confirmada:** este endpoint y su método de repositorio no existen hoy. Son prerrequisitos de una resolución exacta y segura; depender solo de páginas ya cargadas dejaría tareas válidas fuera del alcance del deep-link.

### Sesión expirada y replay

Si el lookup recibe 401, `ApiService` intenta la rotación existente y reenvía la misma petición. Si la rotación funciona, el handler continúa. Si el servidor rechaza el refresh, el coordinador persiste la intención validada antes de que `SessionListeners` limpie estado y lleve a login.

Después de cualquier login exitoso, D22 obliga a consumir ese pendiente antes de la navegación ordinaria a Inicio: se vuelve a validar payload, usuario, membresía, hogar y recurso con la sesión nueva. Si sigue autorizado, abre `/tasks/:taskId`; si no, aplica D4. El registro durable se elimina solo al completar el detalle o un fallback terminal, y nunca se reutiliza como permiso. Un tap posterior dentro de la ventana D24 lo reemplaza.

## 5. Integración con el routing existente

### Ruta interna tipada y reutilizable

Se añade la ruta interna `/tasks/:taskId`, representada por `Routes.taskDetail` y `TaskDetailRouteArgs` tipado con el `householdId` canónico. `onGenerateRoute` comprueba nombre, parámetro y argumentos; valores ausentes o inválidos no caen en Splash, sino en el fallback seguro de Tareas.

La ruta recibe el `Task` ya resuelto y sus identificadores canónicos. El widget puede escuchar upserts posteriores del `TaskCubit`, pero no dispara un segundo lookup en paralelo al coordinador. No es modal: entra en el `Navigator` normal y Atrás vuelve a Tareas.

La lista, Home, calendario y recurrentes abren esa misma ruta de detalle en lugar de empujar directamente `TaskFormPage(task: task)`. El detalle ofrece **Editar** solo al creador o admin y entonces abre el formulario; cualquier miembro puede leer y completar según los permisos vigentes. Así el deep-link no crea una segunda superficie ni convierte la notificación en un atajo a edición.

No se crea una URL externa y no se construye una ruta a partir del string recibido en `type`. El dispatcher mantiene una tabla cerrada:

```text
task         + taskId        -> resolver hogar+tarea -> /tasks/:taskId
mission      + missionId     -> reservado P3, fallback en v1
recognition  + recognitionId -> reservado P3, fallback en v1
desconocido  -> fallback Tareas
```

### Selección del tab Tareas

El Home actual sigue siendo el destino inicial ordinario. Para deep-link y fallback se propone un controlador de navegación del shell —por ejemplo `MainNavigationCubit`— cuya acción `selectTasks()` fija el índice 1. `MainScaffold` observa ese estado en vez de ocultar toda la selección en `_index`.

El coordinador:

- conserva o reconstruye una sola instancia del shell;
- selecciona Tareas antes de abrir el detalle;
- coloca el detalle encima del shell, para que Atrás vuelva a Tareas;
- en fallback, cierra cualquier detalle inválido, deja Tareas visible y muestra el toast mediante un `ScaffoldMessenger` accesible desde la composición raíz.

Esto mantiene `Routes.main` y su tab Inicio como comportamiento normal; solo las intenciones de notificación seleccionan Tareas.

### Readiness y carreras

El coordinador no procesa hasta que concurran:

- `AuthStatus.authenticated` con usuario conocido;
- `Routes.navigatorKey.currentState` disponible;
- finalización del bootstrap de hogar/socket;
- aplicación de la ventana de deduplicación D24, donde la intención más reciente es la única vigente.

Cada await comprueba `navigationRequestId` y `userId`. Un logout, cambio de cuenta, tap posterior o destrucción del widget invalida la solicitud anterior. Los estados de resolución deben distinguir **«Abriendo tarea…»**, error con retry y fallback; se prohíbe reutilizar el spinner indefinido descrito por TD-065 F0-02.

## 6. Casos borde

| Caso | Comportamiento esperado |
|------|-------------------------|
| Tarea eliminada o purgada | El lookup individual excluye soft-deleted y devuelve 404. Se abre Tareas y aparece el copy D4. No se abre Papelera ni se restaura nada. |
| Usuario expulsado después del envío | `requireMembership` devuelve 403 al resolver hogar/tarea. No se muestra título ni dato cacheado del hogar expulsado; fallback al hogar vigente y copy D4. |
| Usuario expulsado y dispositivo offline | El cliente no puede observar todavía la revocación. D23 prevalece: si la tarea está cacheada la muestra como dato no verificado con frescura visible; al recuperar red, el 403 cierra el detalle, purga esa superficie household-scoped y aplica D4. |
| Notificación de otro hogar válido | El handler valida membresía, activa ese hogar, cambia la sala socket de forma autorizada, carga la tarea y abre el detalle. |
| Pareja `householdId`/`taskId` inconsistente | El query household-scoped no encuentra la tarea y responde 404 aunque el id exista en otro hogar. Fallback D4 sin revelar el otro hogar. |
| Payload incompleto o corrupto | Se rechaza localmente, no se hace request y se abre Tareas con el copy de payload inválido. |
| `type` desconocido o futuro aún no implementado | El dispatcher no inventa rutas; abre Tareas. Se registra telemetría sin incluir título, nombre ni contenido del push. |
| App terminated con sesión válida | `getInitialMessage` encola una sola intención, Splash restaura sesión/hogar y el coordinador la procesa al estar listo. |
| App terminated con sesión expirada | Se persiste la intención, login gana y, tras autenticarse, el coordinador la reproduce y revalida antes de abrir detalle o fallback; no deja al usuario en Inicio. |
| Tap en banner de foreground | El callback de `flutter_local_notifications` decodifica el mismo payload y llama al handler común; no navega desde `onMessage` antes del tap. |
| Dos callbacks para el mismo mensaje | `eventId`/`messageId` dentro de la ventana D24 deduplica; la tarea se abre una sola vez. |
| Dos notificaciones distintas en rápida sucesión | Last-write-wins: la última sustituye el pendiente e invalida por `navigationRequestId` cualquier respuesta anterior. No se apilan detalles. |
| Sin conexión al tocar, tarea cacheada | Se abre `/tasks/:taskId` desde la caché del propietario/hogar y se muestra **«Sin conexión · datos guardados {hace X}»**. Al recuperar red se revalida y reconcilia. |
| Sin conexión al tocar, tarea no cacheada | Se abre Tareas y se muestra el toast exacto **«sin conexión, reintentar»**. |
| Usuario sin hogar activo | Si el payload es válido y la membresía existe, se activa ese hogar. Si no, se muestra el setup de hogar; no se mantiene un spinner ni se crea membresía desde el deep-link. |
| Notificación local programada de recordatorio | Fuera del alcance FCM de v1. **Pregunta abierta:** reutilizar después el mismo contrato para recordatorios locales, añadiendo `householdId` a su payload. |

## 7. Tests nuevos y plan de commits atómicos

### Backend

- los pushes de asignación y completado contienen exactamente `type`, `householdId` y `taskId` canónicos como strings;
- el constructor tipado rechaza tipos o identificadores ausentes antes de enviar;
- `GET .../tasks/:taskId` devuelve una tarea activa del mismo hogar a cualquier miembro actual;
- devuelve 400 para ObjectId mal formado, 403 para ex-miembro y 404 para tarea inexistente, borrada o perteneciente a otro hogar;
- la pareja hogar/tarea no filtra existencia cross-household;
- el endpoint conserva el envelope `{ success, data?, error? }` y no altera permisos de edit/delete;
- los tests FCM verifican que el `data` multicast conserva el contrato completo;
- productores futuros de misión/reconocimiento deben tener pruebas de contrato antes de activar sus casos del dispatcher.

### Frontend

- parser acepta el payload mínimo y rechaza cada campo ausente, vacío, de tipo incorrecto o con ObjectId inválido;
- `onDidReceiveNotificationResponse`, `onMessageOpenedApp` y `getInitialMessage` entregan la misma `NotificationIntent` al mismo handler;
- `onMessage` solo pinta el banner; no navega antes del tap;
- el payload local se serializa/decodifica sin pérdida;
- terminated persiste el intent hasta que sesión, hogar, socket y navigator estén listos;
- sesión rechazada conserva el deep-link durante login y lo reproduce después de autenticarse, sin pasar por Inicio;
- mensaje repetido por dos fuentes produce una sola navegación dentro de la ventana D24;
- dos mensajes distintos rápidos aplican last-write-wins y solo el último puede cambiar hogar o ruta;
- hogar actual y otro hogar válido resuelven la tarea correcta y seleccionan el tab Tareas;
- 400/403/404, tarea borrada y payload corrupto terminan en Tareas con el copy exacto, sin crash ni pantalla vacía;
- error de red abre la tarea cacheada con `cachedAt` y frescura visible; sin caché aplica el toast exacto sobre Tareas;
- refresh exitoso continúa; refresh rechazado navega a login, conserva el pendiente y lo revalida tras autenticarse;
- la expiración de sesión no pierde el pendiente; un tap posterior dentro de D24 sustituye la intención anterior, y cualquier login vuelve a autorizarla desde cero;
- `/tasks/:taskId` con argumentos mal tipados cae en Tareas, nunca en Splash;
- lista, Home, calendario y recurrentes reutilizan el mismo detalle, sin modal ni acceso directo involuntario al editor;
- Atrás desde el detalle vuelve al tab Tareas; el arranque ordinario sigue abriendo Inicio;
- destinatario sin permiso de edición puede ver detalle, pero no obtiene acciones prohibidas;
- evento socket que actualiza o elimina la tarea converge con el detalle sin duplicar el lookup inicial.

### Contrato e integración

- prueba de contrato compartido para `type`, `householdId`, identificador por tipo y `schemaVersion`; v1 solo enruta `taskId`;
- matriz foreground/background/terminated con la misma expectativa de destino;
- prueba de carrera: hogar A lento, tap posterior a hogar B y respuesta de A al final; B permanece activo;
- prueba de seguridad: id de tarea real acompañado por otro `householdId` nunca abre ni revela la tarea;
- prueba de deduplicación y telemetría sin PII.

### Plan de commits de implementación

1. `feat(backend): completar payload y lectura individual de tarea`
2. `test(backend): cubrir contrato y autorización de deep-link`
3. `feat(frontend): unificar intents de notificación`
4. `feat(frontend): integrar detalle de tarea con routing del shell`
5. `test(frontend): cubrir deep-link en ciclos de vida y fallbacks`
6. `docs: documentar contrato de navegación de notificaciones`

El despliegue es aditivo: primero backend añade `householdId` y el GET individual; los clientes antiguos ignoran el campo nuevo. Después se publica el cliente que solo activa deep-link para payload completo. No se habilitan misión o reconocimiento hasta que sus rutas y contratos estén implementados.

## 8. Riesgos, rollback y pruebas manuales

### Riesgos y rollback

| Riesgo | Mitigación | Rollback |
|--------|------------|----------|
| Abrir datos de otro hogar | Lookup household-scoped, `requireMembership`, exclusión de borradas y revalidación tras cada tap. | Desactivar el dispatcher exacto y conservar fallback a Tareas. |
| Carreras cambian al hogar equivocado | `navigationRequestId`, `userId` capturado y guardas tras cada await, alineadas con TD-065. | Desactivar cambio de hogar desde notificación; fallback en el hogar actual. |
| Tap duplicado o ráfaga apila pantallas | Ventana corta, dedupe por evento/mensaje y last-write-wins por `navigationRequestId`. | Reducir la ventana a dedupe de identidad exacta y conservar fallback a Tareas. |
| Bootstrap o sesión dejan pantalla vacía | Pendiente durable, estados explícitos, replay tras login, retry y prioridad de la autenticación. | Volver al handler genérico que selecciona Tareas, limpiando el pendiente. |
| Payloads de versiones distintas | Parser versionado, mínimo estricto y campos desconocidos ignorados. | Aceptar solo `type: task` completo; el resto cae en fallback. |
| Ruta de detalle expone edición indebida | `/tasks/:taskId` separa lectura de `TaskFormPage`; las acciones derivan de permisos server-authoritative. | Ocultar acciones; conservar lectura. |
| Caché offline está obsoleta | Indicador con `cachedAt`, ámbito por propietario/hogar y revalidación al reconectar. | Desactivar apertura cacheada y usar el toast offline sobre Tareas. |
| La membresía se revocó mientras el dispositivo estaba offline | D23 identifica el contenido como no verificado; el primer 403 al reconectar cierra el detalle y purga la superficie del hogar. | Desactivar apertura cacheada hasta recuperar conectividad. |
| Push real no reproducible en CI | Unit/widget/contract tests con dobles; validación física separada por TD-049. | No afecta listas ni tareas; desactivar deep-link por feature flag. |
| Telemetría filtra contenido | Registrar solo `type`, resultado, fuente y códigos; no título, cuerpo, nombres ni ids completos. | Desactivar telemetría del handler. |

Flags recomendados: `notificationDeepLinks` para el dispatcher y `notificationTaskDetail` para la ruta individual. El rollback no exige retirar el payload enriquecido ni el endpoint de lectura; basta devolver todos los taps al fallback de Tareas.

### Pruebas manuales

1. Con dos dispositivos y dos miembros, asignar una tarea y tocar el push en foreground, background y terminated; los tres abren la misma tarea.
2. Repetir con una tarea completada por otra persona y comprobar que el creador llega al mismo detalle.
3. Verificar que un arranque normal sigue abriendo Inicio, que `/tasks/:taskId` no es modal y que Atrás desde el deep-link vuelve a Tareas.
4. Abrir la misma tarea desde la lista, Home, calendario y recurrentes; todas deben usar el mismo detalle, y **Editar** solo debe aparecer con permiso.
5. Tocar una notificación de otro hogar del mismo usuario; debe cambiar al hogar correcto, cambiar la sala socket y abrir la tarea.
6. Eliminar la tarea después de recibir el push y antes del tap; debe aparecer el copy D4 sobre Tareas.
7. Expulsar al destinatario después del push; tocarlo y comprobar 403, ausencia de datos del hogar y fallback D4.
8. Alterar `taskId`, `householdId`, `type` y eliminar cada clave por separado; nunca debe haber request inválida, crash, Splash ni pantalla vacía.
9. Poner un `taskId` real junto al `householdId` de otro hogar y verificar que no se revela título ni existencia.
10. Caducar el access token con refresh válido; tocar y confirmar que la rotación continúa al detalle una sola vez.
11. Revocar también el refresh; tocar desde terminated, iniciar sesión y comprobar que el pendiente se reproduce y revalida sin dejar al usuario en Inicio.
12. Cortar la red con la tarea cacheada; debe abrirse con **«Sin conexión · datos guardados {hace X}»** y reconciliar al volver. Repetir sin caché y comprobar el toast **«sin conexión, reintentar»** sobre Tareas.
13. Tocar dos veces el mismo push y provocar también entrega por callbacks solapados; debe existir una sola ruta de detalle.
14. Enviar dos pushes distintos dentro de la ventana, invertir sus respuestas y comprobar que solo prevalece el último.
15. Enviar `type: mission` con `missionId` y `type: recognition` con `recognitionId`; v1 debe reconocer la forma reservada pero aplicar fallback, sin abrir destinos inexistentes.
16. Actualizar o borrar la tarea desde el segundo dispositivo mientras el detalle está abierto; el primer cliente converge o aplica fallback sin quedar vacío.
17. Tras completar TD-049, el dueño ejecuta la matriz anterior en dispositivo Android e iOS reales, incluyendo cold start, app expulsada de memoria, permiso denegado y token rotado.

## 9. Preguntas abiertas

1. Inclusión futura de recordatorios locales programados en el mismo contrato; fuera del alcance FCM v1.

## 💡 Proposed Improvements

- Centralizar la creación y el parseo del payload en contratos tipados y versionados; no repetir mapas libres en cada productor.
- Implementar `/tasks/:taskId` como detalle común para notificaciones y listas, separando lectura de la acción explícita de editar.
- Extraer la navegación de `NotificationService` a un coordinador con readiness, deduplicación y guardas de generación.
- Persistir solo el intent mínimo, protegerlo por propietario de sesión y eliminarlo después de un resultado terminal.
- Añadir `cachedAt` a la caché de tarea y reconciliar el detalle offline al recuperar conexión.
- Corregir al implementar la descripción obsoleta de PDR-008: el shell actual abre Inicio, no Tareas.
- Aplicar al flujo las protecciones de respuestas tardías y carga fallida identificadas por TD-065, sin esperar a que una respuesta antigua cambie el hogar activo.
- Instrumentar resultados agregados (`opened`, `fallback_invalid`, `fallback_forbidden`, `fallback_missing`, `network_error`) sin contenido ni identificadores completos.
- Extender el mismo handler a recordatorios locales únicamente después de aprobar su payload y su política offline.

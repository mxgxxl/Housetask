# TD-071 — Diseño de reconocimiento entre miembros

> Estado: Open. Prioridad: Medium. Diseño documental; no implementa código, tests ni CI. Cierra el item 4 de P2 del roadmap funcional (punto 7 del PDF del dueño).

## 0. Alcance y criterio de evidencia

El reconocimiento permite agradecer una tarea completada con una señal pequeña y positiva. No crea una red social, conversación, competición, moneda ni evaluación de personas.

- **Causa confirmada:** comportamiento o dato visto en el código actual.
- **Hipótesis:** consecuencia inferida que requiere medición o reproducción.
- **Pregunta abierta:** decisión que este prompt, el código y los PDR no cierran; no se decide aquí.

El alcance de v1 es una reacción cerrada a una completación ya confirmada por el servidor, su persistencia histórica, su entrega suave al destinatario y su proyección en actividad reciente y perfil. Quedan fuera comentarios, hilos, menciones, reacciones a compras o hitos, ranking, recompensas económicas y moderación de texto libre.

## 1. Estado actual

### Señales cooperativas existentes

**Causa confirmada:** `Task` conserva `completedAt` y `completedBy`. `TaskTile` muestra «Completada por {miembro}» y, si quien completó ya no pertenece al hogar, «Completada por Ex-miembro». Esa atribución informa quién hizo la tarea, pero no permite agradecerle.

**Causa confirmada:** `completeTask` notifica por push al **creador de la tarea** cuando otra persona la completa y emite `task:completed` a la sala del hogar. El mensaje actual («{nombre} completó: {tarea}») comunica una completación; no es reconocimiento dirigido a quien hizo el trabajo.

**Causa confirmada:** el realtime existente distribuye cambios de tareas, compra, hogar, lotes y mascota. No existe el evento `member.reaction` ni una familia de eventos sociales.

**Causa confirmada:** Perfil muestra la identidad del usuario actual, la lista básica de miembros y el acceso a estadísticas. No hay ficha detallada por miembro, contador de agradecimientos ni superficie equivalente.

### Carencias confirmadas

**Causa confirmada:** no existe modelo o colección de reacciones, endpoint para crearlas o cambiarlas, índice de unicidad, preferencia de notificación, UI de emojis, contador en perfil ni test de reconocimiento.

**Causa confirmada:** el llamado timeline actual implementa PDR-003 como una agenda de tareas agrupada por `dueDate`; no es un registro de eventos. TD-070 diseña `recentActivity`, pero su event log y su feed todavía no existen. Las reacciones no deben insertarse como si fueran tareas fechadas en esa agenda.

**Causa confirmada:** hay dos caminos que pueden completar una tarea. `PATCH .../complete` emite `task:completed`; el `PATCH` genérico con `status: completed` emite `task:updated`. Ambos pueden establecer `completedAt` y `completedBy`. Además, una tarea completada puede volver a `pending`, lo que limpia esos campos, y completarse de nuevo.

**Causa confirmada:** el frontend completa de forma optimista y, sin conexión, encola la mutación. Hasta recibir o sincronizar la respuesta canónica, el `completedBy` y el instante de completación locales no prueban que el servidor aceptara la operación.

**Causa confirmada:** el servicio de notificaciones no tiene preferencias granulares. La entrega push real sigue condicionada por la configuración operativa de Firebase descrita en TD-049.

**Causa confirmada:** el handshake socket une salas a partir de los hogares del usuario, pero `household:join` acepta después un identificador no vacío sin revalidar la membresía. `member.reaction` no puede publicarse de forma segura en una sala obtenida por ese camino hasta corregir la autorización señalada por TD-070/TD-001.

**Hipótesis:** si cada reacción causara a la vez una recarga del feed, otra del perfil y otra de Salud, una ráfaga de agradecimientos generaría peticiones redundantes y resultados fuera de orden. La integración propuesta reutiliza una sola fuente durable y la agregación de invalidaciones de TD-070 D15.

## 2. Decisiones aprobadas

1. **D1 — Conjunto cerrado.** Solo se admiten cuatro reacciones: 👍, 🎉, ❤️ y 💪. La API recibe un código enumerado y el cliente lo traduce al emoji; no existe texto libre.
2. **D2 — Objeto reconocido.** Solo se puede reaccionar a tareas del mismo hogar cuyo estado canónico sea `completed`.
3. **D3 — Entrega suave.** La reacción llega al miembro que completó la tarea y genera una notificación suave. No abre hilo, respuestas ni conversación.
4. **D4 — Histórico permanente.** La reacción permanece visible indefinidamente en el histórico de actividad y no se puede retirar. No hay `DELETE` ni expiración TTL.
5. **D5 — Una reacción por persona y tarea completada.** Cada persona tiene como máximo una reacción por tarea: repetir el mismo emoji es no-op y elegir otro actualiza esa fila sin acumular contadores.
6. **D6 — Sin economía.** Reaccionar es gratis; no gasta monedas ni concede monedas, XP, recompensas o progreso de misión.
7. **D7 — Contador individual y no competitivo.** El perfil muestra «Reacciones recibidas esta semana». No expone comparación, posición, máximo, ranking ni leaderboard.
8. **D8 — Actividad reciente.** La reacción se incorpora como evento del timeline de actividad y alimenta `recentActivity` de TD-070. Extiende la taxonomía de D11 con `member_reaction`; no altera la agenda de tareas de PDR-003.

## 3. Modelo de datos e integridad

### Colección `memberreactions`

Modelo propuesto `MemberReaction`, con `timestamps: true` y el mismo `toJSON` seguro que los modelos públicos:

| Campo | Tipo | Regla |
|-------|------|-------|
| `householdId` | ObjectId ref `Household` | Obligatorio; ámbito de autorización y partición. |
| `taskId` | ObjectId ref `Task` | Obligatorio; la tarea debe pertenecer al mismo hogar y estar completada. |
| `reactorUserId` | ObjectId ref `User` | Obligatorio; miembro actual que agradece. |
| `recipientUserId` | ObjectId ref `User` | Obligatorio; copia canónica de `Task.completedBy` al crear la reacción. |
| `emojiCode` | enum | `thumbs_up`, `celebration`, `heart`, `strength`; el servidor rechaza cualquier otro valor. |
| `taskTitleSnapshot` | String | Título escapado al renderizar; mantiene comprensible el histórico si la tarea se purga después. |
| `taskCompletedAtSnapshot` | Date | Completación canónica a la que se vinculó la reacción. |
| `version` | Number | Empieza en 1 y aumenta al cambiar el emoji; ordena sockets concurrentes. |
| `createdAt` | Date | Instante original de la reacción; ordena el evento y el contador semanal. |
| `updatedAt` | Date | Instante del último cambio de emoji; no crea otro evento ni incrementa el contador. |

No se guarda texto suministrado por el usuario, valor económico, `deletedAt` ni contador mutable. Los nombres y avatares se resuelven desde usuarios/membresías al leer; un miembro ausente se representa como «Ex-miembro», conservando el patrón de TD-018 sin retener una copia adicional de su perfil.

### Índices

| Índice | Finalidad |
|--------|-----------|
| `{ householdId: 1, taskId: 1, reactorUserId: 1 }`, `unique: true` | D5 se hace cumplir en base de datos incluso ante concurrencia. |
| `{ householdId: 1, createdAt: -1, _id: -1 }` | Paginación keyset estable del feed del hogar. |
| `{ householdId: 1, recipientUserId: 1, createdAt: -1, _id: -1 }` | Contador semanal y actividad recibida por miembro. |
| `{ taskId: 1, createdAt: 1 }` | Resumen de reacciones de una tarea completada. |

El índice único es la última barrera contra duplicados; una comprobación previa sin índice no basta porque dos dispositivos pueden reaccionar a la vez.

### Comando server-authoritative

Contrato propuesto:

```text
PUT /api/households/:householdId/tasks/:taskId/reaction
{ "emojiCode": "heart" }
```

`PUT` expresa el recurso único de la persona autenticada sobre esa tarea. La repetición exacta devuelve la representación vigente con HTTP 200, no cambia `updatedAt`, no vuelve a notificar y no reemite socket. Un emoji distinto actualiza la fila existente de forma atómica; la primera elección la crea. Si la implementación optase por `POST`, la Hard Rule 13 obligaría además a `Idempotency-Key`; no se propone `POST` en v1.

El servicio, nunca el controlador, ejecuta en este orden:

1. Valida `emojiCode` contra el enum cerrado; no acepta el glifo como texto arbitrario.
2. Verifica que `reactorUserId` es miembro actual del `householdId` usando la autoridad vigente de TD-001.
3. Lee la tarea por `{ _id: taskId, householdId, isDeleted: false }` y exige `status: completed`, `completedAt` y `completedBy` canónicos.
4. Verifica que `recipientUserId = completedBy` sigue siendo miembro del hogar y que no coincide con quien reacciona. La UI también oculta la acción propia, pero el servidor es autoritativo.
5. Hace `findOneAndUpdate` con upsert sobre la clave única, preservando `createdAt`, `recipientUserId`, título e instante de completación cuando solo cambia el emoji.
6. Clasifica el resultado como `created`, `updated` o `unchanged`; solo los dos primeros publican realtime.
7. Tras confirmar la escritura, emite realtime; una creación intenta además la notificación según preferencias. El aviso ante un cambio de emoji queda sujeto a la pregunta abierta correspondiente. Un fallo de push se registra, pero no revierte la reacción ya durable ni la respuesta HTTP.

Los endpoints de lectura del feed y del perfil vuelven a aplicar membresía. El cliente nunca envía `recipientUserId`, contador ni snapshots: derivan de la tarea y el servidor.

### Contador de perfil

«Reacciones recibidas esta semana» cuenta filas distintas cuyo `recipientUserId` es el miembro, con `createdAt` dentro de la semana natural vigente del hogar. Un cambio de emoji no aumenta el valor. La zona horaria debe ser la misma IANA usada por P1/PDR-013 y TD-069; no se calcula con la zona local de cada dispositivo.

Puede servirse como agregado de la lectura de perfil o como bloque de un endpoint de actividad. En ambos casos la respuesta incluye `weekKey`, `periodStart`, `periodEnd`, `count` y `generatedAt`, para que la UI no mezcle semanas ni datos de hogares. No se devuelve una lista comparativa de miembros.

## 4. Completación y ciclo de vida de la reacción

### Única condición habilitante

La UI habilita el selector únicamente después de recibir una tarea sincronizada con `status: completed`, `completedAt` y `completedBy`. La apariencia optimista no basta. El backend repite toda la validación y responde con el envelope habitual:

- `404` si la tarea no existe, fue eliminada o no pertenece al hogar visible para esa persona;
- `409` si existe en el hogar pero todavía no está completada o la completación fue revertida;
- `403` si la persona autenticada ya no pertenece al hogar;
- `400` para un `emojiCode` fuera del conjunto cerrado.

No se exponen diferencias que permitan consultar recursos de otro hogar.

### Dos caminos actuales de completación

**Causa confirmada:** reaccionar solo al evento socket `task:completed` dejaría fuera completaciones hechas mediante el `PATCH` genérico, que emite `task:updated`. Por ello el contrato no toma el nombre del socket como verdad: toma el estado canónico de la tarea y sus metadatos tras el pull/upsert del cliente.

Como mejora previa o simultánea, ambos caminos deberían producir un mismo evento de dominio de completación. Hasta entonces, el frontend reevalúa la elegibilidad después de `task:completed`, de un `task:updated` que cruce a `completed` y de la respuesta de sincronización offline.

### Cambio y permanencia

- Primer emoji: crea una fila, un evento visible y una notificación.
- Mismo emoji: no-op idempotente, sin segundo evento ni notificación.
- Emoji distinto: actualiza la fila y el item existente del feed; no suma otra reacción recibida ni genera una segunda entrada. Si debe volver a avisar al destinatario es una pregunta abierta.
- No hay retirada. La reacción sobrevive a la salida posterior de cualquiera de sus participantes y a la purga posterior de la tarea mediante snapshots mínimos.
- Las reacciones históricas se eliminan únicamente al destruir el hogar como recurso household-scoped, conforme al hard delete aprobado en TD-067; «indefinidamente» significa durante la vida del hogar.

## 5. Realtime y notificación suave

### Evento `member.reaction`

Después de una creación o cambio confirmado, el servidor emite a la sala autorizada del hogar:

```text
member.reaction {
  eventId,
  operation: "created" | "updated",
  householdId,
  reactionId,
  taskId,
  reactor: { id, name, avatarUrl },
  recipientUserId,
  emojiCode,
  emoji,
  taskTitle,
  version,
  createdAt,
  updatedAt
}
```

`eventId` se deriva de `reactionId` y `version`; ambos permiten idempotencia y orden en el cliente. El feed hace upsert y descarta versiones antiguas; nunca inserta dos veces la misma fila por reconexión. La emisión al hogar permite actualizar el histórico y el resumen de tarea de todos los dispositivos, pero solo el cliente cuyo usuario coincide con `recipientUserId` puede mostrar el indicador personal cuando corresponda.

Copy exacto del indicador in-app:

> **{Nombre} te envió {emoji} por «{Tarea}»**

Es un banner/snackbar discreto, no bloqueante, sin modal, campo de respuesta ni CTA urgente. Tocar el indicador abre el item de actividad o la tarea completada si sigue disponible; si ya no existe, abre el histórico conservado.

Antes de publicar este evento, `household:join` debe revalidar la membresía actual; no basta el identificador aportado por el cliente. Al salir o ser expulsado, el socket abandona la sala conforme al ciclo de membresía.

### Preferencia granular

Se añade la categoría personal `memberRecognitionNotifications`, independiente de recordatorios, asignaciones y completaciones. Desactivarla impide el push y el indicador personal, pero no borra la reacción, no la oculta del feed compartido y no evita que el contador se actualice. Así la preferencia regula la interrupción, no reescribe el histórico del hogar.

La entrega sigue este orden:

1. socket actualiza silenciosamente el feed en todos los clientes conectados;
2. el destinatario conectado ve como máximo un indicador suave por `reactionId`/versión;
3. si está en segundo plano y tiene la categoría activa, se intenta push de baja prioridad;
4. al volver, el pull reconcilia el estado durable y deduplica cualquier combinación socket/push.

Copy exacto del push:

> **Un agradecimiento en casa**
>
> **{Nombre} te envió {emoji} por «{Tarea}»**

No se envía al autor de la reacción, no incluye saldo ni invita a responder. El envío push real queda bloqueado operativamente por TD-049; el registro, el feed y el realtime in-app no dependen de que Firebase esté configurado.

## 6. Integración con TD-070 y el timeline

### Fuente única de actividad

D8 añade `member_reaction` a los eventos admitidos por TD-070 D11. No se calcula actividad leyendo notificaciones ni `updatedAt` de tareas. La fila durable de `MemberReaction` —o su proyección idempotente con el mismo `eventId`— alimenta:

- el item paginado del feed de actividad;
- la actividad del componente `recentActivity` de Salud;
- el contador semanal del destinatario;
- el resumen ligero de la tarea completada.

Esto evita cuatro fuentes divergentes. `createdAt` fija el día activo y la posición histórica; cambiar el emoji actualiza el item pero no fabrica otro día de actividad. Al ser una interacción cooperativa y no una compra, encaja en D11 y en la exclusión de acciones puras de economía.

El timeline de actividad debe ser una proyección/event log separado de la agenda PDR-003. Su lectura usa cursor estable `(createdAt, _id)` y devuelve tipos heterogéneos con un contrato versionado. Para `member_reaction`, el copy exacto del item es:

> **{Nombre} envió {emoji} a {Destinatario} por «{Tarea}»**

La reacción sigue consultable por paginación mientras exista el hogar. La tarjeta `recentActivity` puede mostrar solo su ventana resumida sin borrar el histórico subyacente.

### D15: invalidación sin ráfagas

Tras confirmar una creación o cambio, el servidor emite `member.reaction` para el upsert local y agrega `recentActivity` a la invalidación compacta de Salud. No hace falta que el listener de reacción dispare además un GET completo por su cuenta.

El futuro `HealthCubit` aplica exactamente TD-070 D15: debounce/throttle y ventana configurable; una ráfaga produce un pull, y durante un pull solo deja un refresco posterior. El feed puede incorporar el payload directamente y reconciliar por cursor al volver a primer plano. El perfil invalida únicamente el contador del `recipientUserId`; un cambio de emoji no lo invalida porque el número no varía.

La implementación completa del componente Salud permanece ligada a TD-070 y sus dependencias TD-001/TD-066/TD-068/TD-069. El feed de reacciones puede construirse antes, pero compartir la proyección de actividad evita duplicar el cálculo cuando TD-070 se implemente.

## 7. Casos borde

| Caso | Comportamiento esperado |
|------|-------------------------|
| Miembro que sale o es expulsado | Las reacciones pasadas permanecen como histórico. Se renderiza «Ex-miembro» donde ya no pueda resolverse la membresía. No se admiten nuevas reacciones de quien salió ni nuevas reacciones dirigidas a un destinatario que ya no pertenece al hogar. |
| Reacción antes de la completación | UI oculta/deshabilita la acción; el servidor la bloquea aunque el cliente esté manipulado. El nombre del evento socket por sí solo no prueba la completación. |
| Hogar de una persona | Se oculta la UI porque no existe otro miembro que pueda reconocer o recibir. El servidor bloquea la autorreacción. Perfil muestra el contador sin comparación; normalmente será 0. |
| Tarea completada offline | La UI espera a que la cola sincronice y reciba la tarea canónica. Solo entonces ofrece reaccionar; un intento anticipado no se almacena contra una completación local. |
| Dos dispositivos de la misma persona | El índice único y el upsert producen una sola fila. Los clientes hacen upsert por `reactionId`; repetir el mismo emoji no reemite efectos. |
| Cambio de emoji concurrente | Prevalece la última escritura aceptada por el servidor; el feed converge por `updatedAt`/versión. No cambia el contador. |
| Tarea borrada después | La reacción histórica sigue legible con `taskTitleSnapshot`; ya no ofrece navegación a la tarea. No se puede crear una reacción nueva sobre una tarea eliminada. |
| Sin conexión después de una completación ya sincronizada | El histórico cacheado se muestra como stale. El envío offline de una reacción no se promete en v1 hasta resolver la pregunta abierta correspondiente; la UI conserva la elección solo si existe una operación durable e idempotente. |
| Usuario desactiva notificaciones | No recibe indicador personal ni push posteriores, pero la reacción sigue en el feed y cuenta en su perfil. |
| Ráfaga de reacciones | El feed hace upserts locales y Salud agrupa invalidaciones según D15; no se lanza un pull por evento y componente. |

## 8. Preguntas abiertas

1. **Reapertura y nueva completación.** El código permite volver una tarea a `pending` y completarla después, incluso por otra persona. ¿D5 identifica la reacción por documento de tarea durante toda su vida o por un evento inmutable de completación? **Recomendación:** introducir `completionId`/versión server-authoritative y aplicar la unicidad a `(completionId, reactorUserId)` antes de habilitar reconocimiento en tareas reabiertas; evita reasignar silenciosamente una reacción histórica a otra persona.
2. **Ubicación completa del feed.** D8 fija que la reacción aparece en actividad reciente, pero no decide si el histórico paginado se abre desde la tarjeta de Salud, vive en una pantalla propia o se integra en otra navegación. **Recomendación:** abrirlo desde `recentActivity` de Salud sin sustituir la agenda de Tareas PDR-003.
3. **Valor inicial de la preferencia.** Se exige control granular, pero no se aprueba si `memberRecognitionNotifications` nace activada o desactivada. **Recomendación:** activada con aviso suave in-app y push condicionado al consentimiento/configuración de notificaciones del sistema.
4. **Envío offline de la reacción.** El caso aprobado exige esperar a sincronizar una completación offline, pero no define si una reacción posterior puede encolarse sin red. **Recomendación:** habilitarlo solo cuando la cola pueda persistir un `PUT` idempotente y reconciliar cambios de emoji; hasta entonces, pedir conexión sin afirmar que se guardó.
5. **Aviso al cambiar el emoji.** D3 exige notificación y D5 permite cambiar la reacción, pero no determinan si cada cambio vuelve a interrumpir al destinatario. **Recomendación:** notificar solo la creación; los cambios actualizan socket, feed y estado visible sin nuevo indicador ni push, evitando alternancias molestas.

## 9. Tests nuevos y plan de commits atómicos

### Backend

- modelo: acepta los cuatro códigos, rechaza cualquier otro y crea los índices previstos;
- servicio/API: exige membresía actual, hogar coincidente, tarea no eliminada y completación canónica;
- bloquea autorreacción, hogar unipersonal, tarea pendiente, tarea ajena y destinatario que ya salió;
- primera reacción crea; mismo emoji es no-op; emoji distinto actualiza la misma fila;
- carrera concurrente desde dos dispositivos deja una sola fila por índice único;
- repetir una operación no duplica socket, push, feed ni contador;
- `member.reaction` solo se emite tras persistir y únicamente a una sala con join autorizado;
- preferencias desactivadas omiten indicador/push sin ocultar el registro;
- el comportamiento de notificación al cambiar emoji queda cubierto cuando se apruebe la pregunta abierta correspondiente;
- fallo de push no revierte la reacción;
- contador usa semana natural y `createdAt`; un cambio de emoji no suma;
- salida de miembro y purga de tarea conservan un histórico renderizable;
- destrucción de hogar elimina las reacciones household-scoped conforme a TD-067;
- ambas rutas actuales de completación permiten reaccionar solo después de observar estado canónico;
- reabrir/recompletar queda cubierto al implementar la decisión pendiente de `completionId`.

### Frontend

- selector muestra exactamente 👍 🎉 ❤️ 💪 y nunca campo de texto;
- UI oculta reacción propia y en hogar unipersonal;
- completación optimista/offline no habilita el selector antes de sincronizar;
- respuesta y sockets repetidos hacen upsert de una sola reacción;
- cambiar emoji sustituye el seleccionado y no incrementa contador ni inserta otro item;
- destinatario ve el copy suave exacto; el resto solo actualiza feed/tarea;
- preferencia desactivada suprime el indicador personal;
- miembro ausente y tarea purgada muestran histórico seguro sin enlace roto;
- `member.reaction` actualiza el feed y agrupa la invalidación de Salud sin ráfaga de pulls;
- reconexión y caché stale convergen con el servidor sin duplicados;
- perfil muestra solo el contador propio/semanal y nunca ranking.

### Contrato e integración

- prueba de contrato del enum, envelope y payload `member.reaction`;
- prueba de transición `task:updated` a completada además de `task:completed`;
- prueba con reloj/zona IANA en el límite domingo-lunes;
- prueba de burst: varias reacciones dentro de la ventana D15 causan un pull de Salud y como máximo uno trailing;
- prueba de deduplicación socket + push por `reactionId`/versión.

### Plan de commits de implementación

1. `feat(backend): añadir modelo y API de reacciones de miembros`
2. `test(backend): cubrir integridad e idempotencia de reacciones`
3. `feat(backend): publicar reacción y preferencia de notificación`
4. `feat(frontend): mostrar reacciones en tareas y actividad`
5. `feat(frontend): añadir preferencia y contador semanal`
6. `test(frontend): cubrir reconocimiento realtime y offline`
7. `docs: documentar contrato de reconocimiento entre miembros`

Cada parada debe ser desplegable con la superficie oculta por feature flag hasta que escritura, lectura, autorización, deduplicación y rollback estén disponibles conjuntamente.

## 10. Riesgos y rollback

| Riesgo | Mitigación | Rollback |
|--------|------------|----------|
| Convertir el reconocimiento en competición | Conjunto cerrado, contador solo individual, sin comparativas ni ordenación. | Ocultar contador y selector por feature flag; conservar datos. |
| Filtrar actividad a una sala no autorizada | Revalidar cada join y cada endpoint contra la autoridad vigente de membresía. | Desactivar emisión/feature; mantener lectura API autorizada. |
| Duplicar reacciones o avisos | Índice único, `PUT`, no-op exacto y dedupe por id/versión. | Desactivar notificaciones; recomponer feed desde filas únicas. |
| Asociar una reacción a la persona equivocada tras reabrir | Resolver la pregunta de `completionId`; nunca confiar en destinatario cliente. | Ocultar reacción en tareas reabiertas hasta migrar la identidad de completación. |
| Ráfagas de red y batería | Upsert local, invalidación compacta y D15. | Desactivar invalidación realtime y usar pull al entrar/volver. |
| Histórico indefinido aumenta almacenamiento | Documento pequeño, índices orientados a lecturas y paginación keyset; medir cardinalidad. | Ocultar feature y conservar filas; cualquier política de purga sería una nueva decisión de producto incompatible con D4. |
| Push intrusivo o duplicado | Categoría granular, prioridad suave y dedupe socket/push. | Desactivar el canal push manteniendo feed in-app. |
| Perfil ambiguo al cambiar de semana | Semana IANA, `weekKey` y respuesta acotada. | Ocultar el contador, sin afectar las reacciones. |

El rollback funcional es por flags independientes: `memberReactionsWrite`, `memberReactionsRead`, `memberReactionNotifications` y `memberReactionHealthProjection`. Primero se desactiva escritura, luego notificaciones/proyección y finalmente lectura si fuese necesario. No se borran filas: D4 impide convertir un rollback técnico en retirada silenciosa de histórico.

## 11. Pruebas manuales

1. Completar una tarea como Ana, entrar como Miguel y comprobar que aparecen solo los cuatro emojis.
2. Enviar ❤️ y verificar una sola fila, el copy «Miguel te envió ❤️ por “…”», el feed de ambos y +1 en el contador semanal de Ana.
3. Pulsar ❤️ otra vez y confirmar que no aparece otro evento, aviso ni incremento.
4. Cambiar a 🎉 y comprobar que el item se actualiza, conserva su posición/`createdAt` y el contador no cambia.
5. Intentar reaccionar a tarea pendiente, eliminada, de otro hogar, propia y con sesión de ex-miembro; todas deben quedar bloqueadas por servidor.
6. Completar sin conexión y confirmar que el selector no aparece hasta terminar la sincronización; después debe usar `completedBy` canónico.
7. Desactivar la preferencia y enviar desde otro dispositivo: el feed y contador cambian, pero no hay indicador personal ni push.
8. Generar varias reacciones rápidas y observar un solo pull de Salud, con como máximo un trailing durante una petición en vuelo.
9. Expulsar a quien reaccionó y luego purgar la tarea: el histórico debe mostrar «Ex-miembro» y el snapshot, sin enlace roto.
10. Abrir dos dispositivos de Miguel, elegir emojis simultáneos y verificar una sola fila y convergencia al último valor aceptado.
11. Cruzar el límite domingo-lunes en la timezone del hogar y verificar que el contador pasa a la nueva `weekKey` sin comparar miembros.
12. Destruir un hogar de prueba y confirmar que las reacciones dejan de ser accesibles junto con el resto de recursos household-scoped.

## 💡 Proposed Improvements

- Unificar los dos caminos de completación en un evento de dominio inmutable y versionado antes de asociar reconocimiento a tareas reabiertas.
- Implementar una proyección de actividad común para TD-070 y TD-071; no reutilizar `updatedAt` ni la agenda por `dueDate` como event log.
- Corregir la revalidación de `household:join` antes de habilitar cualquier nuevo evento household-scoped.
- Añadir deduplicación transversal entre persistencia, socket, indicador local y push mediante `reactionId` y versión.
- Medir tasa de uso, cambios de emoji, opt-out y ráfagas sin registrar contenido personal adicional ni construir métricas comparativas.
- Revisar cardinalidad e índices con datos reales antes de introducir cualquier política de retención; D4 prohíbe una purga silenciosa durante la vida del hogar.

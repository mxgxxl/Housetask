# TD-067 — Diseño de gestión de roles y administración

> Estado: Open. Prioridad: High. Diseño documental; no implementa código, tests ni CI.

## 0. Alcance y evidencia

Este documento cubre «Gestión de roles y administración» (punto 20 del PDF del dueño). Usa estas etiquetas:

- **Causa confirmada:** comportamiento visto en el código actual.
- **Hipótesis:** consecuencia inferida pendiente de reproducción.
- **Pregunta abierta:** decisión que el prompt, el código y los PDR no cierran; no se decide aquí.

La autoridad actual de membresía sigue siendo `Household.members` durante TD-001; `HouseholdMember` es un espejo. La implementación deberá usar la autoridad vigente cuando se ejecute.

## Decisiones aprobadas

1. **El admin saliente permanece en el hogar como miembro regular.** Transferir la administración transfiere responsabilidad, no pertenencia: el miembro elegido pasa a `admin` y quien transfiere pasa a `member` en la misma operación transaccional.
2. **Cuando se va el último miembro, el hogar se destruye tras una confirmación explícita.** La eliminación alcanza los recursos ligados al hogar y es coherente con PDR-017: el XP personal es portable, pero el XP y los desbloqueos propios del hogar terminan con el hogar.
3. **El creador no tiene privilegios especiales.** `createdBy` conserva valor histórico; crear el hogar solo convierte a esa persona en su primer admin. Después se aplican las mismas transiciones y permisos que a cualquier otro admin.

## 1. Estado actual

### Roles y verificación

**Causa confirmada:** solo existen `admin` y `member`, definidos por `Role` y validados por `Household` y `HouseholdMember`. El creador entra como `admin`; quien se une por código entra como `member`.

**Causa confirmada:** `requireMembership` protege las rutas HTTP con `:householdId`, lee el rol del array embebido y adjunta `req.member`. No hay middleware de capacidades ni endpoint para promover, degradar, transferir administración, salir voluntariamente o destruir el hogar. `updateHouseholdSchema` existe, pero no está conectado.

| Acción | Admin | Miembro | Autoridad actual |
|---|---:|---:|---|
| Leer hogar, miembros y estadísticas | Sí | Sí | `requireMembership` |
| Crear tareas/compras y completarlas | Sí | Sí | Membresía + servicio |
| Editar/eliminar/restaurar tarea ajena | Sí | No | Admin o creador en `task.service.ts` |
| Purgar papelera | Sí | No | `task.service.ts` |
| Expulsar miembro | Sí | No | `household.service.ts` |
| Cancelar adopción ajena | Sí | No | Solicitante o admin en `pet.service.ts` |
| Cambiar roles / transferir | No existe | No existe | Sin ruta ni servicio |
| Salir voluntariamente / destruir hogar | No existe | No existe | Sin ruta ni servicio |

**Causa confirmada:** la protección del último admin solo cubre `removeMemberInTransaction`: cuenta administradores y elimina dentro de una transacción.

**Hipótesis:** una futura mutación de rol basada en un pre-check y una escritura posterior podría dejar cero administradores bajo concurrencia. La validación debe ser server-authoritative y transaccional.

## 2. Gestión de roles

### Contrato propuesto

- Solo un admin puede promover un miembro o degradar otro admin.
- Un miembro mantiene los permisos cooperativos actuales, pero no gestiona roles, expulsiones, papelera ni acciones administrativas futuras.
- Ser `createdBy` no concede permisos adicionales: el creador es únicamente el primer admin.
- El servidor valida actor, objetivo, transición y último admin. La UI solo presenta acciones.

Contrato HTTP de diseño:

```text
PATCH /api/households/:householdId/members/:userId/role
Body: { "role": "admin" | "member" }
```

La respuesta conserva `{ success, data?, error? }`, devuelve el hogar actualizado y mantiene consistentes las representaciones exigidas por la fase activa de TD-001. **Pregunta abierta:** PATCH no está cubierto por la Hard Rule 13; decidir si se añade clave idempotente o actualización condicional para reintentos.

### Realtime y auditoría

Proponer `household:member_role_changed` con `{ householdId, userId, previousRole, role }`, emitido una vez tras commit. Registrar actor, objetivo, hogar, transición y resultado sin datos sensibles. **Pregunta abierta:** decidir si v1 necesita historial persistente o bastan logs/Sentry.

## 3. Transferencia de administración

1. El admin elige un miembro y pulsa «Transferir administración».
2. La UI muestra el copy exacto de §5.
3. El servidor relee dentro de transacción a actor y objetivo y verifica roles vigentes.
4. El objetivo pasa a admin antes de modificar al actor.
5. Se devuelve y emite solo el estado confirmado.

El admin saliente se degrada siempre a `member` y permanece en el hogar, también cuando ya existían otros admins. La transferencia representa el relevo explícito de responsabilidad; no elimina la membresía ni ejecuta la limpieza de TD-018.

## 4. Protección contra cero administradores

Invariante: todo hogar persistente tiene al menos un admin.

- Degradar o expulsar al último admin se rechaza hasta promover a otra persona.
- Transferir administración promueve al objetivo y degrada al admin saliente dentro de la misma transacción; nunca existe un estado intermedio sin admin. Si el objetivo dejó de ser miembro o la promoción no puede confirmarse, no se degrada al saliente.
- Contar admins y escribir ocurre en la misma transacción sobre la autoridad vigente.
- Durante TD-001 se mantiene el contrato de escritura dual; después del cutover manda `HouseholdMember`.
- Error API propuesto: `El hogar debe conservar al menos un administrador`.

## 5. Acciones sensibles: copy exacto

### Expulsar

- Título: «Expulsar del hogar»
- Cuerpo: «¿Quieres expulsar a {nombre}? Dejará de ver este hogar y sus tareas pendientes se desasignarán.»
- Botones: «Cancelar» / «Expulsar»

### Transferir administración

- Título: «Transferir administración»
- Cuerpo: «¿Quieres convertir a {nombre} en administrador? Tú seguirás en el hogar como miembro.»
- Botones: «Cancelar» / «Transferir»

### Degradar admin

- Título: «Quitar permisos de administrador»
- Cuerpo: «¿Quieres convertir a {nombre} en miembro? Ya no podrá gestionar roles, expulsar miembros ni realizar otras acciones administrativas.»
- Botones: «Cancelar» / «Convertir en miembro»

### Último admin bloqueado

- Título: «Hace falta otro administrador»
- Cuerpo: «No puedes dejar el hogar sin administrador. Promueve o transfiere la administración a otro miembro primero.»
- Botón: «Entendido»

### Destruir el hogar al salir el último miembro

- Título: «Eliminar hogar»
- Cuerpo: «Eres la última persona de este hogar. Si sales, el hogar y su progreso compartido se eliminarán definitivamente. Tu XP personal se conservará.»
- Botones: «Cancelar» / «Eliminar hogar y salir»

## 6. Casos borde

| Caso | Resultado |
|---|---|
| Admin único se auto-degrada | Bloqueado por servidor (requisito confirmado) |
| Admin único sale y el hogar persiste | Transferencia previa obligatoria |
| Dos admins se degradan/expulsan concurrentemente | Solo confirma lo que preserve al menos uno |
| Objetivo sale durante la confirmación | Rechazar y refrescar miembros |
| Transición repetida | No duplicar evento; **pregunta abierta** sobre respuesta exacta |
| Último miembro | Confirmación explícita y destrucción del hogar; se conserva el XP personal y termina el progreso ligado al hogar |
| Admin sale existiendo otro | La invariante permite salir; **pregunta abierta:** exigir transferencia explícita igualmente |
| Creador degradado/expulsado | Se permite bajo las mismas reglas que para cualquier admin; `createdBy` queda histórico |
| Rol cambia durante otra petición | Cada petición reautoriza en servidor con el rol vigente |

La destrucción debe ser server-authoritative y abarcar tareas, compras, mascota, economía de hogar, membresías, notificaciones, caché y sockets. El orden, la atomicidad y la política de conservación legal/operativa de esos datos se detallarán antes de implementar; la decisión de producto de destruir el hogar ya está cerrada.

## Destrucción del hogar: atomicidad y retención

### Estado confirmado y alcance

**Causa confirmada:** el código actual no tiene endpoint, servicio ni estado de ciclo de vida para destruir un hogar. La única salida existente es `removeMember`, limitada a admins y protegida contra eliminar al último admin. Los modelos actuales ligados por `householdId` son tareas, compras, membresías espejo, ledger económico de Fase A, mascota y solicitud de adopción. `User.households` conserva además una referencia desnormalizada.

**Causa confirmada:** `RefreshToken` y `DeviceToken` pertenecen al usuario, no al hogar. No existen «sesiones del hogar» en el modelo actual; destruir un hogar no equivale a cerrar la sesión de la cuenta.

**Causa confirmada:** `PersonalCoinLedger`, `RewardGrant`, los ledgers/proyecciones de XP, presupuestos, hucha y misión son modelos propuestos por TD-066/UX P1, no colecciones implementadas hoy. Esta sección fija su contrato de destrucción futuro para evitar que P1 nazca con referencias huérfanas.

### Atomicidad server-authoritative

La destrucción final es un único comando server-authoritative con `Idempotency-Key` estable por operación lógica. La validación, los reembolsos, las cancelaciones, la retención portable, los borrados, el recibo idempotente y el registro de salida realtime se escriben en una sola transacción Mongo. Si falla cualquier paso, se revierte todo: el hogar continúa activo, ningún aporte queda parcialmente reembolsado y ningún recurso desaparece por separado.

El middleware genérico de idempotencia basado solo en TTL no basta para un borrado irreversible: tras eliminar el hogar ya no se puede volver a comprobar su membresía. El diseño necesita un `HouseholdDestructionReceipt` duradero, fuera del agregado borrado, con al menos `householdId`, `requestedBy`, hash de `Idempotency-Key`, estado, `destroyedAt` y respuesta mínima. Un retry autenticado del mismo actor y clave devuelve el resultado original; otra clave contra el hogar ya destruido no reconstruye ni repite nada.

**Pregunta abierta:** método y ruta exactos del comando (`DELETE` dedicado o `POST .../destroy`). La obligación de `Idempotency-Key` y la semántica de replay no dependen de esa elección.

### Retención por recurso

La tabla define la política final recomendada. «Conservar activo» es una excepción deliberada a hard/soft delete: el dato es personal y portable, por lo que borrarlo contradiría PDR-017. Las duraciones legales u operativas de cualquier tombstone son una **pregunta abierta** y deben fijarse antes de producción.

| Recurso | Existencia actual | Política al destruir | Justificación / tratamiento |
|---|---|---|---|
| `Household` e invite code | Sí | Hard delete al final de la transacción | Es la raíz del agregado; el código deja de ser reutilizable solo según la política general de unicidad. |
| `HouseholdMember`, array embebido y `User.households` | Sí | Hard delete / `$pull` transaccional | No debe quedar pertenencia ni referencia navegable. Durante TD-001 se limpian ambas representaciones; tras el cutover, la autoridad vigente. |
| Tareas, instancias recurrentes y papelera | Sí | Hard delete | Una tarea no es portable entre hogares. Incluye pendientes, completadas, soft-deleted y todas las ocurrencias `parentTaskId`. El soft delete de TD-046 protege borrados ordinarios, no la destrucción confirmada de la raíz. |
| Compras y recurrencias de compra | Sí | Hard delete | Pertenecen exclusivamente al hogar y no tienen valor portable. |
| `EconomyLedger` de Fase A | Sí | Hard delete tras cerrar/migrar cualquier saldo exigible | Es saldo compartido del hogar. No contiene `userId`, por lo que no puede convertirse en propiedad personal durante la destrucción sin inventar atribución. |
| `PersonalCoinLedger` | Diseño TD-066 | Conservar activo | La wallet es personal. Los asientos mantienen `userId`, importe y motivo; `householdId` queda como contexto histórico no navegable, marcado con `sourceHouseholdDeletedAt` o equivalente para no exigir que la raíz exista. |
| `PersonalXpLedger` y `UserProgress` | Diseño TD-066 | Conservar activos | PDR-017 exige que XP, nivel, títulos y badges personales sobrevivan. `UserProgress` ya se diseña sin `householdId`. |
| `PersonalStreak` / `StreakDay` de alcance personal | Diseño TD-066 | Conservar activos | Son portables si el `scope` aprobado es personal. **Pregunta abierta:** TD-066 aún no fija si una racha puede estar ligada al hogar; esa variante, si se aprueba, se elimina con el hogar. |
| `WeeklyPersonalBudget` | Diseño TD-066 | Hard delete después de cerrar la semana afectada | La asignación y sus allocations pertenecen al contexto del hogar; los grants ya consolidados permanecen en los ledgers personales. No se libera presupuesto nuevo tras la destrucción. |
| `RewardGrant` | Diseño TD-066 | Soft delete/tombstone mínimo | Se conserva `userId`, `completionOperationId` y recompensa personal para auditoría/anti-duplicado; se marca `householdDeletedAt` y se elimina cualquier snapshot de texto. `taskId`/`householdId` quedan como ids históricos no navegables. |
| `HouseholdXpLedger` y `HouseholdProgress` | Diseño TD-066 | Hard delete | El XP y los desbloqueos de hogar mueren con el hogar; PDR-017 solo preserva el progreso personal. |
| Mascota y solicitud de adopción | Sí | Hard delete | Mascota, estados y propuesta son compartidos y no pueden existir sin hogar. |
| Cosméticos de hogar actuales (`Pet.cosmetics`) | Sí | Hard delete con la mascota | Fueron comprados con economía compartida y pertenecen al agregado del hogar. |
| Cosméticos personales futuros | Diseño P1+ | Conservar activos | Los desbloqueos personales viajan con el usuario; el registro no debe depender de una raíz de hogar existente. |
| Hucha (`JointSavingsGoal`) activa | Diseño TD-066 | Reembolsar y después hard delete | Cada `SavingsContribution` activa se acredita a su wallet personal dentro de la misma transacción. Si un reembolso no puede escribirse, se bloquea y revierte toda la destrucción. PDR-018 no permite perder aportes al salir. |
| `SavingsContribution` | Diseño TD-066 | Soft delete como `refunded` | Conserva la prueba de reembolso personal y el `operationId`; deja de ser aporte activo y referencia una meta destruida solo como contexto histórico. |
| Misión semanal activa | Diseño UX P1 | Cancelar y hard delete, sin recompensa | La misión pertenece al hogar. Destruir no equivale a completarla y nunca concede cofre, monedas ni XP. |
| Migración/proyecciones económicas de hogar | Diseño TD-066 | Soft-delete del recibo de migración; hard delete de proyecciones de hogar | El tombstone mínimo evita repetir una migración histórica; saldos/progreso compartidos dejan de existir. |
| Refresh tokens y access tokens | Sí | Conservar | Son sesiones del usuario y pueden dar acceso a otros hogares. Las siguientes peticiones al hogar destruido fallan por ausencia de membresía/recurso. No existe revocación por hogar. |
| Device tokens push | Sí | Conservar | También son del usuario. Se dejan de seleccionar destinatarios mediante la membresía eliminada; no se desregistra el dispositivo. |
| Caché local y recordatorios del hogar | Sí, en cliente | Purga client-side tras evento/404 | No participa en la transacción Mongo. El cliente elimina snapshots, cola pendiente y recordatorios vinculados al hogar sin limpiar datos de otros hogares/cuenta. |
| `HouseholdDestructionReceipt` y outbox | Propuesto aquí | Grace period/tombstone operativo | Deben sobrevivir a la raíz para deduplicar retries y entregar el evento. **Pregunta abierta:** plazo exacto de retención y posterior anonimización/hard delete. |

### Orden dentro de la transacción

1. Reclamar el `Idempotency-Key`; si existe un recibo confirmado para actor/hogar/clave, devolverlo sin nuevas escrituras ni eventos.
2. Releer y bloquear lógicamente el hogar con versión/estado; verificar que el actor sigue siendo el único miembro y admin y que no comenzó otra destrucción, transferencia o alta.
3. Marcar el agregado como `destroying` dentro de la transacción para que toda mutación household-scoped participante rechace o entre en conflicto.
4. Cancelar la hucha activa: acreditar todos los reembolsos personales y marcar contribuciones `refunded`. Un solo fallo aborta.
5. Cancelar la misión activa sin recompensa y cerrar presupuestos/recibos personales que deban sobrevivir.
6. Escribir los tombstones de `RewardGrant`, migración, contribuciones y ledgers portables antes de borrar sus tareas/metas de origen.
7. Hard-delete tareas/instancias/papelera, compras, economía y progreso de hogar, mascota, adopción, cosméticos y demás hijos exclusivos.
8. Eliminar ambas representaciones de membresía y retirar el hogar de `User.households` para todas las cuentas afectadas.
9. Crear `HouseholdDestructionReceipt` y un evento outbox `household:destroyed` dentro de la transacción.
10. Hard-delete `Household` y confirmar. Solo después del commit el dispatcher publica el evento; si el commit falla, no hay borrados, recibo ni evento.

**Hipótesis:** sin un estado/versionado común que todas las escrituras household-scoped comprueben, una operación iniciada antes del paso 3 podría confirmar después y recrear un hijo huérfano. La implementación debe demostrar mediante transacciones/versión que esto no ocurre; no basta con comprobar membresía antes del `await`.

### Realtime y salida limpia de clientes

El outbox publica una sola vez lógicamente (deduplicada por `destructionReceiptId`):

```text
household:destroyed
{
  householdId,
  destroyedAt,
  destructionReceiptId,
  personalEconomyChanged: boolean
}
```

El outbox solo puede crearse desde la transacción que acaba de verificar la membresía y el rol del actor; conserva el snapshot de destinatarios autorizados previo al borrado. El dispatcher no acepta un `householdId` arbitrario ni recalcula destinatarios después, cuando la membresía ya no existe. Así, la emisión posterior al commit mantiene la comprobación server-authoritative exigida para eventos household-scoped.

El evento se envía a la sala todavía conectada tras el commit y después el servidor expulsa los sockets de `household_<id>`. El cliente:

1. cancela recordatorios locales del hogar;
2. elimina snapshots y operaciones offline del hogar;
3. resetea Cubits asociados sin tocar otros hogares ni la sesión;
4. abandona la sala y navega a otro hogar o al setup si no queda ninguno;
5. refresca wallet/XP personal si `personalEconomyChanged` es true.

Si el socket falla, el outbox reintenta. Como red de seguridad, cualquier GET posterior devuelve ausencia del hogar y desencadena la misma limpieza idempotente en cliente. **Pregunta abierta:** 404 frente a 410 durante la retención del recibo; el envelope no cambia.

### Periodo de gracia

**Pregunta abierta:** destrucción inmediata después de la confirmación o grace period reversible.

**Recomendación para v1:** destrucción inmediata tras el diálogo explícito ya aprobado y una confirmación reforzada, porque hoy no existe identidad de recuperación para un hogar sin miembros. Un grace period introduciría un agregado sin admin o exigiría conservar una membresía oculta, además de posponer reembolsos y mantener sockets/cachés en un estado nuevo. Si datos reales muestran destrucciones accidentales, diseñar después un estado `pendingDeletion` reversible con propietario de recuperación, plazo, UX y política de hucha explícitos; no simularlo mediante soft delete parcial.

### Casos borde adicionales

| Caso | Resultado requerido |
|---|---|
| Tarea/compra/completación en vuelo | Compite con el lock/versión del hogar: o confirma antes y entra en el conjunto destruido, o aborta/reintenta y recibe hogar destruido; nunca recrea hijos después. |
| Retry tras respuesta perdida | El mismo `Idempotency-Key` devuelve `HouseholdDestructionReceipt`; no repite reembolsos ni sockets. |
| Dos dispositivos destruyen a la vez | Solo una transacción reclama la operación; la otra recibe el resultado confirmado o conflicto estable. |
| Hucha activa | Reembolso completo primero; cualquier fallo bloquea y revierte destrucción. |
| Misión activa | Cancelada sin recompensa; no cuenta como éxito ni afecta rachas personales. |
| Último admin inicia transferencia | Transferencia y destrucción se serializan por versión: si transfiere primero deja de cumplirse «último miembro»; si destruye primero, la transferencia no encuentra hogar. |
| Alta por código concurrente | Si el alta confirma primero, ya no hay último miembro y se aborta la destrucción; si destruye primero, el invite code deja de resolver. |
| Operación offline llega después | El backend no la aplica; el cliente retira esa operación al reconciliar `household:destroyed`/404 y explica que el hogar ya no existe. |
| Fallo de socket tras commit | No revierte datos; outbox reintenta y la siguiente lectura fuerza limpieza idempotente. |

### Tests y pruebas manuales adicionales

- Transacción con fallo inyectado en cada paso: cero borrados/reembolsos parciales.
- Dos destrucciones concurrentes y replay de la misma/diferente clave.
- Carrera destrucción frente a tarea, join y transferencia.
- Hucha con aportes de miembros actuales y anteriores; suma exacta de créditos.
- Misión activa cancelada sin `RewardGrant` ni recompensa.
- Conservación de XP/ledger/cosméticos personales y desaparición de XP/mascota/cosméticos de hogar.
- Tokens de usuario siguen válidos para otro hogar y dejan de autorizar el destruido.
- Evento outbox único, retry del dispatcher y limpieza client-side idempotente en dos dispositivos.
- Prueba manual de cancelar el diálogo, confirmar, perder la respuesta HTTP, reabrir offline y reconectar.

## 7. Tests nuevos y commits atómicos futuros

### Backend

- Promoción/degradación por admin y 403 para miembro.
- Objetivo ajeno, rol inválido y hogar inexistente.
- Bloqueo del último admin en degradación y expulsión; transferencia atómica sin estado intermedio sin admin.
- Carrera entre dos operaciones: nunca cero admins.
- Consistencia con TD-001 y un único evento tras commit.
- Transferencia degrada al saliente, lo mantiene como miembro y no ejecuta la limpieza TD-018.
- Salida del último miembro exige confirmación, destruye el hogar y conserva el XP personal.
- El creador sigue exactamente la misma matriz de permisos y transiciones.

### Frontend

- Matriz de acciones por rol/objetivo.
- Copy exacto de diálogos y bloqueo.
- Refresh tras conflicto y actualización realtime de permisos.

### Plan

1. `feat(backend): añadir transiciones de rol server-authoritative (TD-067)`
2. `test(backend): cubrir roles, último admin y concurrencia (TD-067)`
3. `feat(frontend): añadir gestión de roles y confirmaciones (TD-067)`
4. `test(frontend): cubrir permisos y diálogos de roles (TD-067)`
5. `docs: actualizar API y decisiones de roles (TD-067)`

Este PR solo contiene el commit documental solicitado.

## 8. Riesgos, rollback y pruebas manuales

### Riesgos

- Divergencia entre membresía embebida y `HouseholdMember` durante TD-001.
- Carreras con cero admins o autorización con rol obsoleto.
- Cliente con permisos cacheados tras realtime.
- Borrado parcial al destruir el hogar, dejando recursos o salas huérfanos.
- Pérdida accidental de progreso compartido si la confirmación no explica que la destrucción es definitiva.

### Rollback

- Feature flag para ocultar UI/rutas nuevas sin alterar roles existentes.
- Desactivar rutas antes de revertir clientes.
- Sin migración destructiva: los dos valores de rol ya existen.
- Auditar transiciones de la ventana; cualquier reparación conserva un admin.

### Pruebas manuales

1. Promover con dos dispositivos y comprobar permisos.
2. Degradar cuando queda otro admin y verificar diálogo/evento.
3. Intentar degradar/sacar al admin único: estado intacto.
4. Ejecutar dos operaciones cruzadas con barrera de red.
5. Expulsar a alguien con tareas pendientes y verificar TD-018.
6. Cortar red antes/después de confirmar; no duplicar transición/evento.
7. Transferir y comprobar que el saliente sigue en el hogar como miembro regular.
8. Salir como último miembro: cancelar conserva todo; confirmar destruye el hogar, conserva XP personal y corta acceso/realtime.

## 9. Preguntas abiertas

- ¿Auditoría persistente o logs?
- ¿Semántica exacta de repetir un PATCH ya aplicado?

## Proposed Improvements

- Registrar aparte el gap de salida voluntaria ya reconocido en `ROADMAP.md`.
- Especificar la eliminación transaccional y la retención de cada recurso antes de implementar la destrucción aprobada del hogar.
- Evolucionar a capacidades declarativas para no dispersar comparaciones de rol.
- Coordinar implementación con el cutover de TD-001.
- Evaluar auditoría persistente para disputas administrativas.
- Resolver, con autorización del dueño, la colisión futura de IDs propuesta en `TD-065-DESIGN.md`; este PR no la modifica.

# TD-067 — Diseño de gestión de roles y administración

> Estado: Open. Prioridad: High. Diseño documental; no implementa código, tests ni CI.

## 0. Alcance y evidencia

Este documento cubre «Gestión de roles y administración» (punto 20 del PDF del dueño). Usa estas etiquetas:

- **Causa confirmada:** comportamiento visto en el código actual.
- **Hipótesis:** consecuencia inferida pendiente de reproducción.
- **Pregunta abierta:** decisión que el prompt, el código y los PDR no cierran; no se decide aquí.

La autoridad actual de membresía sigue siendo `Household.members` durante TD-001; `HouseholdMember` es un espejo. La implementación deberá usar la autoridad vigente cuando se ejecute.

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
- Ser `createdBy` no concede permisos adicionales por sí solo. **Pregunta abierta:** confirmar si el dueño quiere protección especial para el creador.
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

**Pregunta abierta — admin saliente:** el prompt contempla dos desenlaces y no fija uno:

- A: se degrada a miembro y permanece.
- B: sale después de transferir, reutilizando la limpieza de asignaciones de TD-018.

No deben ocultarse tras una acción ambigua. Si se aprueban ambos, la UI ofrecerá «Transferir y seguir como miembro» y «Transferir y salir» por separado.

**Pregunta abierta:** si ya existen varios admins, ¿transferir degrada siempre al actor o solo promueve al objetivo?

## 4. Protección contra cero administradores

Invariante: todo hogar persistente tiene al menos un admin.

- Degradar, expulsar o sacar al último admin se rechaza hasta promover/transferir a otra persona.
- Contar admins y escribir ocurre en la misma transacción sobre la autoridad vigente.
- Durante TD-001 se mantiene el contrato de escritura dual; después del cutover manda `HouseholdMember`.
- Error API propuesto: `El hogar debe conservar al menos un administrador`.

## 5. Acciones sensibles: copy exacto

### Expulsar

- Título: «Expulsar del hogar»
- Cuerpo: «¿Quieres expulsar a {nombre}? Dejará de ver este hogar y sus tareas pendientes se desasignarán.»
- Botones: «Cancelar» / «Expulsar»

### Transferir y permanecer (solo si se aprueba A)

- Título: «Transferir administración»
- Cuerpo: «¿Quieres convertir a {nombre} en administrador? Tú seguirás en el hogar como miembro.»
- Botones: «Cancelar» / «Transferir»

### Transferir y salir (solo si se aprueba B)

- Título: «Transferir administración y salir»
- Cuerpo: «{nombre} pasará a administrar el hogar y tú saldrás. Perderás el acceso y tus tareas pendientes se desasignarán.»
- Botones: «Cancelar» / «Transferir y salir»

### Degradar admin

- Título: «Quitar permisos de administrador»
- Cuerpo: «¿Quieres convertir a {nombre} en miembro? Ya no podrá gestionar roles, expulsar miembros ni realizar otras acciones administrativas.»
- Botones: «Cancelar» / «Convertir en miembro»

### Último admin bloqueado

- Título: «Hace falta otro administrador»
- Cuerpo: «No puedes dejar el hogar sin administrador. Promueve o transfiere la administración a otro miembro primero.»
- Botón: «Entendido»

## 6. Casos borde

| Caso | Resultado |
|---|---|
| Admin único se auto-degrada | Bloqueado por servidor (requisito confirmado) |
| Admin único sale y el hogar persiste | Transferencia previa obligatoria |
| Dos admins se degradan/expulsan concurrentemente | Solo confirma lo que preserve al menos uno |
| Objetivo sale durante la confirmación | Rechazar y refrescar miembros |
| Transición repetida | No duplicar evento; **pregunta abierta** sobre respuesta exacta |
| Último miembro | **Pregunta abierta:** destruir, archivar o bloquear salida |
| Admin sale existiendo otro | La invariante permite salir; **pregunta abierta:** exigir transferencia explícita igualmente |
| Creador degradado/expulsado | `createdBy` queda histórico; **pregunta abierta:** si se permite |
| Rol cambia durante otra petición | Cada petición reautoriza en servidor con el rol vigente |

Destruir el último hogar afecta tareas, compras, mascota, economía, notificaciones, caché y sockets. Queda fuera hasta decisión expresa.

## 7. Tests nuevos y commits atómicos futuros

### Backend

- Promoción/degradación por admin y 403 para miembro.
- Objetivo ajeno, rol inválido y hogar inexistente.
- Bloqueo del último admin en cambio de rol, expulsión y salida.
- Carrera entre dos operaciones: nunca cero admins.
- Consistencia con TD-001 y un único evento tras commit.
- Cada desenlace de transferencia aprobado; limpieza TD-018 si termina en salida.

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
- Transferencia destructiva sin explicar si el actor sale.
- Recursos huérfanos si se decide implícitamente el último miembro.

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

## 9. Preguntas abiertas

- ¿El admin saliente permanece o sale? ¿Se ofrecen ambas acciones?
- ¿Transferir degrada al actor cuando ya hay varios admins?
- ¿El creador conserva atribuciones especiales?
- ¿Último miembro: destruir, archivar o bloquear?
- ¿Auditoría persistente o logs?
- ¿Semántica exacta de repetir un PATCH ya aplicado?

## Proposed Improvements

- Registrar aparte el gap de salida voluntaria ya reconocido en `ROADMAP.md`.
- Diseñar destrucción/archivo del hogar como trabajo transversal separado.
- Evolucionar a capacidades declarativas para no dispersar comparaciones de rol.
- Coordinar implementación con el cutover de TD-001.
- Evaluar auditoría persistente para disputas administrativas.
- Resolver, con autorización del dueño, la colisión futura de IDs propuesta en `TD-065-DESIGN.md`; este PR no la modifica.

# TD-066 — Diseño técnico del refactor de economía P1

> Estado: **Open** · Prioridad: **High** · Registrado: 2026-08-20.
>
> Este es un diseño de implementación, no una autorización para cambiar el
> comportamiento. P1 se implementa **después del cutover de TD-001**. Las
> decisiones de producto citadas son PDR-010…019 y `UX-P1-SPEC.md`; donde no
> fijan un dato, se marca «Pregunta abierta» en vez de inventarlo.

## 1. Estado actual confirmado

Lo siguiente es **causa/estado confirmado**, leído en el código actual, no una
inferencia:

- La única moneda es de hogar. `EconomyLedger` guarda `householdId`, `amount`,
  `reason`, `refId` y `createdAt`; el saldo se calcula como `sum(amount)`, no
  se materializa. Su índice único `{ householdId, refId, reason }` evita el
  segundo grant de la misma referencia. Véanse
  `backend/src/models/EconomyLedger.ts` y `economy.service.ts`.
- Las tareas y compras conceden respectivamente 5 y 2 monedas al hogar solo en
  su primera completación/compra. `task.service.ts` y
  `shopping.service.ts` capturan el estado anterior y llaman a `grantCoins`;
  el índice del ledger es la guarda definitiva ante reintentos.
- El límite vigente es un máximo blando de 50 monedas positivas por día UTC.
  `grantCoins` hace leer-sumar-insertar sin transacción, por lo que su propio
  comentario documenta que dos grants concurrentes pueden rebasarlo hasta una
  recompensa. Un error al conceder nunca debe fallar la tarea o la compra.
- La economía es además el saldo compartido usado por mascota: bonus de
  adopción, cosméticos, feed y play. El catálogo estático de sombrero, bufanda
  y gafas vive en `backend/src/config/economy.ts`. El único endpoint de lectura
  es `GET /households/:householdId/economy`, que retorna
  `{ balance, dailyEarned, recentTransactions }`; `PetRepository` lo consume.
- La app offline solo cubre tareas y compra. ADR-010 persiste una
  `PendingOperation` y la reproduce FIFO; las escrituras durables se esperan
  desde TD-059. El contrato vigente de completar por `PATCH` no lleva una hora
  de ocurrencia ni una clave idempotente de operación para una recompensa P1.

**Hipótesis que debe verificarse al implementar:** las compras podrían seguir
siendo una fuente de recompensa P1 por continuidad con Fase A, pero PDR-011…019
solo cierran explícitamente la primera completación de una instancia de tarea.
No se mantiene ni se elimina esa recompensa mediante este diseño.

## 2. Prerrequisito de membresía y límites de diseño

TD-001 mantiene `Household.members` como autoridad hasta su fase 3. La nueva
colección `HouseholdMember` es hoy un espejo de escritura dual, por lo que no
debe decidir una wallet, aportación ni reembolso de P1 antes del cutover. La
ventana de observación está cerrada y el cutover autorizado, pero sigue
pendiente de ejecución; `ROADMAP.md` y `NEXT_SESSION_MAC.md` lo sitúan antes de
P1.

Después del cutover, las mutaciones económicas comprobarán membresía mediante
`HouseholdMember` dentro de su transacción. La baja administrativa existente ya
usa `mongoose.startSession().withTransaction()`; el reembolso de hucha debe ser
un paso de la misma operación antes de borrar la membresía.

## 3. Modelo de datos propuesto

Los importes y los saldos se representan como enteros no negativos salvo los
asientos de un ledger, que permiten débito/crédito. Se conservan los documentos
actuales de Fase A: no se les cambia semántica ni se redistribuye su saldo.

| Colección | Campos principales | Índices / invariantes |
|---|---|---|
| `PersonalCoinLedger` | `userId`, `householdId` (contexto/auditoría), `amount`, `reason`, `refType`, `refId`, `weekKey?`, `effectiveAt`, `createdAt` | Único `{ userId, reason, refType, refId }`; `{ userId, createdAt: -1 }`. La wallet personal es `sum(amount)` de su usuario. |
| `RewardGrant` | `householdId`, `userId`, `taskId`, `completionOperationId`, `effectiveAt`, `effectiveDayKey`, `coinAwarded`, `personalXpAwarded`, `householdXpAwarded`, `weeklyBudgetId`, `status` | Único `{ householdId, taskId, kind: 'task_first_completion' }`; único de `completionOperationId` por hogar. Es el recibo idempotente que une tarea, presupuesto y los tres progresos. |
| `PersonalXpLedger` y `UserProgress` | Ledger: `userId`, `amount`, `reason`, `refId`, `createdAt`; proyección: `xp`, `level`, `updatedAt` | Único ledger `{ userId, reason, refId }`. `UserProgress` no lleva `householdId`: XP, nivel, títulos y badges son portables (PDR-017). |
| `HouseholdXpLedger` y `HouseholdProgress` | Ledger: `householdId`, `amount`, `reason`, `refId`, `createdAt`; proyección: `xp`, `level`, `updatedAt` | Único ledger `{ householdId, reason, refId }`. Sus desbloqueos son del hogar. |
| `WeeklyPersonalBudget` | `userId`, `householdId`, `weekKey`, `periodTimeZone`, `weeklyCap`, `releasedCoins`, `grantedCoins`, `planVersion`, `allocations[]`, `createdAt`, `updatedAt` | Único `{ userId, householdId, weekKey }`. Cada asignación contiene `allocationKey`, `taskOrRuleId?`, `expectedFrequency`, `coinAmount`, `mode: automatic/manual`. |
| `PersonalStreak` y `StreakDay` | Racha: `userId`, `scope`, `scopeId?`, `currentCount`, `iceReserve`, `lastClosedDayKey`; día: `streakId`, `dayKey`, `usefulActivityCount`, `iceConsumed`, `iceRefunded`, `closeState` | Único `{ streakId, dayKey }`; `iceReserve` siempre 0…2. El día conserva la evidencia para un reembolso tardío. |
| `JointSavingsGoal` | `householdId`, `status: active/unlocked/cancelled`, `itemType`, `itemId`, `targetCoins`, `contributedCoins`, `createdBy`, marcas de cierre | Índice único parcial de una meta `active` por `householdId` (PDR-018). No representa una wallet común. |
| `SavingsContribution` | `goalId`, `householdId`, `userId`, `amount`, `status: active/applied/refunded`, `operationId`, `createdAt`, `refundedAt?` | Único `{ goalId, operationId }`; índice `{ goalId, userId }`. Cada aporte deja un débito de wallet enlazado y, si procede, un crédito de reembolso. |
| `HouseholdEconomyMigration` | `householdId`, `phase`, `legacyBalanceSnapshot`, `legacyLedgerWatermark`, `ownerDecision`, `activatedAt?`, `createdAt` | Único `{ householdId }`. Hace observable y reversible la activación, sin borrar el ledger heredado. |

`UserProgress` y `HouseholdProgress` son proyecciones reconstruibles de los
ledgers; se actualizan en la misma transacción que el asiento y nunca se toman
como única fuente de verdad. Si el coste de sumar el ledger no lo justifica, la
proyección acelera lecturas sin perder trazabilidad.

### Presupuesto semanal y seis asignaciones

Para una semana ISO y la zona guardada en `periodTimeZone`, `weeklyCap` es el
techo personal común de PDR-012. Para lunes…sábado, con `d = 0…5`, la liberación
determinista es:

```
releasedOnDay(d) = floor(weeklyCap × (d + 1) / 6)
                  - floor(weeklyCap × d / 6)
available(now) = releasedCoins(week through today) - grantedCoins
```

El domingo no añade nada. Al acabar el sábado se ha liberado exactamente el
presupuesto entero; lo no gastado sigue disponible el domingo y no caduca hasta
el cambio de `weekKey`. La concesión de una tarea consume como máximo lo
disponible; XP no se reduce cuando la moneda llega a cero.

El plan automático usa `expectedFrequency` para repartir el techo entre sus
`allocations`; una edición manual solo modifica la semana del usuario y
«volver a automático» restaura el cálculo reproducible. El servidor recalcula
ambas variantes, valida que no superen `weeklyCap` y guarda `planVersion`.

**Preguntas abiertas:**

- La fuente de `periodTimeZone` no está decidida. TD-013 aún documenta que el
  hogar no tiene timezone; no se debe usar UTC por omisión como una decisión
  silenciosa de P1.
- PDR-011 no define cómo se atribuyen la frecuencia ni el tramo de monedas de
  una tarea sin asignar o con varios asignados. Se necesita la regla antes de
  fijar `allocationKey` y los defaults automáticos.
- Los valores de XP, curvas de nivel y umbrales de hitos no están fijados.
- PDR-019 no decide si la racha se ancla solo a la cuenta o además a cada
  hogar. El campo `scope` evita bloquear ambas opciones; el valor v1 necesita
  decisión de producto.

## 4. Lógica server-authoritative

### Completar una tarea y anti-farm

El nuevo comando de completación corre en una transacción Mongo:

1. Comprueba al actor en `HouseholdMember` tras TD-001 y carga una tarea no
   eliminada del hogar.
2. Reclama la primera completación creando `RewardGrant`; el índice único hace
   que un retry entregue el recibo original y no repita moneda, XP, racha ni
   socket.
3. Normaliza `effectiveAt`/`effectiveDayKey`, resuelve semana y presupuesto,
   calcula la moneda disponible y escribe los ledgers de moneda personal, XP
   personal y XP de hogar junto con sus proyecciones.
4. Marca la tarea completada y genera la recurrencia con la misma semántica
   actual. Emite eventos solo tras el commit y con la versión/recibo devuelto.

No se reutiliza el límite diario blando de Fase A para P1: el límite estructural
es presupuesto personal + primera completación. Los errores de recompensa no
se tragan como hace `grantCoins`: una transacción P1 no puede declarar la tarea
completada sin dejar su recibo económico. Un error transitorio revierte todo y
el `Idempotency-Key` permite reintento seguro.

### Rachas y sync offline tardío

Un cierre server-side de día, o la primera lectura/mutación posterior que lo
necesite, registra `StreakDay`. De lunes a sábado sin actividad útil consume un
hielo si `iceReserve > 0`; domingo cierra como descanso y nunca consume. Una
completación offline sincronizada tarde conserva su `occurredAt` validado por
ventana permitida, incrementa `usefulActivityCount` de ese día y, si había
`iceConsumed`, escribe exactamente un asiento/evento `ice_refund` y restaura la
reserva hasta dos. La clave única del día y del recibo evita doble reembolso.

**Pregunta abierta:** si una racha ya tiene dos hielos cuando llega el sync
tardío, PDR-019 dice «se reembolsa» pero no fija el desenlace al tope. Debe
decidirse si se conserva el reembolso diferido, se convierte a otra recompensa
o se informa sin acreditar; este diseño no elige.

### Hucha y salidas

`contribute` valida wallet individual suficiente y, en una transacción, crea
`SavingsContribution`, el débito `PersonalCoinLedger` y el incremento atómico
de `JointSavingsGoal`. Al llegar al precio cambia la meta a `unlocked` y crea
el desbloqueo compartido una sola vez. Cancelar hace el inverso por cada aporte
activo: marca la contribución, acredita a su autor y baja el total antes de
marcar la meta `cancelled`. La baja de miembro llama al mismo reembolso dentro
de la transacción de membresía antes de retirar sus permisos; no toca aportes
de otros miembros.

**Pregunta abierta:** PDR-018 permite cancelar, pero no fija quién puede
hacerlo ni el tratamiento de una meta desbloqueada. La autorización y esas
transiciones deben cerrar el contrato antes de implementarse.

## 5. API propuesta

Todas las respuestas siguen `{ success, data?, error? }`; toda operación que
cree un recibo, aporte o recurso exige `Idempotency-Key` estable por operación.
Los `GET` no alteran el contrato de economía de Fase A.

| Método y ruta | Uso | `data` relevante |
|---|---|---|
| `GET /households/:householdId/economy/p1/me` | Wallet, presupuesto, XP y racha del miembro actual. | `{ wallet, weeklyBudget, personalProgress, streak, pendingRewards }` |
| `GET /households/:householdId/economy/p1/household` | Progreso XP y meta conjunta visibles al hogar. | `{ householdProgress, activeSavingsGoal, contributions }` |
| `PATCH /households/:householdId/economy/p1/budget` | Ajustar reparto propio o restaurar automático. | `{ weeklyBudget }` con `planVersion` resultante. |
| `POST /households/:householdId/tasks/:taskId/completions` | Comando P1, con `occurredAt` y `Idempotency-Key`. | `{ task, reward: { coins, personalXp, householdXp, budget, streak }, receiptId }` |
| `POST /households/:householdId/economy/p1/savings-goals` | Crear la única meta activa. | `{ goal }` |
| `POST /households/:householdId/economy/p1/savings-goals/:goalId/contributions` | Aportar desde wallet personal. | `{ goal, contribution, wallet }` |
| `POST /households/:householdId/economy/p1/savings-goals/:goalId/cancel` | Cancelar y encolar los reembolsos transaccionales. | `{ goal, refunds }` |

El `PATCH /tasks/:id` y la ruta legacy de completar continúan compatibles
durante migración, pero redirigen internamente al mismo servicio de primera
completación. Solo el cliente P1 usa el comando con `occurredAt`; nunca deben
coexistir dos caminos que concedan recompensas distintas para la misma tarea.

**Pregunta abierta:** se necesita decidir cuánto tiempo se mantiene el cliente
legacy y cuál es su valor de `occurredAt`; no puede fabricarse retrospectivamente
una hora offline fiable para un `PATCH` antiguo.

## 6. Migración sin romper el estado existente

1. **Gate:** completar el cutover TD-001; no activar colecciones ni rutas P1
   antes. Desplegar índices y modelos con feature flag apagado.
2. **Snapshot auditable:** por hogar, guardar `legacyBalanceSnapshot` y el
   watermark de `EconomyLedger` en `HouseholdEconomyMigration`. Mantener
   `EconomyLedger`, `GET /economy`, mascota y cosméticos Fase A intactos.
3. **Decisión del dueño previa a crédito:** no hay base en PDR-010…019 para
   repartir un saldo compartido heredado entre wallets personales. La migración
   no acredita, elimina ni convierte esos importes hasta que exista esa regla.
4. **Activación gradual:** activar P1 por hogar solo cuando el snapshot y la
   política de legado estén registrados. Los ledgers P1 se escriben separados;
   se puede desactivar el flag y volver a lectura Fase A sin pérdida de la
   historia heredada.
5. **Retirada posterior:** no retirar Fase A ni su endpoint hasta que el
   catálogo/mascota se hayan movido por un plan propio, con datos y clientes
   verificados.

## 7. Caché offline y durabilidad

ADR-010 sigue siendo last-write-wins para tareas y compras. La recompensa no
puede ser una wallet optimista definitiva: una tarea `isSynced: false` muestra
recompensa pendiente, pero saldo, XP, hucha y racha se reconcilian solo con el
recibo server-authoritative. La cola persistida debe añadir `operationId` y
`occurredAt` al payload de completación P1; ambos se generan una vez y se
guardan antes de confirmar UI. TD-059 exige esperar esa persistencia.

Al sincronizar, el cliente reemplaza el estado pendiente por el recibo de la
API y por la versión emitida por socket; no suma localmente dos veces si llegan
HTTP y socket. Las snapshots de economía deberán tener `version` y
`refreshedAt`; el cambio de schema/cache ha de limpiar o migrar de forma
propietaria, respetando el marcador de dueño de TD-062. No se encola aportar,
cancelar ni comprar hielos hasta que se diseñe su compensación offline: un
débito monetario no debe adoptar silenciosamente la semántica LWW.

## 8. Tests, commits y puntos de parada

| Parada / commit atómico propuesto | Cobertura que debe quedar verde antes de seguir |
|---|---|
| `feat(backend): añadir ledgers y recibos de economía P1` | Schema, índices únicos, proyecciones reconstruibles y migración vacía. |
| `feat(backend): aplicar presupuesto y recompensas P1` | Dos requests concurrentes / mismo `Idempotency-Key`; primera completación; presupuesto agotado; L-S y domingo; rollback de transacción. |
| `feat(backend): añadir XP rachas y hucha P1` | XP portable tras salida, XP de hogar, hitos, hielo automático, sync tardío/refund, máximo dos, aportes, cancelación y baja. |
| `feat(frontend): mostrar economía P1 y recibos de recompensa` | Cubit/repository: receipt HTTP+socket no duplica, offline queda pendiente, cache owner y migración de Hive. |
| `feat(frontend): añadir presupuesto rachas y hucha P1` | Widgets de domingo, saldo acumulado, error/retry, una meta y copy de reembolso. |
| `chore: activar migración economía P1 por hogar` | Runbook de snapshot, métricas, activación/corte y pruebas manuales firmadas. |

Claude debe ejecutar `npm run typecheck`, backend Jest completo, `flutter
analyze`, Flutter tests y los tests de migración contra réplica Mongo antes de
activar cada parada. Incluir pruebas de propiedades para la suma de seis
liberaciones y pruebas de concurrencia repetidas, no solo una simulación.

## 9. Riesgos, rollback y pruebas manuales

| Riesgo | Mitigación y rollback |
|---|---|
| Doble recompensa entre PATCH legacy, comando nuevo, socket o retry | Un único `RewardGrant` por primera completación y respuesta almacenada por Idempotency-Key. Si falla, apagar flag P1 y conservar ledgers para reconciliación. |
| Saldo heredado compartido mal convertido | No convertir sin decisión explícita; snapshot inmutable y Fase A intacta. |
| Hora offline manipulado o demasiado antigua | Validar ventana y servidor decide semana/día; registrar rechazo claro sin dar recompensa. |
| Transacción de baja deja dinero retenido | Reembolso y delete de `HouseholdMember` en la misma transacción; reintento seguro por índices únicos. |
| Caché muestra un saldo falso | Estado pendiente separado y receipt versionado; limpiar/migrar cache antes de leer P1. |
| Rollback después de activar hogares | Feature flag por hogar, no borrar colecciones ni `EconomyLedger`; exportar `RewardGrant`/ledgers antes de cambios irreversibles. |

Guion manual mínimo: (1) completar una tarea en cada día L-S y el domingo;
(2) repetir la misma operación con la misma clave y desde dos dispositivos;
(3) agotar presupuesto y comprobar que aún sube XP; (4) modo avión, completar,
cerrar/reabrir y sincronizar tarde tras un hielo; (5) aportar entre dos
miembros, cancelar y expulsar a un aportante; (6) salir y entrar en otro hogar,
confirmando que XP personal viaja y el de hogar no; (7) volver el feature flag a
Fase A y comprobar que mascota/cosméticos heredados siguen legibles.

## 10. Dependencias y preguntas abiertas de cierre

- **Dependencia bloqueante confirmada:** TD-001 cutover pendiente. Esta ficha
  no autoriza una implementación anterior.
- **Dependencia confirmada:** ADR-010 y TD-059 obligan a persistir y esperar la
  operación P1 antes de mostrarla como recuperable offline.
- **Pregunta abierta:** conversión, congelación o coexistencia del saldo
  `EconomyLedger` actual y de cosméticos ya comprados.
- **Pregunta abierta:** timezone de semana/día, atribución de tareas compartidas,
  números de XP/nivel, scope de racha, reembolso de hielo al tope y permisos de
  cancelación de hucha.

El documento `docs/TD-064-DESIGN.md` existe pero TD-064 no aparece en el
registro de `TECH_DEBT.md`. Es un hallazgo documental reciente; se reporta sin
modificarlo, tal como exige el alcance de esta tarea.

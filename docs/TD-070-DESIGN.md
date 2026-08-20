# TD-070 — Diseño del dashboard de salud del hogar

> Estado: Open. Prioridad: High. Diseño documental; no implementa código, tests ni CI. Cierra el bloque funcional P2 del punto 17 del PDF del dueño.

## 0. Alcance y criterio de evidencia

El dashboard resume señales operativas del hogar sin convertirlas en una nota moral, una competición entre miembros ni un ranking. Sus componentes son server-authoritative, explicables y accionables; las estadísticas numéricas existentes de PDR-007 permanecen separadas.

- **Causa confirmada:** comportamiento o dato visto en el código actual.
- **Hipótesis:** consecuencia inferida que requiere medición o reproducción.
- **Pregunta abierta:** decisión que este prompt, el código y los PDR no cierran; no se decide aquí.

Los umbrales que no están ya aprobados por TD-069 se documentan como baseline configurable. Deben calibrarse con datos del piloto antes de tratarlos como decisión permanente.

## 1. Estado actual

### Backend y datos disponibles

**Causa confirmada:** `GET /api/households/:householdId/stats?period=last30days|allTime`, protegido por `requireMembership`, devuelve `totalTasks`, `completedTasks`, `completionRate`, `memberStats`, `topCompleter` y `period`. No existe endpoint, modelo, proyección ni índice agregado de «salud».

**Causa confirmada:** para `last30days`, `totalTasks` usa `createdAt` y `completedTasks` usa `completedAt`. El propio test acepta que una tarea creada hace 45 días y completada hace 2 entre solo en el numerador; por tanto la tasa puede superar el 100 %. Es la semántica histórica de PDR-007, pero no sirve como fórmula de cumplimiento del dashboard. TD-070 usa una cohorte alineada por `dueDate` y no reutiliza ese porcentaje.

**Causa confirmada:** `Task` aporta estado, `dueDate`, asignados, `completedAt`, `completedBy`, recurrencia y soft delete. No guarda peso de carga, evento de actividad, racha del hogar ni snapshot semanal.

**Causa confirmada:** los modelos de peso automático, XP/rachas P1 y recomendaciones siguen siendo diseños de TD-066, TD-068 y TD-069; no están implementados en el código actual.

### Frontend y presentación existente

**Causa confirmada:** `StatsPage`, abierta desde el icono de barras de Perfil, muestra el selector «30 días / Todo», una tarjeta de tasa de completado, `topCompleter` y barras de completaciones por miembro. No ocupa una pestaña del bottom navigation.

**Causa confirmada:** `HouseholdRepository.stats` hace un GET directo; `StatsCubit` conserva el último resultado solo en memoria y vuelve a pedirlo al entrar o cambiar periodo. No hay caché persistente, estado stale ni refresco por socket para estadísticas.

TD-070 no reutiliza `topCompleter`, no convierte sus barras en equilibrio de carga y no duplica el selector temporal. El tab «Estadísticas» conserva PDR-007; el tab «Salud» tiene contrato y ventanas propios.

### Realtime actual

**Causa confirmada:** `SocketService` escucha tareas, compras, membresía, batches y mascota; `SocketCubit` los reenvía a sus Cubits, pero no conoce `StatsCubit` ni un futuro `HealthCubit`.

**Causa confirmada:** durante el handshake el servidor obtiene `User.households`, pero el handler posterior `household:join` acepta cualquier string no vacío y llama a `socket.join` sin revalidar membresía. Un evento de salud no puede apoyarse en ese join tal como está: antes de permitir la sala, el servidor debe consultar la autoridad vigente de TD-001. Esta corrección queda dentro del prerrequisito de seguridad del realtime de TD-070; no se modifica código en este PR.

**Hipótesis:** recalcular los cinco agregados ante cada eco de tarea puede producir ráfagas de GET y resultados que se pisan entre dispositivos. El diseño usa invalidación compacta, debounce y pull server-authoritative en vez de enviar cálculos completos por socket.

## 2. Decisiones aprobadas

1. **D1 — Categorías, no nota única.** La UI muestra una barra visual por componente. No existe `healthScore`, porcentaje global, semáforo global ni número que juzgue al hogar.
2. **D2 — Componentes fijos de v1.** En este orden: cumplimiento, equilibrio de carga (TD-069), tareas atrasadas, racha del hogar y actividad reciente.
3. **D3 — Pull inicial y realtime.** Al entrar en «Salud» se hace pull; mientras el cliente está conectado, una invalidación socket refresca la vista visible.
4. **D4 — Tab dedicado.** «Salud» vive separado de «Estadísticas» dentro de la superficie actual de estadísticas del hogar.
5. **D5 — Una acción por anomalía.** Cada componente anómalo muestra exactamente una acción concreta; un componente sano no muestra CTA. Cuando TD-068 tenga una recomendación aplicable, esa recomendación gobierna la acción.

## 3. Contrato del dashboard

### Endpoint y forma de respuesta

Contrato propuesto:

```text
GET /api/households/:householdId/health
```

Cualquier miembro actual puede leerlo después de `requireMembership`. El servidor calcula en la timezone IANA aprobada para P1 y responde con el envelope habitual:

```text
{
  householdId,
  generatedAt,
  periodTimeZone,
  weekKey,
  components: {
    completion,
    loadBalance,
    overdueTasks,
    householdStreak,
    recentActivity
  }
}
```

Cada componente contiene:

- `availability`: `available | insufficient_data | not_applicable`;
- `status`: `healthy | anomalous | null`;
- métricas de dominio necesarias para dibujar su barra, nunca un score moral normalizado;
- `summaryCode` y parámetros para copy determinista en español;
- `action` opcional con una única acción, `recommendationId` cuando procede y destino autorizado;
- `calculatedAt` y versión de fórmula/fuente.

No hay campo agregado que ordene, promedie o compare los cinco componentes. Un componente sin datos no vale cero.

### Cohorte y reglas comunes

- Excluir tareas `isDeleted: true` y duplicados de retry; una completación cuenta una sola vez.
- Usar ocurrencias, no la definición madre de una serie, para cumplimiento, atrasos y carga.
- Resolver semana natural como intervalo semiabierto `[lunes 00:00, lunes siguiente 00:00)` en la timezone P1.
- Calcular membresía con la autoridad vigente de TD-001; no inferir actividad o culpa de un exmiembro.
- Guardar `formulaVersion`, `weightSource`/`weightVersion` cuando aplique y nunca recalcular historia silenciosamente con reglas nuevas.

## 4. Modelo de cálculo por componente

### 4.1 Cumplimiento

Ventana: semana natural actual hasta `now`.

```text
eligibleDue = tareas no borradas con dueDate >= weekStart y dueDate < min(now, weekEnd)
completedDue = eligibleDue con status = completed
completionRatio = completedDue / |eligibleDue|
```

- Datos: `Task.dueDate`, `status`, `isDeleted` y primera completación confirmada.
- Sin datos: `|eligibleDue| = 0`; el componente no se muestra como 0 %.
- Sano: `completionRatio >= 0,80`.
- Anómalo: `completionRatio < 0,80`.
- Barra: proporción de la cohorte atendida, acompañada por copy factual «N de M tareas previstas atendidas»; no se presenta como nota del hogar.
- Acción anómala: la recomendación TD-068 de mayor prioridad asociada a esa cohorte; si no existe una aplicable, fallback «Ver tareas pendientes» con filtro de la semana.

El 80 % reutiliza el umbral cooperativo ya especificado para misiones P1. **Pregunta abierta:** confirmar con el piloto si salud debe conservar ese mismo umbral o configurarlo de forma independiente.

### 4.2 Equilibrio de carga

TD-070 consume TD-069 sin recalcular pesos ni usar los pesos por prioridad que TD-068 propuso antes de D4 de TD-069.

```text
realizedLoad(m, S) = suma de automaticBaseWeight de ocurrencias completadas por m en S
realizedShare(m, S) = realizedLoad(m, S) / carga realizada total de S
anomalía si existe el mismo m con realizedShare > 0,65
  en 2 semanas naturales completas consecutivas,
  cada una con al menos 5 tareas con peso contabilizadas por miembro
```

- Datos: snapshots `automaticBaseWeight`, `weightSource`, `weightVersion`, `completedBy`, cohortes de miembros y carga pendiente de TD-069.
- Sin datos: menos de dos semanas completas comparables o muestra inferior a cinco tareas; no se sustituye por conteos simples.
- Sano: hay dos semanas comparables y ningún miembro supera el 65 % en ambas.
- Anómalo: se cumple la persistencia aprobada de TD-069.
- Barra: distribución apilada de la última semana comparable, con orden estable de miembros y sin ordenar de mayor a menor; la carga pendiente aparece como contexto, no se mezcla con la realizada.
- Acción anómala: «Ver opciones», usando la sugerencia de redistribución TD-069 materializada y controlada por TD-068.

Las tareas sin asignar no entran en ningún porcentaje; aparecen en «Por repartir» dentro de la acción de asignación, conforme a D8 de TD-069.

### 4.3 Tareas atrasadas

Snapshot puntual en `now`, con contexto de la semana natural:

```text
overdue = tareas pendientes, no borradas, con dueDate < now
scheduledContext = tareas no borradas con dueDate dentro de la semana actual
                   + overdue anteriores todavía pendientes
operationalRatio = 1 - |overdue| / max(1, |scheduledContext|)
```

- Datos: `dueDate`, `status`, `isDeleted`, prioridad y recomendación activa.
- Sin datos: hogar sin ninguna tarea histórica y sin contexto programado.
- Sano: `|overdue| = 0`.
- Anómalo: `|overdue| >= 1`.
- Barra: fracción operativa sin atraso; el texto principal muestra el conteo («2 tareas atrasadas»), no una nota.
- Acción anómala: recomendación TD-068 más relevante para la tarea olvidada/atrasada; fallback «Revisar tareas atrasadas».

Una tarea pendiente sin `dueDate` no se inventa como atrasada. TD-068 puede detectarla por inactividad, pero no altera esta fórmula.

### 4.4 Racha del hogar

**Causa confirmada:** no existe hoy una racha del hogar. TD-066 propone `PersonalStreak`/`StreakDay` y mantiene abierto si el alcance es solo personal o también por hogar.

Baseline recomendado, condicionado a cerrar esa pregunta de producto:

```text
activeHouseholdDay(d) = existe al menos una primera completación útil del hogar en d
currentHouseholdStreak = días activos consecutivos de lunes a sábado
domingo = descanso neutral; no suma ni rompe
```

- Datos: fuente server-authoritative de días útiles de TD-066 y timezone P1.
- Sin datos: el hogar nunca registró un día útil.
- Sano: la racha sigue activa al cerrar el último día laborable evaluable.
- Anómalo: existía histórico activo y la racha se reinició a cero.
- Barra: siete segmentos de la semana (actividad, hueco y hoja de descanso), no progreso hacia un objetivo arbitrario.
- Acción anómala: recomendación TD-068 aplicable para retomar una tarea; fallback «Ver tareas pendientes», con tono «Podéis retomarlo cuando os venga bien».

**Pregunta abierta:** aprobar qué eventos mantienen la racha del hogar, si el domingo conserva la misma neutralidad que la racha personal y si existe cualquier mecanismo de hielo compartido. No se reutilizan hielos personales sin esa decisión.

### 4.5 Actividad reciente

Ventana: siete días locales completos/actuales terminando en `now`.

```text
activeDay(d) = existe al menos un evento útil server-authoritative del hogar en d
activeDays7 = suma de activeDay(d) para los últimos 7 días
```

- Datos candidatos: primera completación de tarea, tarea creada/programada, compra confirmada y futuros eventos de misión/hucha. Lecturas, aperturas de pantalla y escrituras rechazadas no cuentan.
- Sin datos: no existe ningún evento histórico útil.
- Sano: `activeDays7 >= 1`.
- Anómalo: existe histórico, pero `activeDays7 = 0`.
- Barra: siete segmentos cronológicos activo/inactivo; no mide volumen por persona.
- Acción anómala: recomendación TD-068 activa con mejor contexto; fallback «Ver tareas».

**Causa confirmada:** no hay event log de actividad y `updatedAt` no identifica qué ocurrió. **Hipótesis:** usarlo como sustituto contaría ediciones técnicas o irrelevantes como salud. El componente requiere una fuente de eventos explícita o una proyección equivalente.

**Pregunta abierta:** cerrar la taxonomía exacta de eventos útiles y decidir si la infraestructura de eventos pendiente de TD-068 es la fuente común. Hasta entonces, la lista anterior es recomendación de diseño, no decisión aprobada.

## 5. Integración y dependencias

### TD-068 — recomendaciones automáticas

El dashboard consume recomendaciones; no vuelve a puntuarlas:

- recibe `recommendationId`, categoría, acción autorizada, explicación, estado y versión;
- respeta preferencias, cooldowns, dismiss y deduplicación de TD-068;
- usa hábitos/olvido para cumplimiento, atrasos, racha y actividad;
- usa la categoría de carga para materializar las opciones calculadas por TD-069;
- convierte tareas sin asignar en sugerencia de asignación, sin sumarlas al balance.

La métrica básica sigue visible aunque el usuario desactive recomendaciones. En ese caso, una anomalía usa el fallback de navegación determinista y nunca genera texto nuevo ni una mutación automática.

### TD-069 — reparto inteligente

Consume sus pesos P1 versionados, semana natural, cohortes, carga realizada/pendiente, umbral `>65 %` durante dos semanas y muestra mínima de cinco tareas. TD-070 solo adapta ese resultado al componente visual. No reutiliza `memberStats.completed`, `topCompleter` ni el proxy por prioridad anterior de TD-068.

### Bloqueos

| Dependencia | Motivo |
|---|---|
| TD-001 | Autoridad única de membresía, cohortes fiables, alta/baja y autorización de salas socket. |
| TD-066 | `automaticBaseWeight`, timezone/semana P1 y fuente de rachas; TD-069 ya depende de esta base. |
| TD-068 | Acciones contextuales, preferencias, cooldowns y posible fuente de actividad. |
| TD-069 | Cálculo server-authoritative del componente de equilibrio. |

El dashboard v1 completo queda **bloqueado por TD-001, TD-066, TD-068 y TD-069**. Se puede prototipar el tab y las fórmulas puras sobre fixtures, pero no declarar TD-070 implementado ocultando componentes fijos o sustituyendo sus datos por proxies inventados.

## 6. Pull, realtime y coherencia

### Flujo conectado

1. Al abrir el tab «Salud», `HealthCubit` sirve primero una caché válida del mismo usuario/hogar, si existe, y siempre lanza `GET .../health`.
2. El backend calcula el snapshot y el cliente reemplaza la caché completa de forma atómica.
3. Tras una mutación relevante confirmada, el servidor emite:

```text
household:health_invalidated
{
  householdId,
  components: [completion | loadBalance | overdueTasks | householdStreak | recentActivity],
  occurredAt
}
```

4. Si «Salud» está visible, `HealthCubit` agrupa invalidaciones durante 750 ms y hace un solo pull. Si no está visible, marca el snapshot dirty y lo refresca al entrar.
5. El socket nunca transporta un score ni se toma como autoridad del cálculo; solo invalida.

Antes de unir o mantener un socket en `household_<id>`, el servidor verifica membresía contra la autoridad vigente. Una baja expulsa los sockets del exmiembro de la sala. Las emisiones de salud se hacen únicamente después del commit de dominio.

### Carreras y orden

- Una respuesta iniciada antes de una invalidación no puede sobrescribir otra más nueva: comparar `generatedAt`/versión de request.
- Dos invalidaciones de la misma ráfaga se deduplican; el pull devuelve los cinco componentes coherentes en un solo snapshot.
- Un fallo de pull conserva el snapshot anterior como stale y ofrece reintento de pantalla; no mezcla componentes de momentos distintos.

## 7. Offline y vuelta a online

**Causa confirmada:** las estadísticas actuales no tienen caché persistente. TD-070 necesita un snapshot de salud por usuario y hogar siguiendo la propiedad de caché de TD-062.

Sin conexión:

- mostrar solo el último snapshot server-authoritative del mismo usuario/hogar;
- banner: «Sin conexión · datos actualizados {fecha relativa}»;
- mantener barras y copy como stale, sin recalcular desde listas parciales del cliente;
- permitir CTAs de navegación a datos locales, pero deshabilitar aceptar/descartar recomendaciones o confirmar reasignaciones hasta refrescar;
- si no hay snapshot, mostrar «Necesitas conexión para calcular la salud del hogar», nunca un estado sano por defecto.

Al recuperar conexión:

1. esperar a que las operaciones offline pendientes terminen de sincronizar;
2. hacer un único pull del snapshot completo;
3. reemplazar la caché atómicamente y retirar el banner stale;
4. aplicar después las invalidaciones socket posteriores, sin duplicar requests.

Cambiar de hogar aísla la clave de caché; logout/cambio de cuenta la limpia conforme a TD-062.

## 8. Presentación visual

### Navegación y layout

`StatsPage` pasa a contener dos tabs superiores:

- «Salud»: nuevo dashboard, sin selector «30 días / Todo»;
- «Estadísticas»: UI PDR-007 actual, incluido su selector y sus métricas numéricas.

**Pregunta abierta:** cuál de los dos tabs queda seleccionado por defecto al abrir desde Perfil. D4 decide que están separados, no cuál prevalece.

Orden vertical fijo en «Salud»:

1. Cumplimiento.
2. Equilibrio de carga.
3. Tareas atrasadas.
4. Racha del hogar.
5. Actividad reciente.

No se reordena por gravedad: una lista que mueve tarjetas convierte anomalías en alarma y dificulta comparar el hogar en el tiempo.

### Gramática de componentes

Cada tarjeta contiene icono, nombre, resumen factual, barra propia, periodo/fuente y como máximo una acción. Estados:

- sano: teal/verde suave, icono de check y copy neutral;
- anómalo: ámbar/coral, icono de atención y copy no culpabilizador;
- datos insuficientes: slate/gris y explicación breve;
- no aplica: «—», sin barra activa ni CTA.

El color nunca es la única señal; texto, icono y semántica accesible repiten el estado. No se usa rojo punitivo, confeti, trofeo, ranking, nombres ordenados ni «nota del hogar».

### Empty state

Si ningún componente tiene datos:

- Título: «Aún no hay suficiente actividad».
- Texto: «Cuando empecéis a organizar y completar tareas, aquí veréis cómo va vuestro hogar.»
- CTA global: «Ir a tareas».

Este CTA pertenece al empty state, no a un componente sano, por lo que no contradice D5.

## 9. Casos borde

| Caso | Resultado |
|---|---|
| Hogar nuevo sin histórico | Ocultar componentes sin datos y mostrar el empty state útil; nunca cinco barras a cero. |
| Miembro nuevo | Recalcular inmediatamente carga pendiente y cohorte actual. No emitir anomalía persistente hasta disponer de dos semanas completas comparables con la nueva cohorte; no reescribir historia. |
| Miembro que sale | Retirar pendientes según TD-018, preservar actividad histórica agregada y dejar de incluirlo en acciones o sockets futuros. |
| Hogar de un miembro | Equilibrio muestra «—» y «No aplica en hogares de una persona»; no hay CTA ni sugerencia de redistribución. Los demás componentes siguen disponibles. |
| Semana sin actividad, con histórico previo | Cumplimiento puede quedar sin datos si no hubo tareas vencidas; actividad reciente pasa a anómala tras siete días completos y la racha aplica la regla aprobada futura, con tono de retorno, no castigo. |
| Semana parcial | Cumplimiento usa solo tareas vencidas hasta `now`; equilibrio persistente usa semanas completas, nunca la actual por sí sola. |
| Cero tareas con `dueDate` | Cumplimiento y atrasos quedan sin datos; una tarea sin fecha solo puede aparecer mediante recomendación de inactividad TD-068. |
| Tarea compartida | Carga pendiente se fracciona y carga realizada se atribuye a `completedBy`, exactamente como TD-069. |
| Tarea sin asignar | No entra en balance; aparece como oportunidad «Por repartir» conectada con TD-068. |
| Datos cacheados de otro hogar/cuenta | Nunca se muestran; validar propietario y `householdId` antes del primer frame. |
| Evento socket durante pull | Marcar dirty y ejecutar como máximo un pull adicional después del actual. |
| Recomendación descartada | No reaparece como CTA durante su cooldown; se usa fallback determinista si el componente sigue anómalo. |

## 10. Tests nuevos y plan de commits atómicos

### Backend y dominio

- Endpoint exige membresía y mantiene `{ success, data?, error? }`.
- Ausencia explícita de `healthScore` o agregado global.
- Cumplimiento: cohorte por `dueDate`, 0/80/100 %, tarea antigua completada ahora y soft delete.
- Equilibrio: consume snapshots TD-069, 65 % exacto no alerta, >65 % dos semanas sí, muestra 4/5 y hogar de uno.
- Atrasos: justo antes/en/después de `dueDate`, tarea sin fecha y overdue antiguo.
- Racha: días útiles, domingo y reinicio según la decisión pendiente finalmente aprobada.
- Actividad: siete días, event types aprobados, cero histórico frente a semana inactiva.
- Miembro nuevo/saliente y dos cohortes no comparables.
- `household:join` rechaza un hogar ajeno y una baja expulsa el socket de la sala.
- Invalidaciones posteriores al commit, lista correcta de componentes y ninguna emisión duplicada en retry.

### Frontend

- Tabs «Salud / Estadísticas» y preservación íntegra de PDR-007.
- Orden fijo, barras accesibles, ausencia de score/ranking y estados sano/anómalo/sin datos/no aplica.
- Un CTA por anomalía y ninguno en sano; preferencias/cooldown TD-068.
- Hogar nuevo, miembro nuevo, hogar de uno y semana sin actividad.
- Pull al entrar, debounce socket, respuesta vieja descartada y un solo refetch tras ráfaga.
- Caché correcta por propietario/hogar, stale offline, sin caché y reconciliación al volver.

### Plan futuro de commits

1. `feat(backend): añadir snapshot de salud del hogar (TD-070)`
2. `test(backend): cubrir fórmulas y autorización de salud (TD-070)`
3. `feat(backend): emitir invalidaciones de salud en realtime (TD-070)`
4. `feat(frontend): añadir HealthCubit y caché de snapshots (TD-070)`
5. `feat(frontend): integrar tab Salud en estadísticas (TD-070)`
6. `test(frontend): cubrir dashboard, offline y socket (TD-070)`
7. `docs: documentar operación del dashboard de salud (TD-070)`

El presente PR contiene solo el commit documental solicitado.

## 11. Riesgos, rollback y pruebas manuales

### Riesgos

- Que las barras se interpreten como calificación moral pese a no existir score global.
- Fórmulas caras sobre histórico y tormentas de pull por sockets.
- Estado incoherente si cada componente se calcula o cachea por separado.
- Fuga de métricas a un socket unido sin membresía vigente.
- Duplicar o contradecir el peso de TD-069 y las recomendaciones de TD-068.
- Convertir inactividad o racha en culpa, especialmente con enfermedad, cuidados o vacaciones.
- Mostrar datos de otra cuenta/hogar desde caché.

### Rollback

- Feature flag independiente para el tab «Salud» y kill switch para invalidaciones socket.
- Endpoint read-only: ocultarlo no modifica tareas, recomendaciones ni economía.
- Mantener «Estadísticas» intacto para volver a la experiencia PDR-007.
- Desactivar primero realtime y conservar pull; después ocultar el tab si las fórmulas generan conflicto.
- Versionar snapshots para invalidar caché sin migrar métricas antiguas.

### Pruebas manuales

1. Abrir Perfil → Estadísticas y verificar tabs separados y ausencia de score global.
2. Crear cohortes por debajo/en/encima de 80 % y comprobar cumplimiento sin superar 100 %.
3. Sembrar dos semanas TD-069 con 65 % y >65 %, cinco tareas, tareas compartidas y sin asignar.
4. Vencer una tarea y comprobar un solo CTA; resolverla y comprobar que desaparece.
5. Probar hogar nuevo, alta de miembro, baja y hogar de una persona.
6. Completar desde un segundo dispositivo y verificar invalidación/debounce/pull en tiempo real.
7. Intentar `household:join` con un hogar ajeno y confirmar que no recibe salud ni eventos.
8. Activar modo avión con/sin snapshot, cambiar de hogar/cuenta y reconectar con operaciones pendientes.
9. Simular siete días sin actividad y revisar tono, racha y acción sin lenguaje culpabilizador.
10. Apagar realtime y luego el feature flag; «Estadísticas» sigue funcionando sin cambios.

## 12. Preguntas abiertas

- Definición exacta de actividad útil, domingo e hielos para la racha del hogar.
- Taxonomía/fuente persistente de actividad reciente y su relación con el event log pendiente de TD-068.
- Tab seleccionado por defecto al abrir la superficie desde Perfil.
- Calibración tras el piloto del 80 % de cumplimiento y de siete días sin actividad; los valores documentados son baseline configurable.

## Proposed Improvements

- Corregir el join socket para revalidar membresía antes de añadir cualquier canal de salud.
- Diseñar una proyección/rollup versionada y medirla con `explain` antes de agregar histórico en cada pull.
- Compartir una única taxonomía de eventos con TD-068 para evitar dos fuentes de «actividad».
- Mantener métricas y acciones separadas: las recomendaciones pueden apagarse sin falsear la salud básica.
- Auditar copy, accesibilidad y privacidad con hogares piloto antes de activar anomalías por racha o inactividad.
- Evaluar por separado la futura retirada de `topCompleter`; TD-070 lo aísla, pero no cambia PDR-007.

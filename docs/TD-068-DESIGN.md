# TD-068 — Diseño de recomendaciones automáticas basadas en reglas

> Estado: Open. Prioridad: Medium. Diseño documental; no implementa código, tests ni CI. Reglas fiables primero, sin IA generativa.

## 0. Alcance y evidencia

Este documento cubre «Recomendaciones automáticas» (punto 12 del PDF del dueño). Distingue:

- **Causa confirmada:** comportamiento o dato visto en el código.
- **Hipótesis:** inferencia pendiente de validar con datos o reproducción.
- **Pregunta abierta:** decisión no fijada; no se decide aquí.

Los umbrales incluidos son una **línea base de diseño configurable**, no una decisión de producto irreversible. Deben validarse con datos del piloto antes de activar notificaciones.

## 1. Datos disponibles y límites actuales

**Causa confirmada:** `Task` guarda título, categoría, asignados, prioridad, fechas (`dueDate`, `createdAt`, `updatedAt`, `completedAt`), autor/completador, estado y recurrencia (`isRecurring`, `recurrenceRule`, `parentTaskId`). Las completaciones permanecen como documentos consultables salvo borrado lógico.

**Causa confirmada:** no existe `backend/src/services/timeline.service.ts`. El timeline usa consultas por rango en `task.service.ts` y agrupación por día en Flutter.

**Causa confirmada:** las estadísticas actuales solo agregan tareas creadas/completadas y top completer para 30 días o todo el histórico. No calculan hábitos, carga pendiente, recomendaciones ni preferencias.

**Causa confirmada:** no hay evento de actividad por tarea. `updatedAt` es el único proxy genérico de edición; no dice qué campo cambió ni registra visualizaciones, rechazos o aplazamientos.

**Hipótesis:** agrupar por título normalizado puede unir tareas distintas con nombres genéricos («Limpiar») o separar el mismo hábito por pequeñas variaciones. Antes de producción se debe medir precisión con hogares piloto.

## 2. Detección de hábitos

### 2.1 Cohorte y agrupación

Solo se evalúan tareas:

- del mismo hogar;
- completadas y no borradas;
- no recurrentes (`isRecurring == false` y sin serie `parentTaskId`);
- con `completedAt` dentro de las últimas `M = 8` semanas.

Agrupación v1 propuesta: `householdId + normalize(title) + category`, donde `normalize` aplica trim, minúsculas, espacios simples y diacríticos normalizados solo para comparar; el texto almacenado no se modifica. **Pregunta abierta:** fijar el nivel de normalización y si hace falta confirmación del usuario para unir variantes.

### 2.2 Fórmula base

Para un grupo con completaciones ordenadas `t1..tn`:

```text
n >= N, con N = 4 y M = 8 semanas
intervalos Δi = ti - t(i-1)
periodo candidato P = mediana(Δi), redondeado a 1, 7, 14 o 28 días
regularidad = proporción de Δi con |Δi - P| <= tolerancia(P)
tolerancia(1) = 12 h; tolerancia(7|14) = 2 días; tolerancia(28) = 5 días
sugerir si regularidad >= 0,75
```

Para patrón semanal/quincenal se añade coherencia de día:

```text
weekdayConfidence = máximo recuento del mismo día de semana / n
exigir weekdayConfidence >= 0,60
```

La hora solo se usa si hay `dueDate` o `startsAt` en al menos 75 % de las muestras; `completedAt` mide cuándo se terminó, no cuándo se quería hacer. La sugerencia propone tipo, intervalo y día inferidos, pero el usuario confirma antes de convertir nada.

Copy propuesto: «Sueles completar “{título}” cada {periodo}. ¿Quieres convertirla en recurrente?» CTA: «Revisar recurrencia» / «Ahora no».

### 2.3 Deduplicación

- No recomendar si alguna muestra ya es recurrente o pertenece a serie.
- No recomendar si existe una tarea recurrente activa con la misma clave normalizada.
- Guardar identidad estable de sugerencia y estado `shown/accepted/dismissed/expired` para no regenerarla en cada lectura.
- Tras descartar, cooldown inicial de 8 semanas para la misma clave. **Pregunta abierta:** confirmar duración y si «No volver a sugerir» se ofrece por hábito.

## 3. Detección de tareas olvidadas

Se evalúan tareas pendientes, no borradas y no cubiertas por una recomendación equivalente activa.

```text
lastActivityAt = max(createdAt, updatedAt)
inactiveDays = floor((now - lastActivityAt) / 24 h)
overdueDays = dueDate existe ? floor((now - dueDate) / 24 h) : 0

umbral base configurable X = 7 días
sugerir si inactiveDays > X
o si overdueDays >= 2
```

Modificador por prioridad propuesto: alta `X=3`, media `X=7`, baja `X=14`. La recomendación nunca completa, reasigna ni borra automáticamente; ofrece «Reprogramar», «Reasignar», «Completar» o «Archivar» según permisos y futura política de archivo.

**Causa confirmada:** hoy no existe archivo de tareas, solo papelera. Por tanto «Archivar» es una capacidad futura y no debe mostrarse hasta diseñarse.

**Hipótesis:** `updatedAt` puede renovarse por una edición irrelevante y retrasar la señal. Un historial de eventos permitiría distinguir reprogramación, asignación y edición, pero no existe.

## 4. Sugerencias contextuales

Cada candidato recibe una puntuación explicable:

```text
score = overdueScore + inactivityScore + repetitionScore + loadScore

overdueScore = min(max(overdueDays, 0), 14) / 14 * 40
inactivityScore = min(inactiveDays / X, 2) / 2 * 25
repetitionScore = habitConfidence * 20
loadScore = min(max(memberLoadRatio - 1, 0), 1) * 15
```

`habitConfidence = regularidad × weekdayConfidence` (o solo regularidad si no aplica día semanal).

Carga v1 propuesta:

```text
memberLoad = pendientes asignadas ponderadas
peso prioridad: alta 3, media 2, baja 1
memberLoadRatio = carga del asignado / mediana de carga de miembros activos
```

Acciones concretas:

- atrasada + inactiva: «Reprograma “{título}” o asígnala a otra persona»;
- patrón regular: «Convierte “{título}” en semanal»;
- carga muy superior (`ratio >= 1,5`) y hay miembro con menor carga: «Revisad el reparto de {N} tareas pendientes»;
- varias tareas vencen el mismo día/categoría: agruparlas en una tarjeta, sin fusionarlas ni cambiar fechas automáticamente.

**Causa confirmada:** `memberStats.completed` no mide carga actual; para equilibrar hay que consultar tareas pendientes y `assignedTo`. Una tarea con varios asignados cuenta fraccionada (`peso / número de asignados`) para evitar multiplicarla.

**Pregunta abierta:** definir si las tareas sin asignar cuentan como carga del hogar, se reparten como oportunidad o se excluyen del ratio.

No habrá ranking, culpa ni texto generativo. El motor usa plantillas versionadas y expone «Por qué te lo sugerimos» con datos concretos.

## 5. Presentación y control de frecuencia

### Superficies

- Pantalla de tareas: módulo discreto «Sugerencias» sobre la lista, máximo 3 activas; tarjeta contextual junto a una tarea solo cuando haya acción inmediata.
- Notificaciones push: solo opt-in y solo recomendaciones High; TD-049 debe estar operativo para entrega real.
- Digest: resumen semanal dentro de la app; push/email quedan como **pregunta abierta**. No existe infraestructura de email.

### Anti-spam propuesto

- Máximo una impresión por sugerencia y superficie cada 7 días.
- Máximo una notificación push de recomendaciones por hogar/usuario cada 7 días.
- Digest una vez por semana, en timezone del hogar cuando TD-013 lo permita; fallback UTC debe quedar visible en telemetría.
- No volver a mostrar una sugerencia aceptada, expirada o descartada durante su cooldown.
- Recalcular al abrir Tareas o mediante job diario; nunca en cada rebuild ni en cada evento socket.

**Pregunta abierta:** día/hora del digest y si se configura por usuario o por hogar.

## 6. Preferencias del usuario

Preferencias personales, no del hogar:

- activar/desactivar todas las recomendaciones;
- hábitos/recurrentes;
- tareas olvidadas;
- equilibrio de carga;
- notificaciones push de recomendaciones;
- digest.

El backend es autoridad para que se sincronicen entre dispositivos. Defaults propuestos: recomendaciones in-app activas; push y digest push desactivados hasta consentimiento explícito. Cambiar preferencias no borra tareas ni histórico; deja de generar/entregar la categoría.

**Pregunta abierta:** retención de sugerencias ya generadas al desactivar una categoría: ocultarlas o marcarlas como descartadas.

## 7. Casos borde

| Caso | Resultado |
|---|---|
| Hogar nuevo/sin histórico | No recomendar hasta `n >= 4` y ventana suficiente |
| Tarea ya recurrente/serie | Nunca sugerir duplicado |
| Poca actividad de un miembro | No inferir desinterés; sugerir revisar reparto solo con carga pendiente suficiente |
| Un solo miembro | Sin sugerencias comparativas de equilibrio |
| Exmiembro en histórico | Conserva completaciones históricas; no recibe sugerencias ni carga actual |
| Varios asignados | Peso fraccionado; no duplicar carga |
| Sin asignar | **Pregunta abierta** sobre contribución a carga |
| Cambio de timezone/DST | Calcular por calendario IANA futuro; TD-013 sigue abierto |
| Tarea borrada/restaurada | Borrada no genera; restaurada reinicia evaluación desde actividad confirmada |
| Datos offline | Mostrar sugerencia cacheada como potencialmente desactualizada; acciones se someten al servidor |
| Títulos parecidos | No fusionar fuera de la clave normalizada aprobada; medir falsos positivos |

## 8. Tests nuevos y commits atómicos futuros

### Backend/reglas

- `n=3` no sugiere; `n=4` regular sí; intervalos fuera de tolerancia no.
- Diario, semanal, quincenal, mensual y DST/timezone.
- Exclusión de recurrente, serie, borrada y sugerencia ya descartada.
- Inactividad justo antes/en/después de X y vencimiento de 2 días.
- Puntuación determinista y desempate estable.
- Carga ponderada, varios asignados, exmiembro, hogar de uno y poca muestra.
- Preferencias y cooldown impiden generación/entrega; concurrencia no duplica.
- Membership en toda lectura/acción y envelope API.

### Frontend

- Estados vacío/carga/error/stale y máximo 3 tarjetas.
- Copy/explicación determinista y CTAs según permisos.
- Preferencias por categoría y consentimiento push.
- Aceptar/descartar persiste y no reaparece tras refresh/socket.

### Plan

1. `feat(backend): añadir modelo y motor de recomendaciones por reglas (TD-068)`
2. `test(backend): cubrir hábitos, olvido, carga y deduplicación (TD-068)`
3. `feat(backend): exponer recomendaciones y preferencias (TD-068)`
4. `feat(frontend): presentar sugerencias y controles de frecuencia (TD-068)`
5. `test(frontend): cubrir tarjetas, acciones y preferencias (TD-068)`
6. `docs: documentar contratos y operación de recomendaciones (TD-068)`

Este PR solo contiene el commit documental solicitado.

## 9. Riesgos, rollback y pruebas manuales

### Riesgos

- Falsos positivos por título normalizado o histórico escaso.
- Queries costosas sobre histórico sin índices/precálculo.
- Spam por regeneración, varios dispositivos o timezone.
- Recomendaciones de carga percibidas como juicio o ranking.
- Uso de `updatedAt` como proxy impreciso.
- Preferencias divergentes entre dispositivos.

### Rollback

- Feature flag por hogar/usuario y kill switch del job/push.
- Motor read-only: desactivarlo no modifica tareas.
- Versionar reglas (`ruleVersion`) para invalidar sugerencias antiguas.
- Desactivar primero entrega push, luego generación; conservar métricas anonimizadas/agregadas según política aprobada.

### Pruebas manuales

1. Sembrar 3/4/5 completaciones regulares e irregulares y revisar explicación.
2. Probar límites X y vencimiento con reloj controlado.
3. Activar una recurrencia existente y comprobar cero duplicados.
4. Repartir carga desigual con tareas multi-asignadas y verificar tono no competitivo.
5. Desactivar cada categoría en un dispositivo y comprobar otro.
6. Abrir repetidamente, reconectar sockets y cruzar semana: respetar cooldown.
7. Modo avión con sugerencia cacheada; acción se reconcilia al volver.

## 10. Preguntas abiertas

- ¿Se aprueban N=4, M=8 semanas y las tolerancias como baseline de piloto?
- ¿Cómo se normalizan títulos y cómo se corrigen falsos agrupamientos?
- ¿Las tareas sin asignar cuentan en carga?
- ¿Día/hora y canal del digest, por usuario o por hogar?
- ¿Qué ocurre con sugerencias activas al desactivar una categoría?
- ¿Se crea un event log de actividad o se acepta `updatedAt` como proxy v1?

## Proposed Improvements

- Añadir un historial mínimo de eventos de tarea antes de usar «sin actividad» como señal fuerte.
- Medir precisión, aceptación, descartes y silencios por regla/versión antes de habilitar push.
- Diseñar índices/rollups con `explain` y cardinalidad real; no reutilizar el agregado de estadísticas como si midiera carga.
- Mantener plantillas explicables y evitar lenguaje de culpa, ranking o productividad individual.
- Coordinar timezone con TD-013 y push con TD-049.
- Resolver, con autorización del dueño, la colisión futura de IDs propuesta en `TD-065-DESIGN.md`; este PR no la modifica.

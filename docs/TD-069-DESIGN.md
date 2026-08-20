# TD-069 — Diseño de reparto inteligente de carga doméstica

> Estado: Open. Prioridad: High. Diseño documental; no implementa código, tests ni CI. Diferencial funcional del punto 11 del PDF del dueño.

## 0. Alcance y criterio de evidencia

El objetivo es estimar y hacer visible el reparto de trabajo doméstico sin convertirlo en una clasificación de personas. El sistema usa reglas deterministas y explicables, propone redistribución solo ante desequilibrio persistente y protege privacidad y convivencia.

- **Causa confirmada:** comportamiento o dato visto en el código actual.
- **Hipótesis:** consecuencia inferida que requiere datos o reproducción.
- **Pregunta abierta:** decisión no cerrada por el prompt, PDR o código; no se decide aquí.

## Decisiones aprobadas

1. **D4 — Proxy de peso.** V1 usa el peso automático canónico de P1 antes de presupuesto, recompensa cobrada y ajustes manuales. Cada snapshot conserva `weightSource` y `weightVersion`; duración/categoría queda descartada en v1.
2. **D5 — Ventana.** El balance usa semana natural, de lunes a domingo, coherente con las misiones y el presupuesto x/6.
3. **D6 — Persistencia.** Se activa la señal cuando un miembro supera el 65 % de la carga durante dos semanas consecutivas. El umbral es configurable.
4. **D7 — Muestra mínima.** Se necesitan cinco tareas con peso en la semana para mostrar el balance.
5. **D8 — Tareas sin asignar.** No cuentan en el balance por miembro; se muestran como sugerencia de asignación conectada con TD-068.
6. **D9 — Ubicación.** V1 vive en la vista de estadísticas del hogar existente y se integrará en el dashboard de salud del hogar cuando este se diseñe.

## 1. Estado actual

### Datos disponibles

**Causa confirmada:** `Task` guarda hogar, título, descripción, asignados múltiples, autor, estado, prioridad, categoría, `dueDate`, duración opcional (`startsAt`/`endsAt`), `completedAt`, `completedBy`, recurrencia y timestamps. La duración no se combina actualmente con recurrencia.

**Causa confirmada:** las tareas completadas permiten atribuir quién realizó la primera completación mediante `completedBy`; las pendientes permiten observar asignación actual mediante `assignedTo`. Una tarea puede estar sin asignar o tener varios asignados.

**Causa confirmada:** `household-stats.service.ts` solo calcula tareas creadas/completadas, tasa de completado, `memberStats` y `topCompleter` para 30 días o todo el histórico. No consulta tareas pendientes por asignado, no pondera esfuerzo/duración y no calcula carga semanal.

Por tanto, la carencia de carga pendiente es **causa confirmada**, no hipótesis. Tampoco existe hoy un campo de dificultad o peso doméstico.

**Causa confirmada:** PDR-011 descartó dificultad manual en v1 y fijó un reparto automático determinista del presupuesto semanal por frecuencia esperada. TD-066 propone `WeeklyPersonalBudget.allocations[]` con `coinAmount`, `expectedFrequency` y modo automático/manual, pero esos modelos todavía no están implementados.

### Límites de los datos

- `priority` expresa urgencia, no esfuerzo; no debe usarse como sinónimo de peso.
- `startsAt/endsAt` puede aproximar duración cuando existe, pero muchas tareas son instantáneas o no tienen bloque horario.
- `completedAt` dice cuándo terminó una tarea, no cuánto trabajo real requirió.
- El título/descripcion no se interpreta con IA ni con heurísticas semánticas opacas.

## 2. Modelo de carga doméstica estimada

### Proxy aprobado para v1

D4 fija como proxy v1 el **peso automático canónico previo al presupuesto** que calcule el mismo motor de PDR-011/TD-066 para distribuir valor entre tareas. No se usa la recompensa realmente cobrada ni el ajuste manual del usuario:

```text
automaticBaseWeight(taskOrRule, weekSnapshot) -> entero positivo
taskWeight(occurrence) = automaticBaseWeight de su tarea/regla en esa semana
```

Esta elección evita reintroducir dificultad manual, reutiliza una explicación que el usuario ya verá en «Ajustar reparto» y mantiene el peso estable aunque una persona agote su presupuesto o cambie temporalmente su `coinAmount` manual. La moneda concedida puede ser cero por cap; el trabajo realizado no pasa a pesar cero. Cada snapshot guarda `weightSource` y `weightVersion` para que una semana no cambie al desplegar reglas nuevas. Un motor alternativo de duración/categoría queda explícitamente descartado en v1.

### Snapshot e inmutabilidad semanal

Al generar una ocurrencia elegible se guarda o resuelve un snapshot de peso para la semana. Editar una asignación no reescribe el peso; cambiar la regla automática solo afecta semanas futuras. Los ajustes manuales de monedas de PDR-011 nunca alteran la métrica de carga, evitando que la percepción del reparto pueda manipularse desde el presupuesto.

## 3. Balance semanal

### Dos métricas separadas

1. **Carga asumida/realizada:** trabajo completado durante la ventana, atribuido a `completedBy`.
2. **Carga prevista pendiente:** trabajo aún pendiente con vencimiento dentro de la ventana, distribuido entre `assignedTo`.

No se suman en una única cifra opaca. El headline «Miguel ha asumido ~68 %» se refiere siempre a carga realizada; la redistribución opera sobre carga prevista.

Para semana `S`, miembro activo `m` y ocurrencias elegibles no borradas:

```text
realizedLoad(m, S) = Σ taskWeight(o)
  para o completada por m y completedAt dentro de S

realizedHouseholdLoad(S) = Σ realizedLoad(m, S)
realizedShare(m, S) = 100 × realizedLoad(m, S) / realizedHouseholdLoad(S)

plannedLoad(m, S) = Σ taskWeight(o) / max(1, |assignedTo(o)|)
  para o pendiente, debida dentro de S y asignada a m
```

Una tarea compartida pendiente reparte su peso por igual para no multiplicarlo. Al completarse, el peso realizado se atribuye solo a `completedBy`, que es quien ejecutó la primera completación confirmada. Las tareas sin asignar se muestran en un bucket «Por repartir» y no inflan el porcentaje de ningún miembro.

Ejemplo explicable:

```text
Miguel: 17 puntos de carga realizada
Resto del hogar: 8 puntos
Total: 25
17 / 25 = 68 %
```

La UI redondea y antepone «aproximadamente»: «Miguel ha asumido aproximadamente el 68 % de la carga estimada esta semana.»

### Ventana temporal

D5 fija una semana natural de lunes a domingo en la timezone IANA que TD-066 define para presupuesto y economía. Se modela como intervalo semiabierto `[lunes 00:00, lunes siguiente 00:00)` para cubrir correctamente el domingo y los cambios DST. Así el reparto comparte frontera con las misiones y el presupuesto x/6. La semana actual se presenta «hasta hoy» y no activa por sí sola una alerta persistente.

No se publica porcentaje si el denominador es cero. D7 exige al menos cinco tareas con peso contabilizadas en el balance por miembro dentro de la semana; con cuatro o menos se muestra el estado de muestra insuficiente. Las tareas sin asignar quedan fuera de esta muestra conforme a D8.

## 4. Sugerencias de redistribución

### Detección persistente

Regla aprobada y configurable:

```text
desequilibrio semanal si realizedShare(m, S) > 65 %
persistente si ocurre durante 2 semanas naturales completas consecutivas
y cada semana contiene al menos 5 tareas con peso contabilizadas en el balance por miembro
```

El valor exacto de 65 % no activa la señal; debe superarse. El porcentaje y el número de semanas se guardan como configuración para poder calibrarlos sin cambiar la fórmula. No se infiere culpa, voluntad ni disponibilidad personal.

### Selección de tareas reasignables

El sistema propone, pero nunca reasigna automáticamente. Ordena tareas:

1. pendientes y no borradas;
2. asignadas al miembro con mayor carga prevista;
3. con `dueDate` posterior a 24 horas, para evitar mover una urgencia sin contexto;
4. con otro miembro activo cuya carga prevista sea menor;
5. preferentemente instancias individuales; no modifica toda una serie recurrente sin confirmación específica;
6. excluye operaciones en vuelo/offline hasta sincronizar.

El CTA respeta permisos: reasignar es editar una tarea, así que solo creador o admin puede confirmar según la Hard Rule 17. Para el resto, la tarjeta permite revisar/coordinar, no ejecutar una mutación prohibida.

### Copy exacto en español

**Sugerencia persistente**

- Título: «Revisad el reparto con calma»
- Cuerpo: «Durante 2 semanas, Miguel ha asumido aproximadamente el 68 % de la carga estimada. Hay 3 tareas próximas que podéis repartir de otra forma.»
- CTA principal: «Ver opciones»
- CTA secundaria: «Ahora no»

**Detalle de opciones**

- Encabezado: «Ideas para repartir mejor»
- Ayuda: «Son sugerencias basadas en tareas y tiempos estimados. Vosotros decidís qué encaja en casa.»
- Acción con permiso: «Reasignar tarea»
- Acción sin permiso: «Ver tarea»

**Estado equilibrado**

- «El reparto está bastante equilibrado esta semana.»

**Muestra insuficiente**

- «Aún no hay suficientes tareas esta semana para estimar el reparto.»

No se usan mensajes como «Miguel trabaja más», «Ana aporta menos», «ganador», «último» o «debería hacer». Tampoco se envía el porcentaje con nombres en una notificación visible en pantalla bloqueada por defecto.

## 5. Sin leaderboard, privacidad y tono

- Nunca ordenar miembros de mayor a menor ni mostrar puestos, medallas o top completer dentro de esta experiencia.
- Presentar una distribución conjunta y su evolución; el foco es «cómo está el hogar», no «quién gana».
- Mostrar las cifras solo a miembros actuales del hogar, tras membership server-authoritative.
- Exmiembros conservan atribución histórica mínima donde proceda, pero no aparecen en sugerencias de reparto futuro.
- No usar títulos/descripciones de tareas en telemetría; registrar ids, pesos, versión de regla y resultado agregado.
- Permitir descartar una sugerencia y aplicar cooldown; no insistir en cada apertura.

**Causa confirmada:** las estadísticas actuales sí exponen `topCompleter`. TD-069 no lo reutiliza ni lo amplía; el módulo de equilibrio dentro de la vista de estadísticas es una superficie distinta y no añade un ranking nuevo.

## 6. Presentación y dashboard de salud del hogar

Según D9, v1 se integra en la vista de estadísticas del hogar existente:

- `StatsPage`: bloque «Equilibrio de carga» con gráfico de proporciones sin orden competitivo, carga realizada y prevista separadas y explicación del proxy.
- Dentro del mismo flujo: bucket «Por repartir» y acceso a sugerencias de reasignación; las tareas sin asignar se presentan como sugerencias de asignación conectadas con TD-068.
- Futuro: cuando se diseñe el «Dashboard de salud del hogar» del punto 17, este bloque se integrará allí sin crear mientras tanto una pantalla paralela.

No se añade en v1 una tarjeta separada en Home ni un digest/push específico de balance.

## 7. Dependencias de datos y bloqueo

La decisión D4 depende de los modelos de TD-066:

- `WeeklyPersonalBudget.allocations[]` o una proyección canónica equivalente;
- `automaticBaseWeight`, `weightVersion` y snapshot por ocurrencia/semana;
- timezone IANA y fronteras de semana;
- `RewardGrant`/primera completación para no contar retries;
- `HouseholdMember` como autoridad de miembros activos.

Por tanto, TD-069 queda **bloqueado por el cutover de TD-001 y por la base de economía de TD-066**. Se puede prototipar el cálculo sobre fixtures, pero no activar porcentajes reales con pesos inventados mientras falte esa fuente. La alternativa independiente de duración/categoría no forma parte de v1.

## 8. Casos borde

| Caso | Tratamiento |
|---|---|
| Hogar de una persona | Mostrar «Tu hogar de una persona también cuenta», sin porcentaje comparativo ni sugerencia de redistribución. |
| Miembro nuevo | Entra en carga prevista desde el alta; no se comparan semanas anteriores como si hubiera estado presente. El snapshot conserva la cohorte activa de cada semana. |
| Miembro que sale | Se conserva carga realizada histórica; se retira de pendientes y sugerencias futuras según TD-018/TD-067. |
| Tarea sin asignar | No cuenta en el balance por miembro. Aparece en «Por repartir» como sugerencia de asignación conectada con TD-068. |
| Tarea compartida pendiente | Peso dividido entre asignados activos. |
| Tarea compartida completada | Todo el peso realizado va a `completedBy`; no se reparte por asignación previa. |
| Sin `completedBy` histórico | Excluir del reparto individual y mostrarlo como carga histórica sin atribución; no adivinar autor. |
| Tarea con duración y recurrencia | El código actual no combina ambas; usar el snapshot de la instancia/regla aprobado por P1, sin inferir duración ausente. |
| Cambio de peso a mitad de semana | El snapshot conserva versión y peso originales hasta la semana siguiente. |
| Operación offline tardía | Se atribuye a la semana server-authoritative de `occurredAt` validado por TD-066; la UI recalcula y etiqueta la actualización. |
| Muy pocas tareas | Con menos de cinco tareas con peso contabilizadas en el balance por miembro no se muestra porcentaje ni señal de desequilibrio; aparece el estado de muestra insuficiente. |
| Diferente disponibilidad personal | No se infiere desde actividad. **Pregunta abierta:** cualquier ajuste por vacaciones/cuidados requiere una señal voluntaria futura. |

## 9. Tests nuevos y plan de commits atómicos

### Backend y dominio

- Peso automático estable; ajustes manuales/cap monetario no alteran carga.
- Fórmula 17/25 → 68 % y redondeo determinista.
- Semana natural/timezone/DST y semana parcial sin alerta.
- Tarea compartida pendiente fraccionada y completada atribuida a `completedBy`.
- Sin asignar, exmiembro, alta a mitad de semana, hogar de uno y muestra insuficiente.
- Umbral justo por debajo/en/encima del 65 %, persistencia de dos semanas y configuración alternativa.
- Muestra de cuatro/cinco tareas con peso contabilizadas por miembro y exclusión de tareas sin asignar.
- Primera completación/retry offline no duplica peso.
- Selección de reasignables y permisos creador/admin.

### Frontend

- Copy exacto, estado equilibrado e insuficiente.
- Distribución sin orden/ranking y accesibilidad del gráfico.
- Carga realizada y prevista claramente separadas.
- Miembro sin permiso no ve mutación de reasignación.
- Preferencias/cooldown y ausencia de datos sensibles en notificaciones.

### Plan futuro

1. `feat(backend): añadir snapshot automático de peso de carga (TD-069)`
2. `test(backend): cubrir balance semanal y persistencia (TD-069)`
3. `feat(backend): generar sugerencias de redistribución (TD-069)`
4. `feat(frontend): mostrar equilibrio y opciones de reparto (TD-069)`
5. `test(frontend): cubrir tono, privacidad y ausencia de ranking (TD-069)`
6. `docs: documentar proxy y operación del reparto (TD-069)`

El presente PR solo contiene el commit documental solicitado.

## 10. Riesgos, rollback y pruebas manuales

### Riesgos

- Convertir moneda en falso sinónimo de esfuerzo si el proxy P1 solo refleja frecuencia/presupuesto.
- Falsos conflictos familiares por muestras pequeñas o tono acusatorio.
- Comparar semanas con miembros distintos sin snapshot de cohorte.
- Coste de agregaciones históricas y deriva al cambiar reglas de peso.
- Filtrar nombres/porcentajes en push, logs o analítica.
- Reasignar una serie completa cuando solo se pretendía mover una instancia.

### Rollback

- Feature flag por hogar/usuario para ocultar el bloque de `StatsPage` y sus sugerencias.
- Motor read-only: desactivarlo no modifica asignaciones ni tareas.
- Versionar snapshots/reglas; no recalcular historia silenciosamente.
- Desactivar primero notificaciones/sugerencias, después agregados; conservar datos base sin crear un ranking alternativo.

### Pruebas manuales

1. Crear una semana de cinco o más tareas con reparto 17/25 y comprobar «aproximadamente el 68 %».
2. Crear dos semanas completas por encima del 65 % y comprobar la sugerencia; una sola semana o exactamente 65 % no sugieren.
3. Ajustar monedas manualmente y verificar que el peso no cambia.
4. Probar tareas compartidas, sin asignar y alta/salida de miembro.
5. Cambiar timezone cerca de domingo/lunes y verificar snapshot/frontera.
6. Abrir como admin, creador y miembro sin permisos; solo quien puede editar reasigna.
7. Revisar el bloque de `StatsPage` con lector de pantalla y comprobar que no existe push de balance con nombres/porcentajes.
8. Apagar el feature flag: tareas y estadísticas actuales siguen intactas.

## 11. Preguntas abiertas

- Señal voluntaria futura para disponibilidad personal, si se considera necesaria.

## Proposed Improvements

- Eliminar `topCompleter` de futuras superficies de salud o aislarlo claramente para no contradecir el principio sin leaderboard.
- Guardar snapshot de cohorte, peso y versión por semana para explicabilidad y auditoría.
- Medir descartes y falsos positivos antes de activar cualquier digest/push.
- Diseñar índices/rollups solo después de medir cardinalidad; evitar agregaciones completas en cada apertura.
- Añadir revisión de privacidad específica para telemetría y notificaciones de equilibrio.
- Coordinar TD-069 con TD-066 para que presupuesto y carga compartan cálculo automático sin acoplar carga a la recompensa cobrada.

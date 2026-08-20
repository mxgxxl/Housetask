# TD-069 — Diseño de reparto inteligente de carga doméstica

> Estado: Open. Prioridad: High. Diseño documental; no implementa código, tests ni CI. Diferencial funcional del punto 11 del PDF del dueño.

## 0. Alcance y criterio de evidencia

El objetivo es estimar y hacer visible el reparto de trabajo doméstico sin convertirlo en una clasificación de personas. El sistema usa reglas deterministas y explicables, propone redistribución solo ante desequilibrio persistente y protege privacidad y convivencia.

- **Causa confirmada:** comportamiento o dato visto en el código actual.
- **Hipótesis:** consecuencia inferida que requiere datos o reproducción.
- **Pregunta abierta:** decisión no cerrada por el prompt, PDR o código; no se decide aquí.

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

### Proxy recomendado y alternativa

**Recomendación:** usar como proxy v1 el **peso automático canónico previo al presupuesto** que calcule el mismo motor de PDR-011/TD-066 para distribuir valor entre tareas. No se usa la recompensa realmente cobrada ni el ajuste manual del usuario:

```text
automaticBaseWeight(taskOrRule, weekSnapshot) -> entero positivo
taskWeight(occurrence) = automaticBaseWeight de su tarea/regla en esa semana
```

Esta elección evita reintroducir dificultad manual, reutiliza una explicación que el usuario ya verá en «Ajustar reparto» y mantiene el peso estable aunque una persona agote su presupuesto o cambie temporalmente su `coinAmount` manual. La moneda concedida puede ser cero por cap; el trabajo realizado no pasa a pesar cero.

**Alternativa:** un motor independiente de duración/categoría:

```text
effectiveMinutes = duración explícita si startsAt/endsAt son válidos
                 = default automático versionado por categoría en otro caso
weight = max(1, round(effectiveMinutes / unidadDeTiempo))
```

La alternativa puede aproximar mejor el esfuerzo que un reparto basado sobre todo en frecuencia, pero exige defaults de categoría que el dueño no ha aprobado y duplica reglas respecto a P1.

**Pregunta abierta — decisión de proxy:** confirmar si la fuente autoritativa será (A) `automaticBaseWeight` compartido con P1 —recomendado— o (B) duración/categoría automática. No se mezclan ambos silenciosamente: cada snapshot guarda `weightSource` y `weightVersion` para que una semana no cambie al desplegar reglas nuevas.

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

**Pregunta abierta:** semana natural o rolling 7 días.

**Recomendación:** semana natural en la timezone IANA que TD-066 fija para presupuesto y economía. Así el reparto comparte frontera con el plan semanal y permite comparar semanas completas. La semana actual se presenta «hasta hoy» y no activa por sí sola una alerta persistente. Rolling 7 días puede añadirse como vista exploratoria, pero no debe mezclarse con el detector semanal.

No se publica porcentaje si el denominador es cero. **Pregunta abierta:** mínimo de muestra antes de mostrar una cifra; recomendación inicial para piloto: al menos 4 ocurrencias y 8 puntos de peso en la ventana.

## 4. Sugerencias de redistribución

### Detección persistente

Para `H` miembros activos, la referencia neutral es `expectedShare = 100 / H`.

Baseline configurable recomendado:

```text
deviation(m, S) = realizedShare(m, S) - expectedShare(S)
desequilibrio semanal si deviation >= X, con X = 15 puntos porcentuales
persistente si ocurre durante N = 2 semanas naturales completas consecutivas
y cada semana supera el mínimo de muestra aprobado
```

En un hogar de dos personas, el umbral empieza en 65 %, por lo que dos semanas alrededor de 68 % cumplen la señal. No se infiere culpa, voluntad ni disponibilidad personal. **Pregunta abierta:** aprobar `X=15`, `N=2` y el mínimo de muestra tras medir falsos positivos en el piloto.

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

**Causa confirmada:** las estadísticas actuales sí exponen `topCompleter`. TD-069 no lo reutiliza ni lo amplía; el dashboard de equilibrio es una superficie distinta y no añade un ranking nuevo.

## 6. Presentación y dashboard de salud del hogar

El equilibrio de carga es un componente del futuro «Dashboard de salud del hogar» del punto 17 del PDF:

- Home: tarjeta compacta solo cuando hay datos suficientes, con distribución agregada y acceso al detalle.
- Dashboard: gráfico de proporciones sin orden competitivo, toggle «Esta semana / Tendencia», carga realizada y prevista separadas, bucket «Por repartir» y explicación del proxy.
- Tareas: módulo contextual con las tareas candidatas a redistribución.
- Digest: como máximo una mención semanal y solo si las preferencias futuras lo permiten; sin nombres/porcentajes en lock screen por defecto.

**Pregunta abierta:** si el dashboard de salud se implementa como nueva pantalla o extensión de `StatsPage`. No se decide navegación en esta ficha.

## 7. Dependencias de datos y bloqueo

La recomendación A depende de los modelos de TD-066:

- `WeeklyPersonalBudget.allocations[]` o una proyección canónica equivalente;
- `automaticBaseWeight`, `weightVersion` y snapshot por ocurrencia/semana;
- timezone IANA y fronteras de semana;
- `RewardGrant`/primera completación para no contar retries;
- `HouseholdMember` como autoridad de miembros activos.

Por tanto, TD-069 queda **bloqueado por el cutover de TD-001 y por la base de economía de TD-066** si se aprueba el proxy recomendado. Se puede prototipar el cálculo sobre fixtures, pero no activar porcentajes reales con pesos inventados mientras falte esa fuente.

Si el dueño aprueba la alternativa independiente de duración/categoría, la dependencia económica se reduce, pero TD-001 sigue siendo necesaria para cohortes de miembros fiables y habría que aprobar los defaults automáticos antes de producción.

## 8. Casos borde

| Caso | Tratamiento |
|---|---|
| Hogar de una persona | Mostrar «Tu hogar de una persona también cuenta», sin porcentaje comparativo ni sugerencia de redistribución. |
| Miembro nuevo | Entra en carga prevista desde el alta; no se comparan semanas anteriores como si hubiera estado presente. `expectedShare` usa el snapshot de miembros de cada semana. |
| Miembro que sale | Se conserva carga realizada histórica; se retira de pendientes y sugerencias futuras según TD-018/TD-067. |
| Tarea sin asignar | Bucket «Por repartir»; no se atribuye a nadie. **Pregunta abierta:** si debe contar en el denominador general de carga prevista del hogar. |
| Tarea compartida pendiente | Peso dividido entre asignados activos. |
| Tarea compartida completada | Todo el peso realizado va a `completedBy`; no se reparte por asignación previa. |
| Sin `completedBy` histórico | Excluir del reparto individual y mostrarlo como carga histórica sin atribución; no adivinar autor. |
| Tarea con duración y recurrencia | El código actual no combina ambas; usar el snapshot de la instancia/regla aprobado por P1, sin inferir duración ausente. |
| Cambio de peso a mitad de semana | El snapshot conserva versión y peso originales hasta la semana siguiente. |
| Operación offline tardía | Se atribuye a la semana server-authoritative de `occurredAt` validado por TD-066; la UI recalcula y etiqueta la actualización. |
| Muy pocas tareas | No porcentaje ni sugerencia; estado de muestra insuficiente. |
| Diferente disponibilidad personal | No se infiere desde actividad. **Pregunta abierta:** cualquier ajuste por vacaciones/cuidados requiere una señal voluntaria futura. |

## 9. Tests nuevos y plan de commits atómicos

### Backend y dominio

- Peso automático estable; ajustes manuales/cap monetario no alteran carga.
- Fórmula 17/25 → 68 % y redondeo determinista.
- Semana natural/timezone/DST y semana parcial sin alerta.
- Tarea compartida pendiente fraccionada y completada atribuida a `completedBy`.
- Sin asignar, exmiembro, alta a mitad de semana, hogar de uno y muestra insuficiente.
- Umbral justo por debajo/en/encima de X y persistencia N semanas.
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

- Feature flag por hogar/usuario para ocultar tarjeta, dashboard y sugerencias.
- Motor read-only: desactivarlo no modifica asignaciones ni tareas.
- Versionar snapshots/reglas; no recalcular historia silenciosamente.
- Desactivar primero notificaciones/sugerencias, después agregados; conservar datos base sin crear un ranking alternativo.

### Pruebas manuales

1. Crear una semana 17/25 y comprobar «aproximadamente el 68 %».
2. Repetir una semana y cruzar el umbral; una sola semana no sugiere.
3. Ajustar monedas manualmente y verificar que el peso no cambia.
4. Probar tareas compartidas, sin asignar y alta/salida de miembro.
5. Cambiar timezone cerca de domingo/lunes y verificar snapshot/frontera.
6. Abrir como admin, creador y miembro sin permisos; solo quien puede editar reasigna.
7. Revisar dashboard con lector de pantalla y push en lock screen: sin exposición de nombres/porcentajes.
8. Apagar el feature flag: tareas y estadísticas actuales siguen intactas.

## 11. Preguntas abiertas

- Proxy autoritativo: `automaticBaseWeight` compartido con P1 o duración/categoría automática.
- Semana natural —recomendada— o rolling 7 días.
- Umbrales de piloto: X=15 puntos, N=2 semanas y mínimo de muestra.
- Inclusión de tareas sin asignar en el denominador de carga prevista.
- Pantalla nueva de salud o extensión de `StatsPage`.
- Señal voluntaria futura para disponibilidad personal, si se considera necesaria.

## Proposed Improvements

- Eliminar `topCompleter` de futuras superficies de salud o aislarlo claramente para no contradecir el principio sin leaderboard.
- Guardar snapshot de cohorte, peso y versión por semana para explicabilidad y auditoría.
- Medir descartes y falsos positivos antes de activar cualquier digest/push.
- Diseñar índices/rollups solo después de medir cardinalidad; evitar agregaciones completas en cada apertura.
- Añadir revisión de privacidad específica para telemetría y notificaciones de equilibrio.
- Coordinar TD-069 con TD-066 para que presupuesto y carga compartan cálculo automático sin acoplar carga a la recompensa cobrada.

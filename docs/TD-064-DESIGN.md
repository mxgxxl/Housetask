# TD-064 — Diseño de paginación del timeline

> Estado: propuesta de diseño, 2026-08-20. `TD-004` ya existe y está resuelto; `TD-064` es el siguiente ID libre verificado. Este documento no cambia código ni el registro de deuda técnica.

## 1. Causa raíz y evidencia

### Causa confirmada (histórica, resuelta)

La pérdida de `timelineCursor` existió en `frontend/lib/presentation/cubit/task_cubit.dart`: el `copyWith` de `TaskState` asignaba a `null` los campos nullable que un `emit` no volvía a pasar. Por tanto, un `emit` ajeno entre `loadTimeline()` y `loadMoreTimeline()` borraba el cursor; la guarda interpretaba que no había página pendiente y ensanchaba la ventana antes de agotar la actual.

Esa es la causa confirmada en el código anterior y está resuelta por TD-056: los campos persistentes usan `clearTimelineCursor`, y el test intercala `clearOfflineNotice()` antes de paginar. No hay evidencia en el código actual de que el mismo cursor se siga perdiendo.

### Hallazgos confirmados en el código actual

1. No existen `timeline.service.ts`, `timeline.controller.ts` ni `timeline_cubit.dart` separados. La implementación vive en `backend/src/services/task.service.ts`, `backend/src/controllers/task.controller.ts` y `frontend/lib/presentation/cubit/task_cubit.dart`.
2. La primera carga del timeline sigue llamando `TaskRepository.list()` con `cursor == null`, `status == null` y una ventana `from`/`to`. Esa combinación pasa por `CacheService.saveTasks`, que reemplaza la caché de tareas del hogar aunque la respuesta es solo una ventana de fechas. La propia nota de TD-045 identifica este caso adyacente: se pierde la instantánea offline previa fuera de la ventana, no el cursor.
3. Al agotar una ventana, `loadMoreTimeline()` amplía `to` y vuelve a pedir la primera página de todo el superconjunto con `cursor == null`. `_mergeTimelineItems` evita filas duplicadas visualmente, pero el backend vuelve a recorrer elementos ya vistos —incluidos los sin fecha, que el filtro actual devuelve en cada ventana— antes de alcanzar fechas nuevas. Es una ineficiencia de paginación confirmada por el flujo de código, no una pérdida de cursor.

### Hipótesis pendientes de verificación

- No se ha reproducido contra un hogar real si el refetch de superconjuntos provoca una latencia visible al llegar a semanas con muchas tareas o sin fecha.
- No se ha medido si una mutación o un evento Socket entre dos páginas vuelve obsoleto un cursor válido. El Cubit conserva el cursor; que la experiencia requiera refresh depende de la distribución real de escrituras y debe medirse.
- No hay evidencia de que el límite actual de 50 filas sea insuficiente para una ventana normal. El diseño no trata esa hipótesis como causa confirmada.

## 2. Diseño propuesto

### Decisión: keyset cursor, no offset

Se mantiene la paginación cursor-based. Offset-based requeriría saltar y contar filas a medida que crece el historial, y desplazaría o duplicaría resultados cuando una tarea se crea, completa, cambia de fecha o se borra durante el scroll. El cursor keyset conserva una posición sobre un orden total y ya es el patrón del repositorio (ADR-008).

Se introduce una lectura especializada de timeline, sin alterar el endpoint genérico de tareas:

- Las tareas fechadas se ordenan por `dueDate ASC, _id ASC`; `_id` deshace empates y hace total el orden.
- El cursor opaco contiene versión, límite de inicio de la sesión (`from`), última `dueDate` e `_id`. El servidor rechaza un cursor cuyo `from` no coincide con la consulta.
- El timeline solo recorre tareas activas con fecha. «Sin fecha» viaja por una paginación separada, para que una lista grande de tareas sin fecha no reinicie ni contamine cada página fechada.

Índice propuesto: `{ householdId: 1, dueDate: 1, _id: 1 }`. El actual `{ householdId, status, dueDate }` no sirve bien a una lectura temporal que no filtra por `status`. El filtro de borrado suave se aplica como hoy; antes de convertir el nuevo índice en parcial hay que verificar el tratamiento de documentos legacy sin `isDeleted`.

### Caché e invalidación

La caché deja de interpretar una primera página con `from`/`to` como instantánea completa. Guarda tareas normalizadas por `householdId + taskId` y metadatos separados por consulta de timeline (`from`, cursor, páginas cargadas, estado de frescura). Cada página hace upsert por id; ninguna página de timeline sustituye toda la caché de tareas.

Una escritura o evento Socket hace upsert o eliminación por id y recalcula solo el grupo de día afectado. Si altera una tarea fuera de las páginas cargadas, se conserva el cursor y se muestra la nueva tarea cuando entre en la ventana; el pull-to-refresh reconcilia la primera página. Salir del hogar invalida en bloque las tareas y los metadatos de timeline de ese hogar.

## 3. API

La propuesta añade dos endpoints, ambos tras el middleware existente de autenticación y membresía:

```
GET /api/households/:householdId/tasks/timeline?from=<ISO>&limit=50&cursor=<opaco>
GET /api/households/:householdId/tasks/undated?limit=50&cursor=<opaco>
```

`from` es obligatorio en el endpoint temporal y representa el inicio local convertido a UTC por el cliente. El servidor devuelve siempre el envelope establecido:

```json
{
  "success": true,
  "data": {
    "items": ["…tareas…"],
    "nextCursor": "opaco o null",
    "hasMore": true,
    "total": 123
  }
}
```

`total` sigue devolviéndose solo en la primera página; las siguientes responden `null`, igual que ADR-008. No se usan headers para el cursor: el body mantiene la convención actual y permite cachear el envelope completo. El endpoint genérico `GET /tasks` permanece compatible mientras el rollout no esté validado.

## 4. Frontend

Extraer la responsabilidad a un `TimelineCubit` dedicado, con estado inmutable que contenga `itemsByDay`, `undated`, cursores independientes, `hasMore`, `isLoadingInitial`, `isLoadingMore`, `isRefreshing`, `isOffline`, `error` y un `generation` monotónico.

- **Carga inicial:** crea una generación y obtiene la primera página fechada y la de «Sin fecha»; conserva ambas separadas.
- **Prefetch:** el `ScrollController` solicita la siguiente página cuando `extentAfter < 600`; `isLoadingMore` y el cursor eliminan duplicados ante scroll rápido.
- **Pull-to-refresh:** no vacía las páginas ni el cursor antes de la respuesta. Incrementa `generation`, refresca las primeras páginas y reconcilia por id; una respuesta de una generación anterior se descarta. Si el refresh falla, conserva cursor y contenido ya cargado.
- **Offline:** renderiza la instantánea normalizada disponible, marca el estado como desactualizado y no anuncia más páginas remotas. Al reconectar, el refresh conserva el contenido hasta reconciliarlo.

El `TaskCubit` mantiene mutaciones y buckets existentes. Durante una transición, sus eventos Socket y operaciones optimistas alimentan el `TimelineCubit` mediante un método tipado de upsert/remove, sin llamadas HTTP completas por cada evento.

## 5. Casos borde

| Caso | Comportamiento esperado |
|---|---|
| Scroll rápido | Una única petición por cursor; solicitudes repetidas son no-op mientras haya carga. |
| Refresh durante scroll | La generación nueva invalida la respuesta tardía; el contenido y cursor previo permanecen visibles hasta una respuesta válida. |
| Nueva entrada durante scroll | Upsert por id y reubicación de día; no se reinicia el cursor. Si queda antes de la posición ya recorrida, aparece por Socket o en el refresh siguiente. |
| Edición, completado o borrado durante scroll | Actualizar/eliminar solo la fila y el grupo local; nunca usar offset para recalcular páginas ya vistas. |
| Miembro que sale del hogar | Cancelar/ignorar respuestas de la generación del hogar, borrar estado y caché de timeline antes de mostrar otro hogar. |
| Cursor inválido o de otra consulta | Backend responde 400; frontend descarta la sesión de timeline y reinicia la primera página, sin conservar el cursor inválido. |

## 6. Pruebas y plan de commits

### Pruebas nuevas

- Backend: recorrido completo de `timeline` con fechas iguales, mutaciones entre páginas y ausencia de huecos/duplicados; validación de cursor que no corresponde a `from`; lectura de `undated` separada; autorización de membresía.
- Datos/cache: una primera página de timeline no evacua tareas fuera de la ventana; upsert y delete actualizan un único día; fallback offline no inventa `hasMore` remoto.
- Cubit: prefetch coalescido, respuesta tardía descartada por `generation`, refresh fallido que conserva cursor, eventos Socket durante scroll y salida de hogar durante petición.
- Widget: el umbral de prefetch, indicador discreto offline y conservación visual de filas durante refresh.
- Manual: hogar con más de dos páginas fechadas, más de una página sin fecha, completar/editar desde otro dispositivo durante scroll, modo avión y cambio de hogar.

### Plan de commits atómicos

1. `feat(backend): add timeline keyset pagination` — índice, servicio, controller/rutas, Swagger y pruebas backend.
2. `refactor(frontend): isolate timeline cache metadata` — modelo de caché y pruebas de repositorio, sin cambiar UI.
3. `feat(frontend): add paginated timeline cubit` — Cubit, integración Socket y pruebas de Cubit.
4. `feat(frontend): prefetch timeline pages` — vista, pull-to-refresh, offline y pruebas widget.

## 7. Riesgos, rollback y pruebas manuales

| Riesgo | Mitigación / rollback |
|---|---|
| Nuevo índice aumenta coste de escritura | Crear y observar el índice antes de activar la ruta; se puede dejar sin usar y volver al endpoint actual. |
| Dos fuentes de estado durante migración | Mantener `GET /tasks` intacto y cambiar la UI solo cuando backend, caché y Cubit estén verificados. Revertir el cliente devuelve al comportamiento actual sin migración de datos. |
| Cursor inconsistente ante escrituras concurrentes | Orden total por fecha e id, upsert Socket y refresh explícito; registrar cursores rechazados para investigar. |
| Caché offline incompleta | Metadatos de frescura separados; ante duda, mostrar contenido como desactualizado y no afirmar que no hay más páginas. |

Antes de activar la ruta nueva, ejecutar las pruebas manuales de la sección 6 en dos dispositivos y comprobar que una salida de hogar no deja tareas o cursores del hogar previo en pantalla.

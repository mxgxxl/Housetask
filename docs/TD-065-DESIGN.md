# TD-065 — Auditoría estática de loading, error y retry (Fase 0)

> Estado: Open, prioridad High. Auditoría estática realizada el 2026-08-20. No se ha ejecutado `flutter analyze`, `flutter test` ni una prueba en dispositivo. Los hallazgos son candidatos para que Claude o el dueño los confirmen antes de abrir trabajo de implementación.

## 1. Alcance y método

El objetivo de esta Fase 0 es localizar rutas de Flutter que dependen de red, caché o Socket y que podrían terminar en una pantalla vacía, un estado contradictorio o una respuesta antigua sobrescribiendo una más nueva. No modifica código ni convierte por sí sola un candidato en un incidente reproducido.

### Archivos leídos

- Cubits: `auth_cubit.dart`, `household_cubit.dart`, `task_cubit.dart`, `shopping_cubit.dart`, `pet_cubit.dart`, `stats_cubit.dart` y `socket_cubit.dart`.
- Repositorios y datos: `auth_repository.dart`, `household_repository.dart`, `task_repository.dart`, `shopping_repository.dart`, `pet_repository.dart`, `api_service.dart` y `auth_local_datasource.dart`.
- Durabilidad y señal de red: `cache_service.dart`, `connectivity_service.dart` y `socket_service.dart`.
- Consumidores de estado: `app.dart`, `main.dart`, `session_listeners.dart`, `splash_page.dart`, `login_page.dart`, `register_page.dart`, `main_scaffold.dart`, `home_page.dart`, `tasks_page.dart`, `shopping_page.dart`, `stats_page.dart`, `calendar_page.dart`, `recurring_tasks_page.dart`, `trash_page.dart`, `pet_page.dart`, `pet_shop_page.dart` y `household_setup_page.dart`.

### Método y criterio de evidencia

Se siguió cada operación con `await` desde el Cubit al repositorio/API/caché y de vuelta a cada `emit`, además de sus consumidores visuales y de los callbacks Socket/conectividad. Se buscó en concreto: identidad de la petición, limpieza al cambiar sesión u hogar, coexistencia de carga y paginación, y ramas visuales para `initial`, `loading` y `error`.

- **Causa confirmada** significa que el mecanismo indicado está presente en el código actual: por ejemplo, una respuesta posterior puede ejecutar un `emit` sin comprobar que siga perteneciendo a la petición activa. No afirma que haya ocurrido en producción.
- **Hipótesis** significa que el disparador real o su impacto depende de timing, del servidor o de una ruta de UI que esta lectura no puede demostrar. Debe verificarse antes de priorizarla como bug.

## 2. Hallazgos por severidad

### Critical

No se ha identificado un hallazgo Critical mediante lectura estática. La ausencia de un caso Critical aquí no sustituye pruebas de sesión, conectividad ni dos dispositivos.

### High

| ID | Ubicación | Evidencia | Descripción | Reproducción sugerida |
|----|-----------|-----------|-------------|-----------------------|
| F0-01 | `frontend/lib/presentation/cubit/task_cubit.dart:434`, `:548`, `:648`, `:677`; `shopping_cubit.dart:187`; `pet_cubit.dart:96`; `household_cubit.dart:65`; `stats_cubit.dart:49` | **Causa confirmada (mecanismo).** Cada método conserva o cambia el id activo, hace `await` y emite el resultado sin generación, cancelación ni comprobación de que el hogar/sesión/periodo sigan siendo los de la petición iniciada. | Una respuesta iniciada para un hogar o sesión anterior puede repoblar el Cubit después de `reset()` o de cargar otro hogar. En tareas y compras también puede reemplazar una mutación optimista o una actualización Socket llegada durante la carga. El impacto visible exacto es pendiente de validar, pero el guard de frescura no existe en el código. | Con dos hogares, retrasar artificialmente `list/getById/getPet/stats`; iniciar la carga del hogar A, cambiar a B o cerrar sesión antes de resolver A y soltar A al final. Verificar que ningún Cubit ni caché visual muestra datos de A. Repetir con una actualización Socket o un toggle mientras el GET sigue en vuelo. |
| F0-02 | `frontend/lib/presentation/pages/splash_page.dart:27-37`; `household_cubit.dart:65-75`; `main_scaffold.dart:104-116` | **Causa confirmada.** Si `HouseholdCubit.loadHousehold` falla antes de asignar `current`, emite `error`; `SplashPage` navega de todos modos y `MainScaffold` solo distingue `empty` o `current == null`, para el que muestra un `CircularProgressIndicator` sin error ni retry. | Tras autenticar con usuario cacheado, un fallo de red/5xx/403 al cargar el hogar puede dejar la shell en spinner indefinido. El usuario no ve causa, reintento ni salida alternativa. | Guardar un `currentHouseholdId` válido, hacer que `GET /households/:id` responda 5xx o timeout y completar el flujo de splash. Confirmar spinner persistente y ausencia de CTA. Probar también 403 por pertenencia revocada. |
| F0-03 | `frontend/lib/presentation/pages/home_page.dart:22-115`, `:291-323`; `task_cubit.dart:434-466`; `shopping_cubit.dart:187-205` | **Causa confirmada.** Home solo deriva `allTasks` e `items` y no consulta `TaskStatusUi`/`ShoppingStatusUi`, `error` ni `isOffline`. | Mientras la primera carga está en curso o falla, Home representa tareas como «¡Nada pendiente!»/cero y compras como «La lista de compra está vacía». Es un empty state afirmativo sin explicar que los datos aún cargan o fallaron; además no ofrece retry local. | Abrir Home con red bloqueada antes de la primera carga y con caché vacía. Repetir dejando responder los GET después de varios segundos. Comprobar que el contenido cambia de falso vacío a datos sin haber explicado el estado intermedio. |
| F0-04 | `task_cubit.dart:495-542`, `:548-622`; `shopping_cubit.dart:207-235`; `tasks_page.dart:64-77`, `:186-216`, `:370-374`; `shopping_page.dart:35-45`, `:91-96` | **Causa confirmada (mecanismo).** `loadMore` y refresh/inicial pueden coexistir; no hay token de generación. En `TaskCubit.loadMore` el resultado se compone sobre el snapshot `current` tomado antes del `await`, por lo que una respuesta tardía puede restaurar ese snapshot. | Un pull-to-refresh, un evento Socket o una mutación durante paginación puede perder filas/cambios recientes, reintroducir una página antigua o dejar cursor/total incoherente. En Shopping se compone sobre el estado más reciente, pero tampoco se invalida una página que ya no corresponde al refresh. | Cargar dos páginas; mantener la segunda respuesta en espera; hacer pull-to-refresh o completar/editar desde otro dispositivo; liberar la segunda respuesta después. Comparar ids, cursores, total y el cambio local/Socket contra un GET fresco. Hacerlo también en «Todas» durante `loadMoreTimeline`. |

### Medium

| ID | Ubicación | Evidencia | Descripción | Reproducción sugerida |
|----|-----------|-----------|-------------|-----------------------|
| F0-05 | `stats_cubit.dart:49-61`; `stats_page.dart:24-35` | **Causa confirmada.** Dos llamadas a `load` para periodos distintos no se serializan ni se identifican. La respuesta antigua emite sus estadísticas conservando el `period` ya seleccionado por la llamada posterior. | El selector puede mostrar «Todo» con métricas de «30 días» (o al revés). Es un estado internamente contradictorio: el periodo es el último solicitado, los datos pueden ser de otra petición. | Retrasar `stats(last30days)`, seleccionar «Todo» antes de que acabe y hacer que la primera respuesta llegue la última. Validar el periodo del control, las cifras y la petición que las originó. |
| F0-06 | `tasks_page.dart:121-128`, `:186-216`; `shopping_page.dart:63-75`; `task_cubit.dart:518-540`; `shopping_cubit.dart:219-233`; `recurring_tasks_page.dart:24-37`; `trash_page.dart:43-55` | **Causa confirmada.** Las vistas enseñan error/retry solo cuando la lista está vacía. Un error de refresh o de paginación con datos previos queda almacenado en el estado, pero no se representa en la lista ni ofrece un retry explícito de esa página. | El usuario puede seguir viendo datos desactualizados sin saber que el refresh falló; en una página adicional no hay explicación de por qué no aparecen más filas. | Cargar datos, forzar 5xx en pull-to-refresh y después en la segunda página. Verificar si existe señal de stale/error, retry y si el cursor se conserva correctamente. Repetir en Recurrentes y Papelera. |
| F0-07 | `task_cubit.dart:405-416`; `shopping_cubit.dart:168-179`; `task_repository.dart:357-455`; `shopping_repository.dart:256-342` | **Hipótesis.** Se ve que `syncPending` no tiene una exclusión mutua de Cubit/repositorio; una acción manual y una transición offline→online pueden leer la misma cola. El efecto exacto depende de idempotencia y semántica de PATCH/DELETE del backend. | Dos sincronizaciones simultáneas pueden repetir lecturas, reordenar escrituras de la misma entidad o incrementar reintentos. Los POST de creación tienen clave de idempotencia; no se puede afirmar por lectura que update/delete sufran una pérdida o duplicado final. | Instrumentar un repositorio/fake API con barreras; lanzar `syncPending()` dos veces con create→update→delete en cola y comprobar orden, llamadas, retryCount, caché y servidor. Repetir con una reconexión emitida durante «Reintentar sincronización». |
| F0-08 | `socket_cubit.dart:32-49`; `socket_service.dart:18-39`, `:44-98`; `main_scaffold.dart:60-84` | **Causa confirmada para la gestión de salas; hipótesis para pérdida de eventos.** Al cargar un hogar nuevo se hace `joinHousehold` pero no hay `leaveHousehold` ni id actual en `SocketCubit`. Además, una segunda llamada a `connectAndListen` sustituye el socket mientras `_listenersBound` puede impedir registrar listeners de dominio en el nuevo objeto. | El cliente puede conservar salas de hogares anteriores y recibir tráfico que sus Cubits suelen filtrar. El evento de lote `tasks:batch_created` no lleva guard de hogar en este lado y provoca refresh del hogar actual. La pérdida de listeners requiere una segunda conexión por esta ruta, que no se ha demostrado en el flujo normal. | Cambiar de hogar y emitir `tasks:batch_created` en el anterior; medir GETs y estado. En un fake `SocketService`, llamar dos veces a `connectAndListen`, luego emitir `task:updated` en el segundo socket y comprobar si llega al Cubit. |

### Low

| ID | Ubicación | Evidencia | Descripción | Reproducción sugerida |
|----|-----------|-----------|-------------|-----------------------|
| F0-09 | `stats_page.dart:45-79`; `calendar_page.dart:69-124`; `profile_page.dart:70-122`; `pet_shop_page.dart:22-34` | **Causa confirmada para las ramas visuales; hipótesis para el disparador de algunas.** Stats puede renderizar únicamente el selector si está `initial` sin datos; Calendar convierte ausencia de `allTasks` en «Sin tareas este día»; Perfil oculta la tarjeta de hogar con `SizedBox.shrink`; Tienda mantiene spinner si `pet == null`, incluso si el estado global ya es error. | Son superficies que no distinguen de forma uniforme «sin datos», «cargando» y «no se pudo cargar». No todas son alcanzables en el flujo principal con los guards actuales, por lo que su frecuencia necesita verificación. | Montar cada pantalla con los estados `initial`, `loading`, `error` sin datos y `error` con datos stale. Comprobar copy, CTA y accesibilidad del reintento. |

## 3. Estados contradictorios y carreras

| Caso | Estado que puede resultar | Clasificación | Evidencia estática |
|------|---------------------------|---------------|--------------------|
| Cambio de hogar/sesión durante GET | Estado de B con contenido de A, o contenido posterior a `reset()` | Causa confirmada (mecanismo) | Los Cubits de F0-01 emiten después de `await` sin comprobar la identidad capturada ni una generación actual. |
| Cambio rápido de periodo | `StatsState.period` de la segunda pulsación con `stats` de la primera | Causa confirmada | `targetPeriod` se guarda en el primer emit; ambos éxitos posteriores usan `state.copyWith` sin validar su solicitud. |
| Refresh durante `loadMore` | Página/cursor/total basado en un snapshot anterior; en tareas puede borrar cambios intermedios | Causa confirmada (mecanismo) | `TaskCubit.loadMore` usa `current` capturado antes del GET; no hay invalidación al iniciar `load`. |
| Error de refresh con datos previos | `status == error` y datos visibles como si estuvieran al día, sin mensaje | Causa confirmada | Los builders comprueban error únicamente junto a una colección vacía. |
| `HouseholdStatusUi.empty` con `current` anterior | Estado representable contradictorio | Hipótesis de alcanzabilidad normal | `init` emite `copyWith(status: empty)` sin `clearCurrent`; el flujo habitual resetea antes de autenticar, pero no hay invariante dentro del Cubit. |
| Dos drenajes de cola | Dos lectores procesan la misma instantánea de `PendingOperation` | Hipótesis | No existe lock; el desenlace final depende de operaciones concurrentes de Hive y del backend. |

## 4. Pantallas con riesgo de vacío o explicación insuficiente

| Pantalla | Riesgo | Severidad | Estado esperado a diseñar/validar |
|----------|--------|-----------|-----------------------------------|
| Shell principal | Spinner permanente si falla la carga inicial de hogar | High | Error con CTA «Reintentar» y salida segura al selector de hogar cuando corresponda. |
| Inicio | Falso empty state de tareas/compras durante carga o error | High | Skeleton/carga, error inline y datos stale señalizados sin afirmar que la lista está vacía. |
| Tareas / Compras | Fallos de refresh y paginación invisibles con datos previos | Medium | Banner discreto de datos sin actualizar y retry de la operación fallida; no borrar la lista. |
| Estadísticas | Selector sin contenido inicial; periodo potencialmente desalineado | Medium | Carga/error explícitos y datos etiquetados con el periodo de la respuesta aceptada. |
| Recurrentes / Papelera | Un error con datos previos no se señala | Medium | Conservar contenido, explicar la desactualización y permitir reintentar. |
| Calendario / Perfil / Tienda de mascota | Empty/spinner sin distinguir ausencia de datos de fallo | Low | Estados de carga/error/empty separados y retry visible donde el recurso se puede recargar. |

## 5. TDs recomendados (no abiertos en esta auditoría)

Los IDs son recomendaciones pendientes de registro, renumeradas tras la colisión con TD-067 y TD-068; hay que comprobar el registro al abrirlas. No quedan reservadas hasta incorporarlas a `TECH_DEBT.md`.

| ID propuesto | Prioridad | Alcance de una línea |
|--------------|-----------|----------------------|
| TD-069 | High | Añadir generación/identidad de solicitud por hogar, sesión y periodo a cargas de `HouseholdCubit`, `TaskCubit`, `ShoppingCubit`, `PetCubit` y `StatsCubit`; descartar respuestas tardías. |
| TD-070 | High | Resolver la carga inicial de hogar fallida con UI de error/retry y transición segura, evitando el spinner indefinido de `MainScaffold`. |
| TD-071 | High | Modelar explícitamente loading/error/stale/empty en Home para tareas y compras, con reintento sin ocultar datos cacheados. |
| TD-072 | Medium | Serializar o invalidar refresh/paginación y expresar errores de página siguiente en Tareas/Compras/Recurrentes/Papelera. |
| TD-073 | Medium | Validar y, si se confirma, fijar exclusión mutua del drenaje offline y ciclo de salas/listeners Socket al cambiar de hogar. |

### Preguntas abiertas

- ¿El dueño quiere registrar TD-064, ya diseñado pero ausente del registro, antes de reservar IDs posteriores? Esta auditoría no lo modifica.
- ¿El fallback tras 403 de `loadHousehold` debe ofrecer selector de hogar, relogin o ambas opciones? Es una decisión de UX/producto, no se decide aquí.
- ¿Qué nivel de stale data se acepta en Home y listas: banner persistente, timestamp o solo feedback tras un gesto de refresh? Requiere decisión de producto antes de implementar TD-071/TD-072.

## 6. Plan de verificación para Claude

| Hallazgo | Verificación mínima | Pruebas/análisis a ejecutar tras implementar o al reproducir |
|-----------|---------------------|---------------------------------------------------------------|
| F0-01 | Fakes controlados que resuelven peticiones en orden inverso, con cambio de hogar, logout y evento Socket entre medias | `flutter analyze`; `bloc_test` por Cubit; widget test de `SessionListeners` + `MainScaffold`; prueba manual con dos hogares/dispositivos. |
| F0-02 | Forzar fallo de `HouseholdRepository.getById` desde splash y comprobar copy/CTA/ruta | `flutter analyze`; widget test de splash→shell y retry; prueba manual con red cortada y 403. |
| F0-03 | Montar Home con Task/Shopping en `initial`, `loading`, `error`, caché y datos stale | `flutter analyze`; widget tests de estados; prueba manual modo avión con caché vacía y con caché existente. |
| F0-04 | Barreras en adapters de tareas/compras para invertir refresh/página 2/mutación/Socket | `flutter analyze`; `bloc_test` de cursores, ids y total; pruebas de repositorio; prueba manual de scroll rápido + pull-to-refresh en dos dispositivos. |
| F0-05 | Resolver `last30days` después de `allTime` y viceversa | `flutter analyze`; `bloc_test` que verifica periodo y payload aceptado; widget test del selector. |
| F0-06 | Inyectar 5xx en refresh y página 2 con una lista preexistente | `flutter analyze`; widget tests de banner/error/retry y conservación de cursor/lista. |
| F0-07 | Lanzar dos `syncPending` contra la misma cola con fake API/Hive | `flutter analyze`; tests de repositorio con create→update→delete; comprobar `retryCount` y ausencia de dobles PATCH/DELETE no deseados. |
| F0-08 | Fake SocketService con cambio de sala y doble `connectAndListen` | `flutter analyze`; unit/widget tests de `SocketCubit`; prueba manual de cambio de hogar y eventos desde ambos hogares. |
| F0-09 | Golden/widget tests para cada combinación `initial/loading/error/stale/empty` de las superficies afectadas | `flutter analyze`; pruebas widget de Stats, Calendar, Perfil y Tienda; revisión manual de copy y accesibilidad. |

Antes de aceptar cualquiera de estos como bug o abrir su fix, ejecutar además la suite Flutter completa correspondiente. Esta Fase 0 no la ha ejecutado por alcance explícito.

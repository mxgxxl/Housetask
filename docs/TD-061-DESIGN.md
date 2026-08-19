# TD-061 — Diseño: el logout descarta la cola pendiente sin aviso

Plan para TD-061 (ver `docs/TECH_DEBT.md`), detectado durante el round TD-057/TD-060 como decisión C. Documento de diseño: no se ha tocado código, tests, CI ni TDs al escribirlo. Verificado contra el árbol en `cb70524`.

---

## 1. Inventario: qué se pierde exactamente

### El camino

`AuthCubit.logout()` (`auth_cubit.dart:108-119`) hace, en orden: `unregisterToken()` → `_repo.logout()` → **`_cache.clearAll()`** → emitir `unauthenticated`.

`CacheService.clearAll()` vacía las **cuatro** boxes de Hive:

| Box | Qué contiene | ¿Se pierde algo irrecuperable? |
|---|---|---|
| `pending_operations` | La cola de `PendingOperation` (create/update/delete de task/shopping) | **Sí.** Es la única copia: el servidor nunca vio estas escrituras |
| `tasks` | Tareas cacheadas, incluidas las de `isSynced:false` (escritura offline optimista) y las de `isDeleted:true` (borrado encolado) | **Sí**, las no sincronizadas. Las sincronizadas se repueblan del servidor |
| `shopping` | Ídem para artículos | **Sí**, las no sincronizadas |
| `households` | Hogares cacheados | No: no existe escritura offline de hogares, se repuebla |

Las entidades `isSynced:false` y la cola **son la misma escritura vista desde dos sitios**: la entidad es lo que el usuario ve en pantalla y la `PendingOperation` es lo que la reproducirá. Borrar ambas no deja ni rastro ni síntoma — la fila simplemente desaparece.

El estado en memoria de los Cubits también se limpia, pero eso lo hace `SessionListeners` (TD-058) y no añade pérdida: es un reflejo de lo anterior.

### Cuánto puede haber pendiente

**La cola no tiene tope.** No hay `MAX_PENDING` ni poda por tamaño en `CacheService` ni en los repositorios: cada mutación hecha sin conexión añade una `PendingOperation` y ahí se queda hasta que `syncPending()` la reproduzca. El único mecanismo que reduce la cola sin sincronizar es el descarte tras más de 3 reintentos fallidos por una causa **no** de red (ADR-010), que además reporta a Sentry.

En la práctica el tamaño es "cuántas cosas haya hecho el usuario desde que perdió la conexión", sin límite superior. Un viaje en metro con diez tareas completadas son diez operaciones.

**Pero el número exacto ya está disponible en tiempo de ejecución**, y esto es lo que hace barata la solución:

- `CacheService.pendingOperationsCountSync` — lectura síncrona, sin `await`.
- `CacheService.pendingOperationsCount` — stream en vivo.

De hecho **ya se muestra al usuario**: el badge del `OfflineBanner` pinta esa cifra. Así que un aviso con contador no necesita fontanería nueva, solo leer lo que ya se calcula.

### Hallazgo que cambia el alcance: solo afecta al logout explícito

`clearAll()` se llama desde **un único sitio en toda la app**: `AuthCubit.logout()`. Ni `login()`, ni `register()`, ni `onSessionExpired()` lo llaman.

`onSessionExpired()` (`auth_cubit.dart:104-106`) se limita a emitir `unauthenticated`. Consecuencias:

1. **Una expiración de sesión NO pierde la cola**: las boxes sobreviven en disco. El problema de TD-061 es exclusivo del botón "Cerrar sesión".
2. **Pero abre uno distinto, y no menor.** Si la sesión de A caduca y después inicia sesión B en el mismo dispositivo, nadie limpia el disco: la cola de A sigue ahí, y `syncPendingOperations` la reproducirá **con el token de B**. Las operaciones apuntan a hogares de los que B no es miembro, así que el servidor responderá 403/404 — no de red, luego consumen sus 3 reintentos y se descartan con reporte a Sentry. No hay fuga de datos a los hogares de B (el filtrado por `householdId` lo impide), pero sí escrituras de A intentadas bajo las credenciales de B, y ruido en Sentry.

Es exactamente lo que el comentario de `logout()` dice que no debe pasar — *"offline writes queued under this session must not silently replay onto whatever account signs in next"* — solo que esa protección vive únicamente en el camino del logout explícito.

**No se arregla en este round** (TD-061 es sobre el aviso, no sobre esto), pero merece entrada propia. Ver §6.

---

## 2. Diseño de la solución

### Opciones consideradas

| | Qué es | A favor | En contra |
|---|---|---|---|
| **A. Aviso simple** | Añadir "puede que pierdas cambios" al diálogo actual, siempre | Trivial | Se muestra también cuando no hay nada pendiente, así que se aprende a ignorar. Y sin número el usuario no puede juzgar si le importa |
| **B. Aviso con contador** | El diálogo cambia solo si la cola no está vacía, y dice cuántos cambios | Preciso, accionable, reutiliza `pendingOperationsCountSync` | Requiere dos variantes del diálogo |
| **C. Bloqueo total** | No dejar cerrar sesión con cola pendiente | Imposible perder datos | **Descartada.** Rompe la propiedad de seguridad: un dispositivo compartido o perdido debe poder limpiarse SIEMPRE. Y atrapa al usuario justo cuando está offline y no puede vaciar la cola |
| **D. Confirmación con detalle** | Listar las operaciones pendientes | Máxima información | Los payloads son internos (`{'status':'completed'}`); traducirlos a lenguaje humano es una feature, no un aviso |
| **E. Sincronizar antes de salir** | Si hay conexión, intentar `syncPending()` y luego cerrar | Convierte la pérdida en no-pérdida | No sirve offline, que es justo cuando hay cola |

### Elección: **B + E**, con C descartada explícitamente

El flujo depende de dos cosas que la app ya sabe: cuántas operaciones hay pendientes y si hay conexión (`ConnectivityService.checkConnectivity()`).

```
cola vacía            → diálogo actual, sin cambios
cola > 0 y ONLINE     → intentar sincronizar primero; si drena a 0, cerrar sesión normal;
                        si queda algo, caer al aviso con el número restante
cola > 0 y OFFLINE    → aviso con contador y confirmación explícita de descarte
```

**Por qué B y no A:** un aviso que aparece siempre es un aviso que nadie lee. Mostrarlo solo cuando hay algo que perder es lo que le da peso, y el número es lo que permite decidir — "1 cambio" y "14 cambios" son decisiones distintas.

**Por qué E encima de B:** el mejor aviso es el que no hace falta. Si hay conexión, la cola puede vaciarse en el tiempo que el usuario tarda en leer el diálogo, y entonces no hay nada que advertir. Es además lo que ya sugería la solución propuesta en la entrada de TD-061.

**Por qué C se descarta sin matices:** bloquear el logout convierte un problema de datos en un problema de seguridad. El caso que motiva limpiar el dispositivo —lo he perdido, lo comparto, se lo doy a alguien— es precisamente aquel en el que no puedo permitirme fallar. Y como la cola solo se vacía con conexión, bloquear dejaría a un usuario sin cobertura sin forma de cerrar sesión.

### Lo que NO cambia

**`clearAll()` sigue borrándolo todo.** La solución es avisar, no dejar de limpiar. Conservar la cola entre sesiones reintroduciría exactamente el riesgo que describe §1: escrituras de una cuenta reproducidas bajo otra.

---

## 3. UX

### Dónde

**En el `AlertDialog` que ya existe**, no en un bottom sheet ni un snackbar.

- Un snackbar es descartable y asíncrono; una confirmación de pérdida de datos tiene que ser modal y bloquear hasta que el usuario decida.
- El diálogo ya existe (`profile_page.dart:219`) y el fichero ya usa `AlertDialog` para el resto de confirmaciones (`_editName`). Introducir un bottom sheet aquí sería inconsistente por gusto.

### Las tres variantes

**1. Sin nada pendiente** — el diálogo actual, intacto:

> **Cerrar sesión**
> ¿Seguro que quieres cerrar sesión?
> `Cancelar` · `Cerrar sesión`

**2. Con cola y conexión** — estado transitorio mientras drena:

> **Cerrar sesión**
> Sincronizando 3 cambios pendientes…
> `Cancelar` · `Cerrar sesión` *(deshabilitado)*

Si termina en 0, pasa a la variante 1. Si queda algo (falla el servidor, se cae la red a mitad), pasa a la 3 con el número restante.

**3. Con cola y sin conexión (o sincronización incompleta)**:

> **Cerrar sesión**
> Tienes **3 cambios sin sincronizar**. Si cierras sesión ahora, se perderán.
> `Cancelar` · `Cerrar sesión y descartar`

### Los botones

- **`Cancelar`** es la acción por defecto y segura. Cierra el diálogo y no hace nada más.
- **`Cerrar sesión y descartar`** nombra la consecuencia en vez de esconderla, igual que el mensaje de borrado rechazado de TD-007 nombra la tarea. Mantiene el estilo destructivo (`AppColors.error`) que ya tiene el botón actual.

### El contador

Se lee una sola vez al abrir el diálogo con `pendingOperationsCountSync`, no del stream. Un número que cambia mientras se lee la frase es peor que uno estable: el usuario decide sobre lo que ve. La excepción es la variante 2, donde el número **debe** bajar porque eso es lo que está comunicando.

Pluralización explícita: "1 cambio sin sincronizar" / "N cambios sin sincronizar".

---

## 4. Casos borde

### 4.1 Cola pendiente + offline

El caso central, y el que no tiene salida buena: no se puede sincronizar, así que la única opción real es descartar o quedarse. La variante 3 lo dice sin rodeos y exige un toque deliberado en un botón que nombra el descarte.

No se ofrece "cerrar sesión y conservar para más tarde": conservar la cola es justo lo que §1 explica que no debe hacerse.

### 4.2 Logout cancelado: ¿se reanuda la sincronización?

**No se reanuda porque nunca se detuvo.** Si la variante 2 lanzó `syncPending()` y el usuario pulsa `Cancelar`, la sincronización **sigue en curso**: es beneficiosa, ya está en vuelo y abortarla no aportaría nada. `TaskCubit.syncPending()` no acepta cancelación y no hay motivo para dárselo.

Consecuencia deseable: cancelar el logout deja al usuario con la cola drenándose, que es exactamente lo que querría.

Requisito de implementación: el `Future` de la sincronización **no puede estar atado al ciclo de vida del diálogo**. Si se lanza desde el `builder`, hay que asegurarse de que cerrar el diálogo no descarte el resultado ni provoque un `setState` sobre un widget desmontado.

### 4.3 Logout forzado por expiración de token

**No hay diálogo, y no hace falta**: como establece §1, `onSessionExpired()` no llama a `clearAll()`, así que la cola **sobrevive**. Cuando el usuario vuelva a entrar con la misma cuenta, sus cambios siguen ahí y se sincronizarán.

No se debe intentar mostrar un aviso en este camino: no hay interacción del usuario que confirmar, la sesión ya está muerta y `SessionListeners` navega a login desde donde sea que estuviera.

Lo que sí queda pendiente es el reverso —que la cola de A sobreviva a un login de B— y eso es §6.

### 4.4 Logout mientras una sincronización automática ya está en curso

`syncPending()` se dispara solo en la transición offline→online (`task_cubit.dart:377`). Si el usuario abre el logout justo entonces, la variante 2 podría lanzar una segunda sincronización concurrente.

`syncPendingOperations` es idempotente por diseño —cada create lleva su `Idempotency-Key` y el backend devuelve el recurso original con HTTP 200 (Hard Rule 13)— así que solaparlas no corrompe nada. Pero produce peticiones de más. Propuesta: si `state.isSyncing` ya es `true`, la variante 2 **observa** en vez de lanzar otra.

### 4.5 La cola es de otro usuario

Si por el camino de §1 la cola pertenece a una sesión anterior, el contador la incluiría y el aviso diría "tienes N cambios" sobre cambios que no son suyos. Es un síntoma del problema de §6, no de este diseño, y desaparece cuando aquel se arregle.

---

## 5. Tests y plan de commits

### Tests

| Test | Verifica |
|---|---|
| `sin cola, el diálogo es el de siempre` | Ninguna variante nueva aparece cuando no hay nada que perder |
| `con cola y offline, el diálogo dice el número exacto` | 1 → "1 cambio", 3 → "3 cambios" |
| `el botón destructivo nombra el descarte` | El texto, no solo la acción |
| `cancelar no cierra sesión ni toca la caché` | `logout()` no se llama y la cola sigue intacta |
| `confirmar cierra sesión y vacía la cola` | Comportamiento actual preservado |
| `con cola y online, se intenta sincronizar antes` | `syncPending()` invocado; con la compuerta abierta el botón está deshabilitado |
| `si la sincronización drena la cola, se cierra sesión sin advertir` | El mejor aviso es el que no hace falta |
| `si la sincronización deja restos, se advierte con el número restante` | No con el inicial |
| `cancelar no aborta una sincronización en vuelo` | §4.2 — el Future sobrevive al diálogo |
| `no se lanza una segunda sincronización si ya hay una` | §4.4, leyendo `isSyncing` |
| `la expiración de sesión no muestra diálogo ni vacía la cola` | §4.3, fija la asimetría a propósito |

Estimación: **~11 tests**, la mayoría de widget sobre `profile_page` con cubits falsos, más uno de `AuthCubit` para el último.

### Plan de commits

| # | Título | Alcance | Riesgo | Parada |
|---|---|---|---|---|
| 1 | `refactor(ui): extraer el diálogo de logout a su propio widget` | Sacar `_logout` de `profile_page` a un widget testeable, sin cambiar comportamiento | Bajo | |
| 2 | `feat(ui): avisar del descarte de la cola pendiente al cerrar sesión` | Variantes 1 y 3 (contador y confirmación explícita), sin el intento de sincronización | Medio | **Sí** — cierra el núcleo de TD-061 y es desplegable solo |
| 3 | `feat(ui): sincronizar antes de cerrar sesión cuando hay conexión` | Variante 2, con §4.2 y §4.4 | Medio | |
| 4 | `docs: cerrar TD-061` | TECH_DEBT, tabla corta, y abrir el TD de §6 | Ninguno | |

**La parada tras el commit 2 es la que importa**: ahí el usuario ya no pierde datos sin enterarse, que es el problema que TD-061 describe. El commit 3 es una mejora sobre eso — evita la pérdida en vez de solo advertirla — y puede aplazarse sin dejar nada a medias.

---

## 6. Riesgos, rollback y pruebas manuales

### Riesgos

| Riesgo | Detección |
|---|---|
| **El contador miente** porque incluye operaciones de otra sesión (§4.5) | Es el problema de abajo, no de este diseño. Se detecta con la prueba manual 5 |
| **Un aviso más que ignorar**: si aparece demasiado, se aprende a confirmar sin leer | Por eso solo aparece con cola no vacía. Si en uso real resulta frecuente, la señal es que la sincronización falla, no que sobre el aviso |
| **La sincronización del commit 3 tarda** y el usuario cree que la app se ha colgado | Botón deshabilitado con texto explícito, no un spinner mudo. Conviene un tope: pasados unos segundos, caer a la variante 3 |
| **Regresión en el camino de expiración**: tocar `logout()` y romper `onSessionExpired()` | El test de §5 que fija la asimetría |

### El otro problema, que este round no arregla

**`clearAll()` se llama desde un único sitio: el logout explícito.** Ni `login()` ni `register()` limpian. Así que tras una expiración de sesión de A, un login de B hereda en disco la caché y la cola de A, que se reproducirán con el token de B (§1).

Merece **entrada propia**, y probablemente prioridad mayor que TD-061: aquí no se pierde trabajo del usuario, se ejecutan escrituras de una cuenta bajo las credenciales de otra. El arreglo parece pequeño —limpiar también al autenticar, o al detectar que el `userId` que entra difiere del último— pero la decisión de cuál de las dos es un cambio de comportamiento que conviene razonar aparte.

### Rollback

Cada commit es revertible por separado y ninguno cambia datos persistidos: todo es UI y orden de llamadas. No hay migración ni formato que deshacer.

### Pruebas manuales en dispositivo

1. **Sin cola:** cerrar sesión con todo sincronizado. El diálogo debe ser el de siempre, sin números.
2. **Con cola y sin conexión:** modo avión → completar 3 tareas → cerrar sesión. Debe decir **"3 cambios sin sincronizar"** y el botón nombrar el descarte. Confirmar y comprobar que efectivamente se pierden (es el comportamiento correcto, ahora advertido).
3. **Cancelar:** mismo guion, pulsar `Cancelar`. Volver a Perfil y comprobar que el badge del banner sigue mostrando 3 — no se ha tocado nada.
4. **Con conexión (commit 3):** modo avión → 2 cambios → recuperar conexión → cerrar sesión inmediatamente. Debería sincronizar y cerrar sin advertir; si aparece el aviso, el número debe ser el que realmente quedó.
5. **Expiración de sesión:** forzar la caducidad (esperar, o invalidar el refresh token desde el servidor) con cola pendiente. Al volver a entrar **con la misma cuenta**, los cambios deben seguir ahí y sincronizarse — verifica §4.3.
6. **Dos cuentas (el problema de §6):** dejar cola pendiente con la cuenta A, forzar expiración, entrar con B. Observar en Sentry si aparecen operaciones descartadas tras 3 reintentos. Esta prueba no valida TD-061; documenta el otro problema con evidencia.

---

## Decisiones aprobadas

Aprobadas por el dueño el 2026-08-19, antes de empezar la implementación.

### A. El problema cross-account se registra como TD-062, con prioridad alta

El hallazgo del §1/§6 —que `clearAll()` solo se llama en el logout explícito, así que la cola de A sobrevive a una expiración y se reproduce con el token de B— **no se arregla aquí**. Se registra como **TD-062**, Open, prioridad **High**, con la evidencia de este documento, y su diseño se hará en un round aparte **después** de cerrar TD-061.

Es coherente con el orden en que aparecieron: TD-061 es sobre avisar de una pérdida que el usuario provoca a sabiendas; TD-062 es sobre escrituras de una cuenta ejecutadas bajo las credenciales de otra. Se separan porque son problemas distintos con arreglos distintos, no porque uno sea menos urgente — de hecho TD-062 lleva prioridad más alta.

### B. El commit 3 entra en este round

La sincronización previa al logout (variante 2 de §3) se implementa en este mismo round, **después** de la parada del commit 2. La parada se mantiene: el commit 2 cierra el núcleo de TD-061 y es desplegable solo, y el 3 se aborda con esa base ya validada.

### C. Tope de 5 segundos para la sincronización previa

El intento de sincronizar antes de cerrar sesión tiene un límite de **5 s**. Pasado ese tiempo, se cae a la variante de aviso con el número de operaciones que queden.

Matiz que evita el error obvio: **sin conexión el intento no debe consumir el tope**. `ConnectivityService.checkConnectivity()` se consulta primero, y si está offline se va directo al aviso — hacer esperar 5 segundos a quien ya sabemos que no puede sincronizar sería castigar precisamente el caso más común.

### D. Textos en español aprobados

Se usan tal como los propone §3, sin cambios:

- *"Sincronizando N cambios pendientes…"*
- *"Tienes **N cambios sin sincronizar**. Si cierras sesión ahora, se perderán."*
- Botones: *"Cancelar"* y *"Cerrar sesión y descartar"*.
- Pluralización explícita: *"1 cambio"* / *"N cambios"*.

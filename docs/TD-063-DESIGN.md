# TD-063 — Diseño: un fallo de red durante el refresh se trata como sesión muerta

> Estado: **propuesta**, pendiente de aprobación. No hay código escrito.
> Detectado al diseñar TD-062 (ver `docs/TD-062-DESIGN.md` §1, "Un hallazgo colateral que agrava el escenario").

---

## 1. Root cause exacto

### El código

`ApiService._refreshToken()` (`frontend/lib/data/datasources/remote/api_service.dart:82`) termina así:

```dart
} catch (_) {
  completer.complete(null);
  return null;
}
```

Y el interceptor decide con eso (`:61`):

```dart
if (e.response?.statusCode == 401 && !isRefreshCall && !alreadyRetried) {
  final newToken = await _refreshToken();
  if (newToken != null) {
    /* reintentar con el token nuevo */
  } else {
    // Refresh failed → session is dead.
    await _local.clear();
    onSessionExpired?.call();
  }
}
```

**El problema no es el `catch` genérico por sí solo: es que el tipo de retorno tiene dos valores para tres desenlaces.** `String?` solo puede decir "hay token nuevo" o "no lo hay". Los tres desenlaces reales son:

| Desenlace | Qué significa | Qué debería pasar | Qué pasa hoy |
|---|---|---|---|
| **Rotado** | El servidor emitió un par nuevo | Reintentar la petición | Correcto |
| **Rechazado** | El servidor dijo 401: el refresh token ya no vale | Sesión muerta, al login | Correcto |
| **Inalcanzable** | No hubo respuesta: sin red, DNS, timeout, 5xx, 429 | **Conservar la sesión**; la petición falla como offline | **Se trata como rechazado** |

El tercero se colapsa contra el segundo, y por eso `catch (_)` es el síntoma y no la causa. Cualquier arreglo que no le dé un nombre al tercer desenlace lo volverá a colapsar la próxima vez que alguien toque esta función.

### La secuencia que rompe

1. El access token caduca (15 min, ADR-004).
2. El usuario hace cualquier cosa → el servidor responde **401 real**.
3. El interceptor pide un refresh. En ese instante el dispositivo pierde la red (ascensor, metro, salto WiFi↔móvil, backend desplegando).
4. `_refreshToken()` traga la excepción y devuelve `null`.
5. El interceptor limpia SharedPreferences y dispara `onSessionExpired()`.
6. `SessionListeners` desconecta el socket, resetea los cinco cubits de dominio y navega al login (TD-055/TD-058).

Hace falta un 401 **real** seguido de un fallo de red: no basta con estar offline. Estando offline del todo, la petición no llega a recibir un 401 y muere antes como `NetworkFailure`. La ventana peligrosa es concreta: **cobertura suficiente para recibir el 401, insuficiente para completar el refresh.** Es exactamente el perfil de una conexión móvil mala, que es el escenario que motivó TD-003.

### La segunda mitad del daño, que no está en la ficha del TD

El registro describe la expulsión al login. Hay un segundo efecto, del mismo bug y peor:

`handler.next(e)` propaga el **401 original**. `_mapDioError` lo convierte en `AuthFailure(status: 401)`, y `isOfflineWorthy()` devuelve `false` para un 401 — correctamente, porque un 401 es una respuesta real del servidor. Resultado: la escritura que el usuario acababa de hacer **no se encola**; el repositorio la relanza y el cubit optimista la revierte.

O sea que hoy una desconexión pasajera en el momento justo produce **dos** pérdidas: la sesión y la escritura en vuelo. La segunda es más grave, porque TD-062 ya garantiza que la cola sobrevive a la expulsión — pero solo si la escritura llegó a entrar en la cola, y esta no llega.

### Lo que el repo ya sabe hacer, y esta función ignora

`_mapDioError` (`:157`), en el mismo archivo, ya tiene la distinción exacta que falta:

```dart
// No response at all — offline, DNS failure, or a timeout before one
// arrived — is what makes a cache-first repository fall back / queue.
if (e.response == null) {
  return NetworkFailure(message);
}
```

Y `isOfflineWorthy()` (`core/errors/failures.dart:47`) la formaliza: sin respuesta, o 5xx, es "no se pudo preguntar"; un 4xx es "el servidor contestó que no". **La regla ya existe, está documentada y se aplica en toda la app menos en el único sitio donde su ausencia cierra la sesión.** El arreglo es sobre todo aplicar la regla de la casa donde falta, no inventar una nueva.

---

## 2. Opciones y trade-offs

### (a) Distinguir por código HTTP

En `_refreshToken`, capturar `DioException` y mirar `e.response?.statusCode`: 401 (y 403) → sesión muerta; el resto → red.

- **A favor:** mínima, sin tráfico nuevo, sin riesgos de concurrencia. Reutiliza la regla de `_mapDioError`.
- **En contra:** la decisión se sigue transmitiendo por un `String?`, así que el call site tiene que re-derivar el motivo o recibirlo por un canal aparte. Es el arreglo correcto expresado en la estructura que causó el bug.
- **Detalle que la versión ingenua se salta:** el portal cautivo. Un WiFi de hotel devuelve `200` con HTML; no hay excepción, `res.data?['data']` es `null`, y el código actual —y una (a) que solo mire excepciones— lo lee como "el servidor no me dio tokens" → sesión muerta. Un 200 con cuerpo no parseable es **inalcanzable**, no rechazado.

### (b) Reintentar el refresh con backoff antes de declarar la sesión muerta

- **A favor:** recupera el caso de microcorte real sin que el usuario note nada.
- **En contra, y es decisivo: el refresh no es idempotente por diseño.** El backend rota con `findOneAndDelete` — *"the delete IS the claim"* (`auth.service.ts:184`). Si la primera llamada **llegó** al servidor y se perdió la respuesta, el token que el cliente conserva ya no tiene fila. El reintento cae entonces en la rama de replay:
  - `logger.warn('refresh-token replay detected')` + `captureSecurityWarning(...)`, que es **el canal de alerta que CLAUDE.md documenta para robo de refresh tokens**. Los reintentos fabricarían falsos positivos justo ahí.
  - `revokeAllUserTokens(userId, requestStartedAt)` revoca la familia previa a ese instante, incluido el par que el cliente nunca recibió.
  
  Es decir: en el subcaso que un reintento pretende rescatar, el reintento **no puede rescatar nada** (el token nuevo se perdió y es irrecuperable) y además ensucia el canal de seguridad y consuma la revocación. No se puede reintentar con seguridad una llamada no idempotente cuya respuesta no viste.
- **En contra, secundario:** el single-flight. `_refreshCompleter` coalesce todas las 401 concurrentes; un backoff de varios segundos deja esperando a todas, no solo a la primera.
- **En contra, secundario:** presupuesto de rate limit. `/api/auth/refresh` **sí** cuenta contra el limitador global (100 req/15 min/IP): `OWN_LIMITER_PREFIXES` solo exime `/register` y `/login`. Bajo CGNAT de operador móvil ese presupuesto es compartido entre usuarios reales.
- **Y sobre todo: el reintento ya existe y es gratis.** La app es locuaz —reconexión de socket, refresco de listas, sync al recuperar conectividad—, así que la siguiente petición genera un 401 nuevo y un refresh nuevo, esta vez con red. Un reintento explícito duplica un mecanismo que ya funciona, y lo duplica en el único punto donde equivocarse revoca la familia de tokens.

### (c) Combinar (a) + (b)

Hereda el problema de (b) entero. Se podría acotar a los fallos en los que la petición **demostrablemente no salió** (`connectionError`, `connectionTimeout`) y nunca a `receiveTimeout` (que significa que sí salió). Es defendible, pero Dio no distingue esos tipos con garantía suficiente como para apostar una revocación de familia, y el beneficio marginal sobre (a) sigue siendo el que ya cubre el reintento orgánico.

### (d) Exponer el tipo de fallo al interceptor y que decida por tipo

`_refreshToken` deja de devolver `String?` y devuelve un desenlace con tres valores (rotado / rechazado / inalcanzable). El interceptor decide sobre el desenlace, no sobre un `null`.

- **A favor:** nombra el tercer estado, que es literalmente el root cause. Encaja con el estilo de la casa (`Failure` + `isOfflineWorthy` ya modelan esta misma distinción como tipos). Hace que el bug sea difícil de reintroducir: añadir un caso nuevo obliga a decidir de qué lado cae.
- **En contra:** un tipo más. Trivial frente a lo que resuelve.

### Recomendación: **(d) como forma, (a) como regla**

`_refreshToken` devuelve un desenlace de tres estados; el criterio para clasificarlo es el código HTTP. **Sin reintento** (se descartan (b) y (c)), con el motivo documentado en el propio código: *no se reintenta una rotación cuya respuesta no se vio, porque el backend la interpreta como replay*.

Regla de clasificación propuesta:

| Situación | Desenlace |
|---|---|
| 2xx con `accessToken` y `refreshToken` en el cuerpo | **Rotado** |
| **401** de nuestra API | **Rechazado** |
| No hay refresh token guardado | **Rechazado** (no hay nada que refrescar) |
| Sin respuesta (offline, DNS, timeout) | Inalcanzable |
| 5xx (mantenimiento, deploy) | Inalcanzable |
| 429 (rate limit) | Inalcanzable |
| 403 | Inalcanzable — **ver nota** |
| 2xx sin tokens en el cuerpo (portal cautivo) | Inalcanzable |

**Nota sobre el 403, que se aparta del enunciado de la opción (a):** el backend **nunca** responde 403 en `/auth/refresh` — todas sus salidas de error son `AppError(..., 401)`. Un 403 en esa ruta viene por tanto de infraestructura (proxy, WAF, portal cautivo), no de nuestro servidor, y tratarlo como sesión muerta reintroduce el bug por otra puerta. Es una decisión que conviene aprobar explícitamente: **solo el 401 mata la sesión.**

### La segunda mitad del arreglo

Clasificar bien no basta: falta qué le pasa a **la petición original** cuando el desenlace es inalcanzable. Hoy propaga el 401 → `AuthFailure` → no encolable → escritura perdida (§1).

Propuesta: en el desenlace inalcanzable, rechazar con una `DioException` sin respuesta (`type: connectionError`) en lugar de propagar el 401. `_mapDioError` la convierte en `NetworkFailure`, `isOfflineWorthy` devuelve `true`, y el repositorio hace lo que hace siempre sin red: encolar la escritura o caer a la caché.

Es una **reinterpretación** y conviene decirlo claro: el 401 era una respuesta real del servidor. Pero el desenlace de la operación *que el usuario pidió* es genuinamente desconocido — nunca se llegó a intentar con un token válido. "No pude preguntar" describe eso mejor que "rechazado", y es lo que hace que la escritura sobreviva en la cola en vez de revertirse.

---

## 3. Interacción con TD-062 y TD-061

Los tres TDs son el mismo tema visto desde tres sitios: **qué se conserva cuando una sesión se interrumpe, y quién decidió que se interrumpiera.**

### Con TD-062 (marcador de propietario de la caché)

TD-062 hizo que la cola sobreviva a una expiración y que sea **quien se autentica después** quien decida su destino: el mismo usuario la recupera entera, otro la encuentra vacía.

Esa ganancia depende de una premisa que TD-063 rompe: que una expiración signifique algo. Hoy la cola sobrevive a la desconexión —bien—, pero el usuario aparece en el login sin motivo, y solo la recupera si vuelve a entrar. Con TD-063 arreglado, no llega a haber expulsión: la sesión sigue viva, la app sigue leyendo de caché y encolando, y la cola ni siquiera necesita ser rescatada.

Dicho al revés: **TD-062 hizo la expulsión no destructiva; TD-063 hace que la expulsión no ocurra.** Ninguno sustituye al otro, y el orden en que se hicieron fue el correcto — si se hubiera arreglado antes el refresh, el escenario de cambio de cuenta habría quedado igual de roto pero más difícil de reproducir.

TD-062 **no se toca**: `_adoptCache` cuelga de la autenticación, y este round no añade ni quita entradas a sesión autenticada. La única interacción a verificar por test es que un refresh inalcanzable no dispare nada del camino de TD-062 (no hay `emit(authenticated)`, luego no hay adopción, luego el marcador no cambia).

### Con TD-061 (aviso al cerrar sesión con cola pendiente)

TD-061 fijó la asimetría de producto, y este TD es el que la hacía mentir:

- **Logout explícito → la cola se descarta.** Hubo alguien decidiendo, con el recuento delante.
- **Expiración → la cola se conserva.** No decidió nadie.

Un refresh mal clasificado convierte una desconexión en una expiración. Como la expiración conserva la cola, el daño de TD-061 no se materializa — pero la promesa que TD-061 le hace al usuario ("lo tuyo solo se pierde si tú lo decides") se apoya en que el sistema sepa distinguir un evento de una decisión. **TD-063 es el mismo principio un nivel más abajo: distinguir "el servidor dijo que no" de "no pude preguntar".**

Hay además un efecto práctico directo sobre TD-061: expulsado al login, el usuario que vuelve a entrar y luego cierra sesión ve el diálogo de TD-061 avisando de N cambios pendientes que **no sabía que existían**, porque los hizo antes de una expulsión que no entendió. Menos expulsiones espurias es también menos diálogos desconcertantes.

---

## 4. Casos borde

### 4.1 Cambio de red WiFi ↔ móvil durante el refresh

El caso más frecuente. La petición muere con `connectionError` o timeout, sin respuesta.

**Con el fix:** inalcanzable → sesión conservada, la petición original se encola/cae a caché, y la siguiente petición (el propio handoff suele disparar el listener de conectividad y un sync) reintenta el refresh con red buena. El usuario no ve nada.

### 4.2 Backend en mantenimiento o desplegando (5xx)

Railway despliega en cada push a `main`, así que hay ventanas de indisponibilidad reales y frecuentes.

**Hoy:** todo usuario cuyo access token caduque dentro de esa ventana acaba en el login. **Con el fix:** inalcanzable → sesión conservada, la app funciona desde caché hasta que el backend vuelve. Este caso por sí solo justifica el round: es el único en que el bug afecta a *todos* los usuarios a la vez y de forma correlacionada.

Efecto secundario a favor: hoy un 5xx en `/auth/refresh` es **invisible** en Sentry, porque la llamada usa `_refreshDio` (sin interceptores) y su excepción se traga. Ver §6 sobre el breadcrumb.

### 4.3 Refresh token realmente revocado

Vías reales: rotación con replay detectado (`revokeAllUserTokens`), token caducado a los 7 días, o `logout` desde ese mismo dispositivo.

El backend responde **401**. **Con el fix:** rechazado → exactamente el comportamiento de hoy — `_local.clear()`, `onSessionExpired()`, `SessionListeners` al login — y la caché intacta para que TD-062 decida al reautenticar. **Este camino no debe cambiar en absoluto**, y es lo que hay que blindar con test: el riesgo de este round es aflojarlo sin querer.

### 4.4 Modo avión entrando y saliendo

- **Entrando (avión ON con el token caducado):** si la app estaba en primer plano, la petición en curso muere sin respuesta → inalcanzable → sesión conservada. Si el avión ya estaba activo antes de la petición, ni siquiera se llega al 401: la petición muere como `NetworkFailure` y el interceptor de 401 no entra. El bug no aparece.
- **Saliendo (avión OFF):** el listener de conectividad dispara `syncPendingOperations`. La primera petición recibe 401, el refresh ahora sí va bien, y todo se reanuda. Con el fix, además, la cola que se encoló durante el vuelo sigue ahí porque nunca hubo expulsión.

### 4.5 Portal cautivo

WiFi de hotel/aeropuerto: hay interfaz de red (`connectivity_plus` dice "online"), pero el tráfico se intercepta. La respuesta al refresh es un 200 con HTML, o un 302/403.

Es el caso que rompe la versión ingenua de (a), porque no hay excepción que capturar. Se resuelve clasificando "2xx sin tokens en el cuerpo" como inalcanzable (§2).

### 4.6 Refresh inalcanzable repetido, indefinidamente

Sin red durante horas, cada ráfaga de peticiones intenta un refresh y falla. La sesión nunca muere.

**Es el comportamiento deseado:** una sesión solo está muerta cuando el servidor lo dice. El coste es una llamada fallida por ráfaga (el single-flight coalesce dentro de cada una). Si se midiera que molesta, cabría un cooldown de N segundos tras un desenlace inalcanzable; **se deja fuera de este round** por no añadir estado que puede quedar obsoleto para resolver algo que aún no se ha observado.

### 4.7 Dos peticiones concurrentes con el token caducado

`_refreshCompleter` ya coalesce. Con el fix, ambas reciben el mismo desenlace inalcanzable y ambas se encolan. Importa que el `finally` siga limpiando el completer —ya lo hace— para que la siguiente ráfaga pueda intentarlo de nuevo.

### 4.8 El acceso caduca estando offline y sigue caducado

No hay 401 (no hay respuesta), así que este camino no entra. La app lee de caché y encola, que es ADR-010 funcionando. Con el fix nada cambia aquí; se menciona porque es el caso que la gente confunde con el del TD.

---

## 5. Tests y plan de commits

### Tests

Todos de frontend, contra `ApiService` con un `HttpClientAdapter` falso — el mismo patrón que `test/idempotency_key_test.dart` y `test/session_expiry_cache_test.dart`, que ya inyectan `dio` y `refreshDio`. **No hay cambios de backend, luego no hay tests de backend.**

| # | Test | Verifica |
|---|---|---|
| 1 | Refresh responde **401** → sesión limpiada y `onSessionExpired` disparado | §4.3 — el camino que NO debe cambiar |
| 2 | Refresh falla por **red** (sin respuesta) → sesión **intacta**, `onSessionExpired` **no** disparado | El TD |
| 3 | Refresh falla por red → la petición original sale como `NetworkFailure` (encolable) | La segunda mitad del daño (§1) |
| 4 | Refresh responde **500** → inalcanzable, sesión intacta | §4.2 |
| 5 | Refresh responde **429** → inalcanzable, sesión intacta | Presupuesto de rate limit |
| 6 | Refresh responde **200 sin tokens** → inalcanzable, sesión intacta | §4.5, portal cautivo |
| 7 | **No hay refresh token guardado** → rechazado, sesión limpiada | No hay nada que refrescar |
| 8 | Refresh **correcto** → reintento con el token nuevo, respuesta devuelta | Regresión del camino feliz |
| 9 | **Dos 401 concurrentes** → una sola llamada de refresh; tras un desenlace inalcanzable, una petición posterior puede volver a intentarlo | §4.7, single-flight |
| 10 | Tras un refresh inalcanzable, el marcador de TD-062 **no cambia** y la cola sigue entera | Interacción con TD-062 (§3) |

Los pares **1 vs 2** y **1 vs 4** son el corazón: mismo `_onError`, misma petición original, desenlaces opuestos. Si alguno de los dos se pudiera borrar sin que fallara ningún test, el round no habría arreglado nada.

Estimación: **~10 tests**, en un archivo nuevo `test/refresh_outcome_test.dart`. Los de §4.3 y el camino feliz podrían vivir en `session_expiry_cache_test.dart`, que ya monta esa fontanería; se propone archivo nuevo porque lo que se prueba aquí es la clasificación, no la caché.

### Plan de commits

| # | Título | Alcance | Riesgo | Parada |
|---|---|---|---|---|
| 1 | `refactor(api): nombrar los tres desenlaces del refresh` | Tipo de desenlace + `_refreshToken` devolviéndolo. El call site lo traduce al comportamiento actual: **sin cambio de conducta**, tests existentes en verde sin tocarlos | Bajo | |
| 2 | `fix(api): no matar la sesión cuando el refresh no llegó a preguntar` | El interceptor solo limpia sesión en el desenlace rechazado. Tests 1–2, 4–9. **Cierra el TD tal como está descrito** | **Alto** — toca el camino por el que pasa toda petición autenticada | **Sí** |
| 3 | `fix(api): encolar la escritura cuando el refresh no llegó a preguntar` | Rechazar con `connectionError` en vez de propagar el 401 → `NetworkFailure` → encolable. Tests 3 y 10 | Medio — cambia el `Failure` que ven los repositorios | **Sí** |
| 4 | `docs: cerrar TD-063` | TECH_DEBT, tabla corta de CLAUDE.md, ROADMAP, NEXT_SESSION_MAC | Ninguno | |

El commit 1 no es andamiaje suelto: su consumidor —el call site— entra en el mismo commit, según la lección de IMPROVEMENTS del 2026-08-18 (`unused_element` es warning y `flutter analyze` corre con `--fatal-warnings`, así que un commit de solo andamiaje deja CI en rojo).

**Parada tras el commit 2** porque es donde el comportamiento cambia, y los dos modos de fallo son opuestos y ambos silenciosos: no expulsar cuando se debía (sesión zombi) y seguir expulsando (no se arregló nada). **Parada tras el commit 3** porque cambia lo que el usuario ve al fallar una escritura: hoy un error, después una fila encolada. Es la conducta correcta y es un cambio de UX que merece verse en dispositivo antes de dar el round por cerrado.

---

## 6. Riesgos, rollback y pruebas manuales

### Riesgos

| Riesgo | Detección |
|---|---|
| **Sesión zombi**: una sesión realmente muerta que nunca devuelve 401 (un backend que respondiera 5xx ante un token inválido) deja al usuario en un limbo, leyendo caché y encolando escrituras que serán rechazadas | Test 1 fija el 401. En producción se resuelve solo en cuanto llega un 401 de verdad. Riesgo aceptado: depende de que el backend responda 401 a un token inválido, que es lo que hace y lo que sus tests fijan |
| **No se arregló nada**: la clasificación deja fuera algún tipo de fallo de Dio y ese camino sigue matando la sesión | Tests 2, 4, 5, 6 cubren los cuatro tipos observados. La clasificación es por lista blanca —solo el 401 mata— así que un tipo no contemplado cae del lado seguro por construcción |
| **Aflojar la expiración real** (§4.3): el mayor riesgo del round, porque su síntoma es la ausencia de un síntoma | Test 1, y prueba manual 3 |
| **El commit 3 enmascara errores reales**: convertir el 401 original en `NetworkFailure` podría encolar una escritura que el servidor habría rechazado | No: el rechazo por 401 se refiere al *token*, no al contenido. Al sincronizarse la cola con un token válido, el servidor vuelve a juzgar la operación y un 4xx real la descarta por la vía normal (ADR-010, 3 reintentos) |
| **Falsos "replay detected"** si alguien reintroduce un reintento | Ninguno automático. Queda escrito en §2 y debería quedar como comentario en el código, junto al desenlace inalcanzable |

### Observabilidad (adición propuesta, aprobable aparte)

Hoy un fallo de refresh es **invisible**: `_refreshDio` no tiene interceptores y la excepción se traga. Propuesta: un **breadcrumb** de Sentry (no una captura) en el desenlace inalcanzable, categoría `auth`, como los que ya existen para login y completar tarea. Así, cuando algo se reporte después, la línea temporal dice si hubo un refresh fallido antes.

Breadcrumb y no `captureException` a propósito: sin red esto se dispara por cada ráfaga, y una captura por ráfaga es ruido garantizado. Con breadcrumb, el volumen es cero salvo que además ocurra un error de verdad.

### Rollback

Los tres commits de código son revertibles por separado y ninguno cambia formato de datos, esquema ni contrato de API. Revertir el 3 devuelve el comportamiento de error de las escrituras; revertir el 2 devuelve la conducta actual completa; el 1 es inerte por sí solo. **No hay cambio de backend, luego no hay orden de despliegue** (la restricción de "Deployment order" de CLAUDE.md no aplica a este round).

### Pruebas manuales del dueño en dispositivo

Todas necesitan **provocar la caducidad del access token**, que dura 15 minutos. Hay dos formas y conviene elegir antes de empezar:

- **Recomendada — build de desarrollo contra backend local** con `JWT_ACCESS_EXPIRES=30s` en el `.env` local: `flutter run --dart-define=API_BASE_URL=http://localhost:3000`. Convierte una espera de 15 min por intento en media hora de pruebas completas. No toca producción.
- **Alternativa — contra producción**: iniciar sesión, dejar la app en segundo plano 16 minutos, y actuar entonces. Más fiel, mucho más lento, y difícil de repetir.

| # | Guión | Qué se debe observar |
|---|---|---|
| 1 | **Avión durante el refresh** (§4.1). Con el token caducado, activar modo avión y **después** abrir la app / tirar de refrescar | **No debe aparecer el login.** Datos desde caché, banner de offline. Al desactivar avión, la app se reanuda sola sin volver a autenticarse |
| 2 | **Servidor caído** (§4.2). Con el token caducado, parar el backend local (`Ctrl-C`) y usar la app: crear una tarea | No aparece el login. La tarea queda **encolada** (badge de pendientes), no revertida — esto es lo que valida el commit 3. Al levantar el backend, se sincroniza sola |
| 3 | **Expiración real** (§4.3, el control negativo). Con el backend en marcha, invalidar el refresh token: borrar la fila de la colección `refreshtokens` de ese usuario (en el Mongo local, no en Atlas) y hacer cualquier acción tras la caducidad del access | **Debe aparecer el login**, limpiamente. Si no aparece, el round rompió la expiración de verdad, que es su mayor riesgo |
| 4 | **Handoff WiFi → móvil** (§4.1). Con la app abierta y el token caducado, desactivar el WiFi con datos móviles activos | Ni login ni error visible; a lo sumo un parpadeo del banner |
| 5 | **Cola tras desconexión** (§3, interacción con TD-062). Encadenar: dos cambios offline → provocar el fallo del guión 1 → recuperar red | Los dos cambios siguen ahí y se sincronizan. En ningún momento se pasó por el login, así que TD-062 ni interviene |

Además, en los logs de Railway (o del backend local) **no debe aparecer `refresh-token replay detected`** durante ninguna de estas pruebas. Si aparece, significa que se está reintentando el refresh en algún sitio — precisamente lo que §2 descarta.

Las que de verdad validan el round son la **1** (el TD), la **2** (la segunda mitad del daño) y la **3** (el control negativo). Sin la 3, las otras dos podrían pasar simplemente porque la app dejó de cerrar sesión nunca.

---

## Anexo — hallazgo colateral, fuera del alcance de este round

**CLAUDE.md describe mal el rate limiting de `/api/auth/*`.** Dice que toda esa ruta está exenta del limitador global mediante un `skip` sobre `req.originalUrl`; el código (`app.ts:61`) exime solo dos prefijos concretos:

```ts
const OWN_LIMITER_PREFIXES = ['/api/auth/register', '/api/auth/login'];
```

De modo que `/auth/refresh` y `/auth/logout` **sí** cuentan contra los 100 req/15 min/IP del limitador global, y **no** están cubiertos por el limitador de credenciales (5/15 min), que se monta solo en `/register` y `/login`.

No cambia la recomendación de §2 —refuerza el argumento contra los reintentos, porque bajo CGNAT de operador ese presupuesto se comparte entre usuarios reales—, pero la documentación afirma algo que el código no hace. Se reporta y no se corrige: este round es solo de diseño.

---

## Decisiones aprobadas

Aprobadas por el dueño el 2026-08-19, antes de empezar la implementación.

### 1. Tres desenlaces en vez de `String?`

Confirmada la recomendación de §2: `_refreshToken` devuelve **rotado / rechazado / inalcanzable**. Se acepta el razonamiento de que el root cause no es el `catch (_)` sino un tipo de retorno que no puede expresar el tercer estado — con `String?`, el bug se reintroduce solo la próxima vez que alguien toque la función.

### 2. Sin reintento del refresh

Se descartan (b) y (c). El motivo aprobado es el duro: la rotación **no es idempotente** (`findOneAndDelete`, *"the delete IS the claim"*), así que reintentar una llamada cuya respuesta no se vio cae en la detección de replay del backend, dispara `captureSecurityWarning` —el canal de alerta del robo de refresh tokens— y revoca la familia. Envenenar ese canal con falsos positivos cuesta más que el microcorte que el reintento pretendía rescatar, sobre todo cuando el reintento útil ya existe gratis: la siguiente petición genera otro 401.

**Debe quedar como comentario en el código**, junto al desenlace inalcanzable. Es una decisión que se ve razonable de revertir sin conocer el backend.

### 3. Solo el 401 mata la sesión; el 403 es infraestructura

Aprobada explícitamente la desviación respecto al enunciado de la opción (a). El backend nunca responde 403 en `/auth/refresh` —todas sus salidas de error son `AppError(..., 401)`—, así que un 403 en esa ruta viene de un proxy, un WAF o un portal cautivo, y tratarlo como sesión muerta reintroduciría el bug por otra puerta.

La clasificación queda por **lista blanca**: solo el 401 rechaza; cualquier cosa no contemplada cae del lado seguro por construcción.

### 4. Un 2xx sin tokens en el cuerpo es inalcanzable

El portal cautivo (§4.5) no lanza excepción: devuelve 200 con HTML. Es el caso que rompe la versión ingenua de (a) y se clasifica como inalcanzable, no como rechazo.

### 5. Breadcrumb de Sentry, no evento

En el desenlace inalcanzable se deja un breadcrumb (categoría `auth`), como los que ya existen para login y completar tarea. No `captureException`: sin red esto se dispara una vez por ráfaga y una captura por ráfaga es ruido garantizado. Con breadcrumb el volumen es cero salvo que además ocurra un error de verdad, y entonces la línea temporal dice que hubo un refresh fallido antes.

### 6. El commit 3 va: la petición original pasa a ser encolable

Aprobada la segunda mitad del arreglo (§2). Cuando el refresh es inalcanzable, la petición original deja de propagar el 401 y se rechaza como `connectionError` → `NetworkFailure` → `isOfflineWorthy` → el repositorio encola la escritura o cae a caché.

Se acepta que es una reinterpretación y que cambia lo que ve el usuario al fallar una escritura (hoy un error, después una fila encolada), y por eso va en commit propio con parada.

### 7. Pruebas manuales contra un backend local

Se adopta el montaje recomendado en §6: backend local con `JWT_ACCESS_EXPIRES=30s`, en vez de esperar 15 minutos por intento contra producción. El control negativo (guión 3, la expiración de verdad) se provoca borrando la fila correspondiente de la colección `refreshtokens` **en el Mongo local**, nunca en Atlas.

### 8. La documentación del limitador se corrige en el commit final

El hallazgo del anexo entra en el commit de cierre de este round: CLAUDE.md afirma que todo `/api/auth/*` está exento del limitador global, y no es cierto — `OWN_LIMITER_PREFIXES` solo exime `/register` y `/login`, así que `/auth/refresh` y `/auth/logout` **sí** cuentan contra los 100 req/15 min/IP.

Es solo documentación: no se cambia el comportamiento del backend en este round.

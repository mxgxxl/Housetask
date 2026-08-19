# TD-062 — Diseño: la caché offline sobrevive a un cambio de cuenta

Plan para TD-062 (ver `docs/TECH_DEBT.md`), detectado al diseñar TD-061. Documento de diseño: no se ha tocado código, tests, CI ni TDs al escribirlo. Verificado contra el árbol en `0201f29`.

---

## 1. Root cause exacto

### Las dos limpiezas, y que no van juntas

Hay **dos** almacenamientos y **dos** rutinas de limpieza distintas, y no se llaman desde los mismos sitios:

| Almacenamiento | Qué guarda | Quién lo limpia |
|---|---|---|
| **SharedPreferences** (`AuthLocalDataSource.clear()`) | `accessToken`, `refreshToken`, `userJson`, `currentHouseholdId` | `AuthRepository.logout()` **y** `ApiService._onError` en la expiración (`api_service.dart:73`) |
| **Hive** (`CacheService.clearAll()`) | tareas, compra, hogares y **la cola de `PendingOperation`** | **Solo** `AuthCubit.logout()` (`auth_cubit.dart:117`) |

La expiración de sesión limpia la primera y **no toca la segunda**:

```dart
} else {
  // Refresh failed → session is dead.
  await _local.clear();      // SharedPreferences: sí
  onSessionExpired?.call();  // Hive: NO
}
```

`AuthCubit.onSessionExpired()` se limita a emitir `unauthenticated`.

### La secuencia que rompe

1. El usuario **A** hace cambios sin conexión: cada uno deja una `PendingOperation` en Hive.
2. Su sesión caduca (el refresh falla). SharedPreferences queda limpio; **las cuatro boxes de Hive siguen intactas**, cola incluida.
3. El usuario **B** inicia sesión en el mismo dispositivo. Ni `login()` ni `register()` ni `checkAuth()` limpian Hive — `clearAll()` no se llama desde ninguno.
4. `syncPendingOperations` filtra por `entity` (task/shopping), **no por usuario ni por hogar**. En la primera transición offline→online reproduce la cola de A **con el token de B**.
5. Las operaciones apuntan a hogares de los que B no es miembro → el servidor responde **403/404**. No es un fallo de red, así que no entra en la rama `isOfflineWorthy`: consume sus **3 reintentos** (ADR-010) y termina descartada con reporte a Sentry.

**Qué se rompe y qué no:** no hay fuga de datos hacia los hogares de B — el filtrado por `householdId` del servidor lo impide, y la caché de tareas se consulta por hogar, así que B nunca ve tareas de A en pantalla. Lo que sí ocurre es que **se intentan escrituras de una cuenta bajo las credenciales de otra**, que se pierden las de A definitivamente, y que Sentry se llena de descartes que parecen un bug del sync.

Es literalmente lo que advierte el comentario de `logout()` — *"offline writes queued under this session must not silently replay onto whatever account signs in next"* — solo que esa protección vive únicamente en el camino del botón.

### El detalle que condiciona todo el diseño

**Tras la expiración no queda en disco ningún registro de quién era el dueño de los datos de Hive.** `_local.clear()` borra también `userJson`, así que en el siguiente login no hay nada contra lo que comparar.

Cualquier solución del tipo "detectar el cambio de usuario" necesita, por tanto, **un marcador propio** que sobreviva a esa limpieza. No es un detalle de implementación: es lo que descarta la versión ingenua de la opción (a).

### Un hallazgo colateral que agrava el escenario

`_refreshToken()` termina en `catch (_) { completer.complete(null); }`: **traga cualquier excepción, incluida la de red**. El interceptor interpreta ese `null` como "la sesión está muerta".

Para que ocurra hace falta un 401 real seguido de un refresh que falla por red — token caducado justo con mala cobertura, por ejemplo. No es exótico. Y significa que **una expiración no siempre es una expiración**: puede ser una desconexión pasajera.

Eso no se arregla aquí, pero pesa en §2: convierte "limpiar en la expiración" en "borrar el trabajo offline de un usuario que solo tenía mala cobertura". Merece TD propio.

---

## 2. Opciones y trade-offs

### (a) Limpiar al autenticar, detectando cambio de `userId`

Se guarda quién es el dueño de la caché y, en cada autenticación con éxito, se compara: si el usuario que entra no es el mismo, `clearAll()`.

- **A favor:** cubre **todas** las entradas a una sesión autenticada —`login`, `register` y la restauración de `checkAuth`— en un solo punto. Es el único sitio donde con certeza se sabe *quién* va a usar la caché.
- **A favor:** limpia solo cuando hace falta, así que **preserva la cola si vuelve el mismo usuario**, que es justo lo que TD-061 §4.3 promete.
- **En contra:** necesita un marcador persistido nuevo (§1).

### (b) Limpiar en `onSessionExpired`

Añadir `clearAll()` junto al `_local.clear()` de la expiración.

- **A favor:** dos líneas, sin estado nuevo.
- **En contra, y es descalificante:** **destruye la cola de un usuario que no ha hecho nada.** Una caducidad de token no es una acción suya. Y por el hallazgo colateral de §1, un refresh fallido por red se trata igual que uno rechazado: bastaría un túnel para perder el trabajo offline.
- **En contra:** contradice de frente lo que acabamos de construir. TD-061 §4.3 documenta —y un test fija— que la expiración **no** pierde la cola, precisamente para que los cambios sigan ahí cuando el usuario vuelva.
- **En contra:** no cubre otras rutas hacia un cambio de cuenta (un logout que falle a medias, un estado que quede sin tokens por otra vía).

### (c) Ambas

Hereda el defecto de (b) sin ganar nada que (a) no dé ya: si (a) limpia en cada autenticación con usuario distinto, limpiar además en la expiración solo adelanta el borrado al momento en que **todavía no se sabe si hará falta**.

### (d) Marcar cada `PendingOperation` con el `userId` y filtrar en el sync

- **A favor:** preserva la cola de A aunque B use el dispositivo, y A la recupera al volver. Es el mejor resultado posible para el usuario.
- **En contra:** cambia el esquema de un modelo persistido. `PendingOperation` tiene un `TypeAdapter` escrito a mano con `typeId: 3`; añadir un campo obliga a manejar filas antiguas sin él (¿de quién son?) y a decidir qué hacer con ellas — que es la misma pregunta, otra vez.
- **En contra, y es lo decisivo:** **no resuelve el problema, solo su síntoma más visible.** Deja en el dispositivo de B la cola *y* las entidades cacheadas de A, indefinidamente y creciendo. Eso es un problema de privacidad en un dispositivo compartido, no solo de ruido en Sentry. Habría que limpiar igualmente, así que (d) no sustituye a (a): se sumaría.

### Recomendación: **(a)**

Es la única que ataca la causa —nadie comprueba de quién son los datos— en lugar de un momento concreto en que se manifiesta. Cubre todas las entradas a una sesión, no rompe la promesa de TD-061 y, al limpiar solo cuando el usuario cambia, entrega gratis la ventaja que motivaba (d) para el caso frecuente: el mismo usuario recupera su cola.

**Dónde vive el marcador.** Una box de Hive dedicada (`Box<String>`, sin adapter), gestionada por `CacheService` y **vaciada por `clearAll()`**. Razón: el marcador describe de quién son los datos de Hive, así que debe vivir y morir con ellos. Guardarlo en SharedPreferences lo dejaría sobrevivir a un borrado de Hive y afirmar una propiedad sobre datos que ya no existen.

**Sentido a prueba de fallos:** marcador ausente y caché con contenido → **limpiar**. Ante la duda, se borra. El coste de equivocarse en esa dirección es perder trabajo offline no sincronizado; en la contraria, reproducir escrituras de otro. No son comparables.

---

## 3. Interacción con TD-061

### Si el fix fuera (b): ¿debería avisar?

**No, y ese es justamente el argumento para no elegir (b).** En la expiración **no hay usuario delante a quien preguntar**: la sesión ya murió, `SessionListeners` navega a login desde donde estuviera, y no hay interacción que confirmar. Un aviso ahí solo podría ser informativo —"has perdido N cambios"—, es decir, la notificación de un daño ya hecho.

TD-061 se apoya en poder preguntar **antes** de destruir. La expiración no ofrece ese momento, y por eso destruir en la expiración es exactamente lo que TD-061 evitaba: pérdida sin decisión del usuario.

### Con el fix (a), TD-061 queda intacto

Las tres formas del diálogo siguen siendo correctas y el contador sigue diciendo la verdad. Un matiz que **mejora**: TD-061 §4.5 advertía que el contador podía incluir operaciones de una sesión anterior, y con (a) esa caché ya se ha limpiado al autenticar, así que lo que cuenta es siempre del usuario que está mirando.

La única coordinación necesaria es de orden: **la limpieza por cambio de usuario ocurre al autenticar**, mucho antes de que nadie abra el diálogo de logout. No compiten.

---

## 4. Casos borde

### 4.1 Expiración con cola pendiente y sin conexión

Con (a) no pasa nada en ese momento: la cola se queda en disco, que es lo que TD-061 §4.3 promete. Se decide al volver a autenticarse, y para entonces ya se sabe quién entra.

Es también el escenario que hace peligroso el hallazgo colateral de §1: si la "expiración" fue en realidad un fallo de red, el usuario volverá a entrar con su propia cuenta y **recuperará su cola intacta**. Con (b) la habría perdido.

### 4.2 Logout de A y vuelve a entrar A

**No hay nada que preservar:** el logout explícito ya ejecutó `clearAll()`, y con la solución de TD-061 el usuario lo confirmó sabiendo lo que descartaba. Al volver a entrar, el marcador está vacío y se guarda el suyo.

Distinto del caso "expiración de A + vuelve A", donde **sí se preserva** (4.1). La diferencia es deliberada y vale la pena escribirla: en un caso el usuario decidió; en el otro le pasó algo.

### 4.3 Logout de A y entra B

Igual que 4.2 desde el punto de vista de los datos —el logout ya limpió—, con la diferencia de que el marcador ausente hace que se limpie otra vez al autenticar B. Es un `clearAll()` sobre boxes vacías: barato e inofensivo, y mantiene la regla sin excepciones.

### 4.4 Expiración de A y entra B — el caso que define el TD

El marcador dice `A`, entra `B` → **`clearAll()` antes de que nada pueda leer o sincronizar**. La cola de A se pierde, y eso es correcto: es de otra cuenta y no hay forma de entregársela.

**Requisito de orden, y es el punto crítico de la implementación:** la limpieza debe completarse **antes** de que `HouseholdCubit.init()`, cualquier `load()` o el listener de conectividad puedan disparar `syncPending()`. Si se hace tarde, la cola de A puede haberse reproducido ya. Es lo que fija el test de §5.

### 4.5 Primera instalación

Marcador ausente y caché vacía. Se limpia igualmente (sentido a prueba de fallos) y se guarda el dueño. Un `clearAll()` sobre boxes vacías no cuesta nada.

### 4.6 `checkAuth()` restaura una sesión existente

Es el arranque normal de la app: mismo usuario, marcador coincide, **no se limpia nada**. Cualquier otra cosa sería borrar la caché en cada arranque y anular TD-003 entero.

Merece test propio porque es el camino más frecuente de los tres y el que más caro sale romper.

### 4.7 El usuario cambia sin pasar por `unauthenticated`

Hoy no ocurre: no hay "cambiar de cuenta" sin cerrar sesión. Si algún día lo hubiera, (a) lo cubre por construcción, porque la comprobación cuelga de la autenticación y no del logout.

---

## 5. Tests y plan de commits

### Tests

| Test | Verifica |
|---|---|
| `un usuario distinto vacía la caché al autenticar` | El caso de §4.4 |
| `el mismo usuario conserva la caché` | §4.6 — el arranque normal no puede borrar nada |
| `el mismo usuario tras una expiración conserva su cola` | §4.1, la promesa de TD-061 §4.3 |
| `marcador ausente con caché no vacía → se limpia` | El sentido a prueba de fallos |
| `el marcador se guarda tras autenticar` | Sin esto, se limpiaría en cada arranque |
| `clearAll vacía también el marcador` | O quedaría afirmando la propiedad de datos borrados |
| `login, register y checkAuth pasan por la misma comprobación` | Un solo punto: tres tests o uno parametrizado |
| `la limpieza ocurre ANTES de que se pueda sincronizar` | §4.4 — el orden es el fix, igual que en TD-057 |

Estimación: **~9 tests**, casi todos de `AuthCubit` con un `CacheService` falso; el del marcador, contra Hive real usando la costura de TD-059.

### Plan de commits

| # | Título | Alcance | Riesgo | Parada |
|---|---|---|---|---|
| 1 | `feat(cache): marcador de propietario de la caché` | Box del marcador, leer/escribir, y `clearAll()` que lo vacía. Nadie lo usa aún | Bajo | |
| 2 | `fix(auth): vaciar la caché al autenticar otro usuario` | Punto único en `AuthCubit`, invocado desde `login`/`register`/`checkAuth`. **Cierra TD-062** | **Alto** — toca el arranque de sesión, el camino por el que pasa todo | **Sí** |
| 3 | `docs: cerrar TD-062` | TECH_DEBT, tabla corta, `NEXT_SESSION_MAC`, y abrir el TD del refresh que confunde red con sesión muerta (§1) | Ninguno | |

Solo dos commits de código: el fix es pequeño. El riesgo no está en su tamaño sino en su posición — un error aquí no rompe una pantalla, impide entrar en la app o borra la caché en cada arranque.

**La parada tras el commit 2** es para validar en dispositivo antes de dar TD-062 por cerrado, porque los dos fallos que importan (borrar de más, borrar de menos) son invisibles en la UI: uno se manifiesta como "la app va lenta al arrancar" y el otro como nada en absoluto hasta que aparecen descartes en Sentry.

---

## 6. Riesgos, rollback y pruebas manuales

### Riesgos

| Riesgo | Detección |
|---|---|
| **Borrar de más**: un bug de comparación limpia con el mismo usuario, y TD-003 deja de funcionar — la app pierde su caché en cada arranque | Test de §4.6 y prueba manual 1. En dispositivo se nota como "arranca sin datos hasta que carga" |
| **Borrar de menos**: la comprobación no cubre alguna ruta y el problema sigue vivo | El test de que las tres entradas pasan por el mismo punto |
| **Limpiar tarde**, después de que algo haya disparado `syncPending` (§4.4) | El test de orden. Es el mismo tipo de error que TD-057: el arreglo no es *qué* se hace sino *cuándo* |
| **El marcador se desincroniza** de los datos que describe | Vive en Hive y lo vacía `clearAll()`, así que no puede sobrevivirles. El test lo fija |
| **Una expiración espuria por red** hace perder la cola | **No con (a)**: se decide al reautenticar y el mismo usuario la recupera. Con (b) sí, y es el motivo principal para descartarla |

### Lo que este round NO arregla

**`_refreshToken()` traga los errores de red y los trata como sesión muerta** (§1). Con la solución (a) deja de destruir datos, pero sigue expulsando al usuario a la pantalla de login por una desconexión pasajera. Merece **entrada propia**: distinguir un refresh rechazado (401/403 del servidor) de uno que no llegó a preguntar, y en el segundo caso no matar la sesión.

Es vecino de TD-054 (ventana del token tras el logout) pero distinto: aquí no hay exceso de permiso, hay falta de sesión.

### Rollback

Ambos commits son revertibles por separado y ninguno cambia el formato de datos existentes: el marcador es una box nueva, y su ausencia se interpreta como "limpiar", que es el comportamiento seguro. Revertir el commit 2 devuelve exactamente el estado actual.

**No hay migración**: `PendingOperation` no se toca —esa era la ventaja de descartar (d)— y las boxes existentes se leen igual.

### Pruebas manuales

Necesitan **dos cuentas** y provocar una expiración de sesión. La forma fiable de provocarla es invalidar el refresh token en el servidor; esperar a que caduque solo funciona si el plazo es corto.

1. **El arranque normal no borra nada** (§4.6, el que más caro sale romper): con datos cacheados, cerrar y reabrir la app en modo avión. Las tareas deben verse **inmediatamente** desde la caché. Si aparece un momento en blanco o una lista vacía, la comprobación está borrando de más.
2. **Expiración y vuelve el mismo usuario** (§4.1): modo avión → 2 cambios → forzar la expiración → volver a entrar con **la misma cuenta**. Los cambios deben seguir ahí y sincronizarse.
3. **Expiración y entra otra cuenta** (§4.4, el caso del TD): igual, pero entrando con **B**. La cuenta B no debe ver nada de A, y —lo importante— **no deben aparecer descartes en Sentry** tras 3 reintentos en los minutos siguientes. Ese silencio es el resultado.
4. **Logout explícito y vuelve el mismo usuario** (§4.2): confirmar el descarte en el diálogo de TD-061 y volver a entrar. La cola debe estar vacía: el usuario lo decidió.
5. **Primera instalación** (§4.5): borrar la app, reinstalar, entrar. Nada raro, sin retraso perceptible al autenticar.

La 1 y la 3 son las que de verdad validan el round: una vigila el fallo por exceso y la otra el que motivó el TD.

---

## Decisiones aprobadas

Aprobadas por el dueño el 2026-08-19, antes de empezar la implementación.

### 1. El marcador vive en una box de Hive dedicada, con su propio adapter

Confirmada la recomendación de §2: box nueva, `typeId` nuevo, adapter propio, y `clearAll()` la vacía junto con las otras cuatro. El marcador describe de quién son los datos de Hive, así que muere con ellos.

Nota de implementación, por si alguien la revisa y le extraña: un `Box<String>` habría bastado — Hive persiste `String` sin adapter. Se modela igualmente porque un `CacheOwner { userId, updatedAt }` responde también *desde cuándo* la caché pertenece a ese usuario, que es exactamente el dato que uno quiere cuando investiga por qué se limpió (o por qué no).

### 2. El problema del refresh se registra como TD-063

`_refreshToken()` traga cualquier excepción, incluida la de red, y el interceptor trata ese `null` como sesión muerta (§1). Queda como **TD-063**, Open, prioridad **Medium**, con la evidencia de este documento, y su diseño en un round aparte.

Prioridad Medium y no High porque, una vez aplicado el fix (a) de este round, **deja de destruir datos**: el usuario vuelve a entrar con su cuenta y recupera su cola. Lo que queda es una expulsión a la pantalla de login por una desconexión pasajera — molesto, no destructivo.

### 3. La asimetría logout / expiración queda validada

- **Logout explícito → la cola se pierde.** Es una decisión del usuario, tomada con la información delante desde TD-061.
- **Expiración → la cola se preserva.** Es un evento del sistema; el usuario no eligió nada, y borrar su trabajo por algo que le ocurrió sería castigarle por la caducidad de un token.

Es la regla de producto que sostiene todo el diseño y conviene leerla así: **lo que decide si se conserva no es el estado técnico, sino si hubo alguien decidiendo.**

### 4. La expiración se provoca en tests con un token malformado o caducado

Nada de tocar el servidor. Las pruebas usan un JWT inválido —o un mock del interceptor que devuelva 401— para forzar el camino de refresh fallido.

Consecuencia sobre el plan de §5: los tests del escenario de expiración **no son un commit de producción aparte**. En la expiración no se limpia nada (decisión 3) ni se puede saber quién entrará después, así que lo que hay que verificar es la secuencia completa *expiración → login de otro usuario → limpieza*, que es comportamiento del fix (a) observado desde el otro extremo. Se cubren como tests de la solución ya implementada, no como una limpieza nueva en `onSessionExpired`.

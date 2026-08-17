# Product Decision Records (PDRs)

Los PDRs registran decisiones de producto con Context / Decision / Consequences, espejo de los ADRs técnicos de CLAUDE.md. Las decisiones aquí contenidas son fuente de verdad para el roadmap; el código las implementa, no las redefine.

## PDR-001: Monetización F2P + mascota cooperativa del hogar

**Status:** Fase A complete (A1–A4): economía base, adopción cooperativa + instantánea, pestaña Mascota en frontend, tienda de cosméticos, y A4 complete: realtime pet updates via SocketCubit + live cooldown countdown

- **Context:** App de gestión doméstica para parejas/hogares. Una suscripción tiene valor percibido bajo para este público y un paywall inicial mataría la adquisición. Se necesita retención más allá de la utilidad diaria y una vía de monetización sin fricción.
- **Decision:**
  1. Free-to-play sin paywall. Monetización en Fase C mediante cosméticos: moneda ganada jugando + packs de pago único vía IAP (revenue_cat).
  2. Mascota compartida del household (pertenece al hogar, como las tareas), con tono visual cozy/adulto (referentes: Forest, Animal Crossing, Duolingo), NO infantil.
  3. Fases:
     - Fase A (MVP): 2 starters (gato/perro), adopción por consenso del hogar (un miembro inicia, el otro confirma), estados que decaen con el tiempo (hambre/ánimo), cuidado mediante tareas completadas y compras realizadas, moneda básica con caps diarios y anti-farm, tienda pequeña de cosméticos por moneda. Sin minijuegos.
     - Fase B: economía completa (loot drops variables, rachas, logros), especies desbloqueables/comprables como colección con UNA mascota activa a la vez (rotable).
     - Fase C: IAPs de packs cosméticos. Minijuegos: puerta abierta futura, no planificados.
  4. Recompensas variables e intermitentes (loot drops, críticos, bonus de racha) en lugar de salario fijo por tarea, para evitar overjustification effect.
  5. Economía server-authoritative: las monedas se otorgan server-side al completar tareas/compras; reglas anti-farm (solo primera completación otorga, caps diarios, cooldowns), apoyadas en la idempotencia y replay detection existentes.
- **Consequences:**
  - Scope nuevo grande pero fasesado; el core (tareas/compras) sigue siendo prioridad hasta validar hábito con uso real (2-4 semanas) antes de iniciar Fase A.
  - Requiere arte animado (Rive/Lottie) para 2 mascotas en Fase A.
  - Fase C requiere cuentas de developer (Apple $99/año, Google $25 único), necesarias de todos modos para publicar.
  - La mascota amplifica un hábito existente, no lo crea: si la retención del core es baja, reevaluar antes de invertir en Fase A.
  - **Nota de economía (A1):** Coins granted server-side on first task/purchase completion (TASK_COINS=5, PURCHASE_COINS=2, DAILY_CAP=50). Idempotent via unique ledger index. Hunger/mood decay lazily on read. Art is placeholder for now (Rive/Lottie later).
  - **Nota de economía (A2):** Adoption is two-step (request by member A, confirm by member B). Feed/play free with 1h cooldown (anti-farm of states, no coins). Cosmetics bought with coins (ledger negative), unique per household. Generic PATCH completion now grants coins (economy consistency).
  - **Nota A3:** Frontend pet tab with adoption (propose/confirm/cancel), care view (feed/play with cooldown), cosmetics shop. Art is emoji placeholder; Rive/Lottie deferred. Realtime socket refresh deferred to A4.
  - **Nota (adopción instantánea, hogares de 1 miembro):** Adoption is cooperative for 2+ member households (propose + confirm by a different member). Single-member households adopt instantly on propose (no confirmation step).
  - **Nota A4 (complete):** SocketCubit forwards pet:adopt_requested/pet:adopted/pet:adopt_cancelled/pet:updated to PetCubit.applyRealtime (same wiring pattern as Task/Shopping), which reloads pet + economy — no manual pull-to-refresh needed. pet_page's care view ticks hunger/mood decay and the feed/play cooldown countdown once a second (Timer.periodic in a dedicated stateful subtree, disposed on unmount, no full-page rebuilds).

## PDR-002: Visibilidad cooperativa en flujos core

**Status:** In progress (commits 1-2 de este round)

- **Context:** El selector de asignación mostraba usuarios en blanco y los tiles completados no indican quién los completó; ambos degradan el ángulo cooperativo del producto.
- **Decision:** Asignación siempre con nombre+avatar del miembro; tile completado muestra quién la completó (fallback "Ex-miembro").
- **Consequences:** Refuerza percepción de colaboración sin cambiar permisos (TD-011 ya resuelto).

## PDR-003: Timeline por días en pestaña Todas

**Status:** In progress (commits 2-3 de este round: filtrado por rango de fechas en backend, timeline agrupado por día en frontend)

- **Context:** La lista plana no responde "qué hice / qué hago / qué viene".
- **Decision:** Vista agrupada por día (ayer arriba, hoy, mañana, sucesivos), 3 tareas visibles por día + "mostrar más", más días al hacer scroll; endpoint de rango por fechas apoyado en paginación por cursor existente; agrupación por día en el cliente (timezone local del dispositivo) para no depender de TD-013.
- **Consequences:** Rediseña la pestaña Todas de TD-027; Pendientes/Completadas permanecen como listas.

## PDR-004: Tareas con duración y bloques en calendario

**Status:** Resolved

- **Context:** Tareas no instantáneas ("pintar el salón de 13 a 20") no tienen representación hoy.
- **Decision:** startsAt/endsAt opcionales en Task (sin ellos = instantánea, retrocompatible); calendario pinta rangos como bloques con hora y el resto como all-day; notificación "empieza en 30 min" con el sistema existente.
- **Consequences:** Extiende modelo y calendario sin romper recurrencia existente. Duration + recurrence is out of scope this round: recurring tasks ignore startsAt/endsAt — the form hides the duration pickers whenever recurrence is on, and the backend never persists (and clears any pre-existing) startsAt/endsAt on a recurring task. Calendar follows Google Calendar-style rendering: ranged tasks appear on every day they span (month spanning bars + day-view segmented blocks); single-day ranged tasks show as time-range chips / hour blocks. Calendar includes Mes/Semana selector; week view reuses spanning bars logic from month view. table_calendar limitation (no spanning) resolved by custom grid.

## PDR-005: Android minSdk 23 (Android 7.0+)

- **Context:** Flutter 3.44+ enforces minSdk 23 as a hard error (`DependencyVersionChecker.errorMinSdkVersion`) — a project below that floor cannot build at all on this Flutter version, independent of any Gradle/AGP/Kotlin fix.
- **Decision:** Raise minSdk from 21 to 23, dropping support for Android 5.0–6.0 (<5% market).
- **Consequences:** Cleaner builds, no workaround flags; acceptable for validation phase.

## PDR-006: Soft delete y papelera de tareas (TD-046)

**Status:** Resolved

- **Context:** Borrar una tarea era instantáneo e irreversible (hard delete); un swipe accidental, o el de un miembro con prisa, perdía la tarea (y su historial de completado) sin ninguna red de seguridad. En un hogar compartido el coste de un borrado accidental lo paga otro miembro, no quien lo causó.
- **Decision:** DELETE marca la tarea como borrada (`isDeleted` + `deletedAt`) en vez de eliminar el documento; los listados la excluyen por defecto. Nueva sección "Papelera" (acción en la barra superior de Tareas) lista las tareas borradas con un botón "Restaurar". Restaurar, igual que editar/borrar, está limitado al creador de la tarea o a un admin del hogar (misma regla que TD-011) — cualquier miembro puede borrar (como ya podía completar), pero deshacerlo requiere el mismo nivel de permiso que borrarlo.
- **Consequences:** Red de seguridad de bajo coste (ningún cambio de esquema visible al usuario, la app se siente igual salvo por la Papelera); las tareas borradas quedan en la base de datos indefinidamente — no hay todavía un purgado periódico, aceptable mientras el volumen sea bajo (household de 2-6 personas); un purgado (p.ej. borrar definitivamente tras 30 días) es un candidato de Fase 2 si el almacenamiento llega a importar.

## PDR-007: Estadísticas básicas del hogar

**Status:** Implemented

- **Context:** No había visibilidad del reparto de carga entre miembros del hogar (quién completa más tareas, qué % se completa). Esta visibilidad es la semilla de futuras features de retención (rachas, logros — ver PDR-001 Fase B), pero hoy el alcance se limita a datos básicos bien hechos, sin gamificación todavía.
- **Decision:** `GET /households/:householdId/stats?period=last30days|allTime` (cualquier miembro puede leer) devuelve `totalTasks`, `completedTasks`, `completionRate`, `memberStats` (todos los miembros actuales, incluidos los que tienen 0 actividad) y `topCompleter` (null si nadie ha completado nada). `last30days` filtra `completedAt` para las métricas de completado y `createdAt` para el resto, igual que el filtrado por `isDeleted` ya establecido en TD-046. Frontend: nueva `StatsPage` alcanzable desde el icono de la AppBar de Perfil (no se añade una 7ª pestaña al bottom nav), con toggle de periodo, tarjeta de tasa de completado, top completer y barras proporcionales por miembro (`LinearProgressIndicator`, sin librerías de charts nuevas). Estado gestionado por un `StatsCubit` nuevo, no por `HouseholdCubit` — es estado de vista de una pantalla concreta (loading/periodo), no parte de "el hogar activo".
- **Consequences:** Endpoint de solo lectura, sin impacto en escritura ni en el modelo de datos existente. Es la base de datos que futuras features de retención (rachas, logros, comparativas) consumirán, pero esas features quedan fuera de este round.

## PDR-008: Notificaciones push (FCM) para asignación y completado de tareas

**Status:** Implemented (infraestructura base + los 2 triggers principales; recordatorios de tareas próximas quedan para PDR-003/futuro)

- **Context:** El único aviso de que "te asignaron algo" o "completaron tu tarea" era abrir la app y mirar. En un hogar compartido eso rompe el ángulo cooperativo del producto (mismo motivo que PDR-002): si nadie se entera de una asignación hasta que abre la app por otra razón, la coordinación en tiempo real que ya existe vía Socket.io en la sesión activa no llega a los momentos en que la app está cerrada.
- **Decision:**
  1. Backend: Firebase Admin SDK (`firebase-admin`), inicializado de forma perezosa y no bloqueante desde `FIREBASE_SERVICE_ACCOUNT` (JSON como variable de entorno, nunca un archivo commiteado) — mismo patrón "no-op si no está configurado" que `utils/sentry.ts` (TD-009): ausencia o JSON inválido deshabilita el envío sin romper nada más.
  2. Nuevo modelo `DeviceToken` (`userId`, `token`, `platform`, índice único compuesto `{userId, token}`) y `notification.service.ts`'s `sendPushNotification(userId, title, body, data?)`: multicast a todos los tokens del usuario vía `sendEachForMulticast`, borra automáticamente los tokens que FCM reporta como `registration-token-not-registered`.
  3. `POST /api/devices/register` (upsert; si el token ya pertenecía a otro usuario —dispositivo compartido— se transfiere) y `DELETE /api/devices/:token` (logout), ambos bajo auth JWT; `register` protegido por Idempotency-Key (Hard Rule 13).
  4. Dos triggers, ambos fire-and-forget (try/catch que nunca puede tumbar la operación principal, mismo patrón que `grantCoins` de PDR-001):
     - `task.service.ts createTask`: push a cada asignado que no sea quien crea la tarea ("Nueva tarea asignada: {creador} te asignó: {título}").
     - `task.service.ts completeTask`: push al creador cuando quien completa es otra persona ("Tarea completada: {completador} completó: {título}").
  5. Frontend: `firebase_messaging` + `firebase_core` en `NotificationService` (ya existente para recordatorios locales, ahora extendido, no un servicio nuevo): `requestPermission()`, `getToken()`, `registerToken()`, `listenForTokenRefresh()`, `showLocalNotification()` (hace visible un push en foreground, ya que FCM no muestra banner nativo con la app abierta). `AuthCubit` dispara `initPushNotifications()` tras autenticarse y `unregisterToken()` en logout (antes de invalidar la sesión, para poder autenticar el DELETE).
- **Consequences:**
  - Este repo NO trae un proyecto Firebase real conectado (sin `google-services.json` / `GoogleService-Info.plist`, sin plugin `com.google.gms.google-services` aplicado a propósito para no romper el build de Android sin esos archivos) — ver TD-049. Todo el código está listo pero la entrega real de push requiere ese setup manual (cuenta Firebase, `flutterfire configure`, capability de Push Notifications + APNs key en Xcode para iOS) antes de la beta.
  - Recordatorios de tareas próximas (PDR-003 lo menciona como "futuro") NO están en este round — solo asignación y completado.
  - Sin navegación a la tarea específica al tocar el push: no existe todavía una ruta de deep-link por tarea, así que `onMessageOpenedApp` navega al shell principal (pestaña de tareas) en vez de abrir la tarea exacta.
  - Sin manejo de mensajes en background/terminated (`onBackgroundMessage`/`getInitialMessage`) — solo foreground (banner local) y background→foreground vía tap. Candidato de un round futuro si se detecta necesidad real.

## 2026-08-17 — Codex como agente secundario para límites de Claude Code

### Decisión

Mantener Claude Code como herramienta principal de desarrollo en HomeSync y contratar OpenAI Codex como agente secundario para rotar cuando Claude alcance límites de sesión o semanales.

### Razón

Claude Pro puede alcanzar límites de uso y bloquear la ejecución. Añadir Codex como segundo carril permite mantener continuidad operativa sin renunciar a Claude como herramienta principal para tareas complejas.

### Modelo operativo

- Claude Code sigue siendo la herramienta principal para arquitectura, debugging complejo, refactors delicados y decisiones sensibles.
- Codex se usará como fallback para tareas acotadas, mecánicas, tests, documentación, bugs pequeños y PRs validables por CI.
- Las tareas complejas que no puedan dividirse con seguridad se dejarán en cola para Claude si Codex no ofrece garantías suficientes.

### Reglas

- Codex no modificará TDs abiertos sin instrucción explícita.
- Commits atómicos.
- Durante el pilotaje, Codex trabajará por rama y PR.
- CI verde antes de merge.
- El dueño aprueba decisiones, push y merge.
- Al finalizar cada tarea se sincronizan los archivos de contexto.

## 2026-08-17 — Cierre del piloto Codex y flujo definitivo

### Decisión

Cerrar el piloto de Codex con resultado positivo y definir el flujo definitivo: en Mac, Codex CLI trabaja igual que Claude Code (commits directos a main, push aprobado por el dueño); en móvil/cloud, Codex app/web trabaja por rama + PR + CI + aprobación del dueño.

### Razón

El piloto (#32, #34) demostró respeto de scope, commits atómicos y buenas decisiones autónomas. El flujo directo en Mac elimina la fricción de worktrees y PRs locales; el flujo PR se mantiene donde no hay toolchain (móvil/cloud).

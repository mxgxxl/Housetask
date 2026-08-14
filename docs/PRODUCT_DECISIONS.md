# Product Decision Records (PDRs)

Los PDRs registran decisiones de producto con Context / Decision / Consequences, espejo de los ADRs técnicos de CLAUDE.md. Las decisiones aquí contenidas son fuente de verdad para el roadmap; el código las implementa, no las redefine.

## PDR-001: Monetización F2P + mascota cooperativa del hogar

**Status:** In progress (A2 — commit 2 de este round: adopción por consenso, feed/play con cooldown, tienda de cosméticos)

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

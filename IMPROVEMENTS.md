# Improvements & Workflow Learnings

Living document capturing operational learnings from the Mac↔Mobile workflow established over the last 3 days (2026-08-13 to 2026-08-16).

---

## Flujo Mac↔Móvil

### Reglas pactadas

- **Mac:** trabajo directo en main, commits atómicos, push normal. Sin ramas ni PRs.
- **Móvil:** rama nueva desde main actualizado por sesión. Reset de rama entre bloques de trabajo. Merge vía PR con CI verde. Sin amend ni force-push.
- **Modelos por tarea:** Sonnet 5 xhigh para features con lógica de negocio; Sonnet 5 medium/high para tareas mecánicas (docs, limpiezas); Sonnet 4 high para docs (40% más barato).

### Anclajes de seguridad en prompts móviles

- "Verifica que main contiene el commit X; si no, DETENTE"
- "Rama + PR, NUNCA mergees"
- "Sin amend/force-push"
- "Máx. 2 iteraciones de fix si CI rojo"

### Overhead de tokens del flujo móvil (~30-50% vs local)

- Setup inicial: lectura CLAUDE.md + verificación HEAD + git checkout/pull/branch (+15-20%)
- Reglas explícitas de seguridad en el prompt (+10-15%)
- Reportes detallados con hashes/drifts/URLs/CI (+20-25%)
- CI monitoring suscrito (+15-30% si sale rojo)
- Rama nueva por bloque para evitar divergencia (+10%)

---

## Lecciones aprendidas

### Migración EU (2026-08-16)

- **Orden crítico:** Sentry primero (decisión permanente), luego Railway (sin downtime), luego Redis.
- **Dependencias:** mover SOLO Railway a EU empeoraría la latencia si Atlas queda en US. Verificar región de Atlas/Redis antes de mover Railway.
- **Ganancia real:** ~60% menos latencia España→Railway Ámsterdam→Mongo París vs España→Railway US→Mongo París.

### Sentry setup (2026-08-16)

- **Data storage location (US/EU) es permanente** — no se puede cambiar después de crear la organización.
- **DSN de frontend NO va en variables de entorno** — entra por `--dart-define=SENTRY_DSN=...` en builds de release, para que builds de debug locales sigan no-op.
- **Alerts recomendados para apps pequeñas:** solo email, sin GitHub issues automáticos (ruido en repo).

### CI/CD: path-based skip (2026-08-16)

- **Problema:** PR #15 (docs-only: IMPROVEMENTS.md + PR template) corrió el workflow completo (backend + frontend), gastando ~10 min de CI en verificar código que no cambió.
- **Fix:** job `changes` (dorny/paths-filter@v3) al inicio de `.github/workflows/ci.yml`; los jobs `backend`/`frontend` ahora tienen `needs: changes` + `if: needs.changes.outputs.<job> == 'true'` y se saltan cuando sus paths no cambiaron. El propio `.github/workflows/ci.yml` está incluido en ambos filtros a propósito — un cambio al workflow siempre re-verifica ambas suites en vez de confiar ciegamente en el edit.
- **Lección:** un PR que solo toca `.github/workflows/ci.yml` (como el que introdujo este fix) sigue corriendo el CI completo por ese mismo motivo — no es "instantáneo", es la validación intencional del propio cambio de CI.

### iOS white-screen startup bug (2026-08-16)

- **Síntoma:** `flutter run` en iPhone físico instala la app, la Dart VM arranca, pero la pantalla se queda en blanco (launch screen nativa) — sin ningún print `flutter:` en consola, indicando que `main()` se colgaba antes de `runApp()`.
- **Diagnóstico:** se añadieron `debugPrint` temporales entre cada `await` del bootstrap en `main.dart` (Sentry → Firebase → NotificationService → CacheService → runApp) para aislar qué paso no completaba.
- **Causa raíz:** `NotificationService.init()` llamaba a `FlutterLocalNotificationsPlugin.initialize()` con `DarwinInitializationSettings(requestAlertPermission: true, ...)`, lo que dispara el diálogo de permisos del sistema en iOS. Al mostrarse ese diálogo antes de que Flutter hubiera renderizado el primer frame (`runApp()` no se había llamado todavía), el `await` quedaba bloqueado indefinidamente — de ahí la pantalla en blanco sin logs.
- **Fix:** `requestAlertPermission`/`requestBadgePermission`/`requestSoundPermission` puestos a `false` en `DarwinInitializationSettings` (así `plugin.initialize()` ya no dispara el diálogo), y la petición explícita de permisos (`_requestPermissions()`) se difiere con `WidgetsBinding.instance.addPostFrameCallback`, para que se ejecute después de que el primer frame ya esté en pantalla. `_requestPermissions()` también se envolvió en try/catch, consistente con el resto de llamadas al plugin en este archivo.
- **Nota:** no relacionado con TD-049 (que trata de conectar un proyecto Firebase real para push) — este bug es del plugin de notificaciones locales (`flutter_local_notifications`), independiente de FCM/Firebase.
- **Pendiente:** los `debugPrint('[bootstrap] ...')` añadidos a `main.dart` para el diagnóstico son temporales (marcados con `TODO(tech-debt)`) — quitar una vez el dueño confirme en dispositivo físico que la pantalla en blanco no reaparece.

### Hipótesis refutadas

- **2026-08-16 (TD-047):** "Home no muestra tareas hasta refresh" → resultó no ser un bug de load inicial; era combinación de dos bugs previos (timeline stale + creación 400). Documentado como "Resolved — hypothesis refuted" en docs/TECH_DEBT.md.
- **Lección:** antes de lanzar fix de hipótesis, verificar con evidencia de runtime (logs, status codes), no solo con análisis de código.

### Discrepancia de sesión (2026-08-17, móvil)

- Error de Qwen: asumió que TD-050..TD-054 no estaban registrados en TECH_DEBT.md. Verificación de Claude Code (commit 2fb2028) confirmó que ya estaban registrados desde 7e0555d (PR #25). Lección: verificar estado del repo antes de generar tareas de sincronización.

### Decisión TD-050 (2026-08-17)

- Opción elegida por el dueño: A — aplicar fix `createdAt: {$lt: requestStartedAt}`.
- Razón: riesgo de logout fantasma con conexión inestable > riesgo de replay real en ventana de microsegundos.
- Implementado en: 13d5cc2 (fix) + e941e23 (test)
- **Nota de validación:** el fix se implementó y se cubrió con un test nuevo de refresh concurrente (`auth.test.ts`), pero no se pudo correr la suite de Jest en esta sesión — `mongodb-memory-server` sigue bloqueado por el proxy (`fastdl.mongodb.org` → 403 de policy denial, confirmado también desde este entorno, no solo desde móvil como se documentó antes en este archivo). `npm run typecheck` y `npm run lint` sí pasan limpio sobre el cambio. La validación real de comportamiento (incluida la de concurrencia) queda en manos de CI al abrir el PR — ver `docs/NEXT_SESSION_MAC.md`, que ya señalaba TD-050 como el caso de uso típico de "necesita MongoDB real".

---

## Fricciones conocidas

### TD-040 — cuelgue de offline_banner_test.dart

- Se reproduce incluso ejecutándolo aislado.
- `frontend_server_aot` congela CPU tras 90s+ incluso con build/test_cache limpio.
- Parece host-level stall (¿resource pressure?), no bug de test.
- **Workaround CI:** paso aislado con continue-on-error (TD-044).
- **Pendiente:** investigar con --verbose en Mac idle.

### Bloqueo de npm test desde móvil (proxy MongoDB)

- `mongodb-memory-server` intenta descargar binarios de MongoDB → 403 desde algunas redes.
- **Workaround:** CI valida tests, móvil solo typecheck+lint+build.
- **Confirmado de nuevo (2026-08-16, ronda de scan auth):** `npm ci` sí funciona; lo que falla es la descarga del binario (`https://fastdl.mongodb.org/...` → `CONNECT tunnel failed, response 403`). No hay `mongod` local instalado como alternativa. Consecuencia práctica para sesiones móviles: **un fix cuyo riesgo principal es de comportamiento en runtime (no de tipos) no se puede validar localmente** — solo `npm run typecheck` y `npm run lint`. Esto acota qué fixes es razonable intentar desde móvil con presupuesto de 1 iteración de CI: cambios deterministas y de superficie pequeña sí; cambios sensibles a timing o concurrencia (p. ej. TD-050) conviene dejarlos para una sesión con MongoDB real. Workaround parcial útil: extraer la lógica pura a una función y verificarla con un script `node` suelto (se hizo así con el predicado `skip` del rate limiter global en esta ronda).

### Scan de seguridad backend auth (2026-08-16)

- **Hallazgo principal arreglado:** el limitador global (TD-006) eximía todo el prefijo `/api/auth` asumiendo que esos endpoints ya tenían su propio limitador — cierto solo para `/register` y `/login`. `/refresh` y `/logout` no tenían ninguno, así que la exención los dejaba como **las únicas rutas totalmente sin límite de toda la API**. Lección: una exención escrita por prefijo envejece mal cuando se añaden rutas nuevas bajo ese prefijo; conviene enumerar explícitamente lo que se exime (lista `OWN_LIMITER_PREFIXES`) en vez de confiar en que el prefijo entero comparta la misma propiedad.
- **Lección de proceso:** varios hallazgos Medium (TD-051, TD-052, TD-053) son de tipo "la protección existe pero vive en un default de una dependencia o en una convención, no en una aserción explícita del código". No son bugs hoy y por eso no se arreglaron en una ronda de scope cerrado, pero son exactamente los que se rompen en silencio en un bump de major.
- **Fix no aplicado a propósito (TD-050):** ver la entrada en `docs/TECH_DEBT.md`. Requiere relitigar una decisión de seguridad deliberada (TD-022) y rompería un test existente que la codifica; se documentó con el fix candidato en vez de implementarlo unilateralmente.

### Fixes TD-051, TD-052, TD-053 (2026-08-17)

**Problema:** Protecciones de seguridad dependían de defaults de dependencias externas (jsonwebtoken, comparación de secrets, timing de bcrypt). Riesgo de pérdida silenciosa de protección en major bumps.

**Solución:** Configuraciones hechas explícitas en código:
- TD-051: JWT algorithm explícito en `sign()` (`{ algorithm: 'HS256' }`) y `verify()` (`{ algorithms: ['HS256'] }`) en `utils/jwt.ts`, para las cuatro funciones (access + refresh, sign + verify).
- TD-052: `validateProductionEnv` (`utils/env.ts`) ahora rechaza `JWT_SECRET === JWT_REFRESH_SECRET` en producción, además del chequeo de longitud mínima ya existente.
- TD-053: `login` (`auth.service.ts`) compara contra un hash bcrypt fijo (`DUMMY_PASSWORD_HASH`, calculado una vez al cargar el módulo) cuando el email no existe, para que ambas ramas paguen el mismo coste de `bcrypt.compare` (~80-100ms) y la latencia deje de ser un oráculo de enumeración de cuentas.

**Nota sobre TD-053 (descripción genérica de la tarea vs. registro real):** la tarea que disparó esta ronda describía TD-053 genéricamente como "protección en default de bcrypt (salt rounds/versión)" — eso ya estaba resuelto de antes (`BCRYPT_ROUNDS = 10` como constante explícita en `auth.service.ts` desde antes de esta ronda). El TD-053 real registrado en `docs/TECH_DEBT.md` es distinto: un side-channel de timing en `login` que permite enumeración de cuentas. Se implementó el fix correcto (el que dice el registro), no el que la descripción genérica de la tarea sugería. Misma discrepancia para TD-052: la tarea lo describía como "comparación timing-safe de secrets", pero el TD-052 real es sobre `JWT_SECRET !== JWT_REFRESH_SECRET`. Lección: cuando una tarea da una descripción genérica de un TD y también apunta a `docs/TECH_DEBT.md` como fuente de contexto completo, el registro manda sobre el resumen.

**Archivos modificados:**
- `backend/src/utils/jwt.ts` (TD-051)
- `backend/src/utils/env.ts` (TD-052)
- `backend/src/services/auth.service.ts` (TD-053)
- Tests añadidos en `backend/src/tests/auth.test.ts` (TD-051 ×2, TD-053) y `backend/src/tests/env.test.ts` (TD-052), más el ajuste del test preexistente "everything valid" para usar dos secrets distintos (ya no puede compartir el mismo `VALID_SECRET` para ambos, o dispara el chequeo nuevo).

**Validación:** de nuevo, `mongodb-memory-server` bloqueado en este entorno (ver más arriba) — no se pudo correr la suite de Jest completa. Se verificó la lógica pura de TD-051/TD-052 (sin BD) con un script `ts-node` suelto ejecutando `signAccessToken`/`verifyAccessToken`/`verifyRefreshToken` y `validateProductionEnv` directamente, y la de TD-053 comparando el tiempo de un `bcrypt.compare` contra el hash dummy frente a uno real (~80ms ambos). `npm run typecheck` y `npm run lint` pasan limpio. Validación de comportamiento vía HTTP (los tests de Supertest nuevos) queda en manos de CI.

**Decisión del dueño:** priorizar prevención de bugs silenciosos en futuras actualizaciones de dependencias.

---

## Próximas mejoras pendientes

- **IMPROVEMENTS.md mismo:** documentar decisiones de PDR faltantes (002, 003, 005) cuando se creen.
- **README.md update:** añadir mascota, papelera, Sentry, --dart-define, infra EU (pendiente).
- **backend/README.md:** falta por crear (setup + patrón controller/service/model).
- **CLAUDE.md, lista corta "Currently open TDs":** TD-002 y TD-015 llevan verificados como Resolved en `docs/TECH_DEBT.md` desde 2026-08-16 (código ya implementado antes de esa verificación) pero la lista corta espejo en CLAUDE.md nunca se actualizó — quedaron fuera del alcance cerrado de esta ronda (solo TD-016/TD-006), pero es una limpieza de una línea pendiente para la próxima sesión que toque CLAUDE.md.

---

## Configuración pendiente

Acciones manuales/externas conocidas, no automatizables desde una sesión de agente — requieren acceso a cuentas, hardware o consolas de terceros.

- **TD-049 — Firebase, configuración manual (requiere Mac/Xcode) — actualizado 2026-08-16:**
  - ✅ `google-services.json` y `GoogleService-Info.plist` ya copiados localmente por el dueño a `android/app/` e `ios/Runner/` (gitignored, confirmado con ambos patrones ya presentes en `frontend/.gitignore` antes de esta ronda).
  - ✅ Plugin `com.google.gms.google-services` aplicado en Gradle: `classpath` en `android/build.gradle` (buildscript) + `apply plugin` al final de `android/app/build.gradle`.
  - ✅ `android/app/src/main/AndroidManifest.xml` ya tenía `POST_NOTIFICATIONS` (añadido en una ronda anterior de TD-049 no reflejada aquí).
  - ✅ `ios/Runner/Info.plist`: `UIBackgroundModes` con `fetch` + `remote-notification` añadido.
  - ⏳ **Pendiente manual en Xcode:** capability "Push Notifications" (esto genera `Runner.entitlements` con `aps-environment` y referencia `CODE_SIGN_ENTITLEMENTS` en el pbxproj automáticamente) + "Background Modes → Remote notifications" ya cubierto por el Info.plist de arriba pero conviene confirmarlo también en la UI de Signing & Capabilities. Deliberadamente no se editó `project.pbxproj` a mano para crear el entitlements file — el riesgo de un pbxproj malformado sin poder verificarlo fuera de Xcode superaba el ahorro de 2 clicks. Pasos: Xcode → Runner target → Signing & Capabilities → "+ Capability" → "Push Notifications".
  - ⏳ APNs key subida a Firebase Console (Project Settings → Cloud Messaging → APNs Authentication Key).
  - ✅ `FIREBASE_SERVICE_ACCOUNT` ya configurado en Railway (confirmado por el dueño, fuera de esta ronda).
  - ⏳ Ejecutar `flutterfire configure` (opcional si los config files ya están colocados a mano, como aquí).
  - ⏳ Test end-to-end en dispositivo físico (push no se puede validar en simulador/emulador).
- **Self-leave endpoint (gap identificado en TD-018, ronda 2026-08-16):** hoy solo un admin puede remover a otro miembro vía `removeMember` (`DELETE /households/:id/members/:userId`). No existe ningún endpoint de autoservicio para que un miembro normal salga voluntariamente del hogar por su cuenta. Candidato razonable para un TD nuevo si el producto lo necesita — la lógica de desasignación de tareas de TD-018 (`unassignDepartedMemberTasks`) ya está lista para reutilizarse desde ese endpoint el día que se cree.

---

## Roadmap futuro

Funcionalidad identificada pero fuera de alcance de las rondas que la mencionaron.

- **Deep-link a tarea específica desde push notification (PDR-008):** hoy tocar una notificación que abrió la app desde background (`onMessageOpenedApp`) solo navega al shell principal (pestaña de tareas) — no existe todavía una ruta de deep-link por tarea, así que no abre la tarea exacta.
- **Background/terminated message handling para push notifications (PDR-008):** hoy `NotificationService` solo maneja foreground (banner local vía `showLocalNotification`) y background→foreground vía tap (`onMessageOpenedApp`). Falta `onBackgroundMessage`/`getInitialMessage` para el caso de mensaje recibido con la app en background o terminada.
- **Recordatorios de tareas próximas vía push (PDR-003):** PDR-003 lo menciona como "futuro" — requiere lógica de scheduling server-side (hoy los recordatorios de `flutter_local_notifications` son solo locales, calculados client-side a partir de `dueDate`/`startsAt`, sin contraparte de push server-driven).

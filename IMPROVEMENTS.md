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

### Hipótesis refutadas

- **2026-08-16 (TD-047):** "Home no muestra tareas hasta refresh" → resultó no ser un bug de load inicial; era combinación de dos bugs previos (timeline stale + creación 400). Documentado como "Resolved — hypothesis refuted" en docs/TECH_DEBT.md.
- **Lección:** antes de lanzar fix de hipótesis, verificar con evidencia de runtime (logs, status codes), no solo con análisis de código.

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

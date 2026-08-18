# AGENTS.md

HomeSync usa como fuente principal de contexto el archivo CLAUDE.md.

Cualquier agente que trabaje en este repositorio debe leer antes:

- [CLAUDE.md](CLAUDE.md)
- [docs/AGENT_FALLBACK.md](docs/AGENT_FALLBACK.md)
- [docs/PRODUCT_DECISIONS.md](docs/PRODUCT_DECISIONS.md)
- [docs/TECH_DEBT.md](docs/TECH_DEBT.md)
- [docs/ROADMAP.md](docs/ROADMAP.md)
- [docs/NEXT_SESSION_MAC.md](docs/NEXT_SESSION_MAC.md)

## Reglas críticas

1. No modificar TDs abiertos sin instrucción explícita.
2. Commits atómicos.
3. No añadir dependencias si no es imprescindible.
4. Mantener el estilo existente.
5. No hacer cambios fuera del alcance de la tarea.
6. Si cambia comportamiento de producto, documentar la decisión.
7. Durante el pilotaje de agentes secundarios, trabajar por rama y PR.
8. CI debe pasar antes de merge.
9. El dueño aprueba decisiones, push y merge.

## Flujo esperado

- Crear rama desde main.
- Hacer cambios mínimos.
- Generar commits atómicos.
- Abrir PR.
- Esperar CI verde.
- Esperar aprobación del dueño.

## Tareas aptas para agentes secundarios

- Bugs pequeños y localizados.
- Tests acotados.
- Documentación.
- Refactors mecánicos.
- Cambios de UI simples.
- Tareas con acceptance criteria claro.

## Tareas que requieren aprobación o Claude

- Arquitectura nueva.
- Refactors transversales.
- Cambios de producto no decididos.
- Modificación de TDs abiertos.
- Cambios en CI/CD.
- Cambios en secretos, despliegue o producción.
- Añadir dependencias nuevas.

---

# Convenciones del proyecto

Lo que sigue son las reglas y convenciones normativas del repositorio. Se reproducen
aquí **literalmente** (en inglés, tal y como están en `CLAUDE.md`) para que un agente que
solo lea `AGENTS.md` no pueda saltárselas por no haber abierto el manual completo. No
las reformules ni las traduzcas al editarlas: cualquier cambio debe aplicarse igual en
`CLAUDE.md` para que ambos archivos no diverjan.

Todo lo que NO está aquí (arquitectura detallada, ADRs, eventos de socket, Sentry, push
notifications, roadmap, registro de TDs, quick reference de archivos) vive en `CLAUDE.md`
y sigue siendo lectura obligatoria.

---

<!-- sync-start: hard-rules -->
## 🚫 Hard Rules (Never Break These)

1. NEVER store passwords in plain text or return them in responses
2. NEVER reveal whether an email exists in register/login error messages (this includes HTTP status codes: duplicate email on register MUST return 400 with the generic message, never 409 Conflict, because 409 confirms account existence)
3. NEVER trust client input — always validate and sanitize on the server
4. NEVER put business logic in controllers — always delegate to services
5. NEVER use `any` type in TypeScript unless there's no alternative
6. NEVER commit `.env` files or secrets to the repository
7. NEVER break the response envelope format `{ success, data?, error? }`
8. NEVER emit socket events without checking household membership first
9. NEVER delete a household's last admin
10. NEVER skip error handling — every async operation must have error handling
11. NEVER merge code without tests for new features
12. NEVER ignore a failing test — fix it or remove it with justification
13. NEVER allow write POSTs without idempotency protection: every POST that creates a resource MUST accept an `Idempotency-Key` header; backend MUST dedupe via Redis with a TTL; frontend MUST generate one stable UUID per logical operation (surviving 401 retries). On duplicate key detection the backend MUST return the original resource with HTTP 200 and MUST NOT re-emit socket events. (Enforced since the TD-014 commit; see middleware/idempotency.middleware.ts)
14. NEVER configure `express.json()` without a payload size limit (e.g. `limit: '100kb'`). (Enforced since the TD-015 commit; see app.ts's `express.json({ limit: '100kb' })`)
15. NEVER ship production with empty `CORS_ORIGINS`: when `NODE_ENV=production` it MUST be non-empty and the server MUST fail fast at startup otherwise; wildcard `*` is only acceptable in development. (Enforced since the TD-016 commit; see utils/env.ts's `validateProductionEnv`, called from server.ts)
16. NEVER leave orphaned references when a member leaves a household: their pending assigned tasks MUST be unassigned (removed from `assignedTo`), tasks they created MUST be preserved, and the UI MUST render "Ex-miembro" for a former assignee. (Enforced since the TD-018 commit; see household.service.ts's unassignDepartedMemberTasks and task_tile.dart's AvatarStack)
17. NEVER allow edit/delete of a task by anyone other than the creator or an admin; any member may complete tasks and purchase shopping items. (Enforced since the TD-011 commit; see tasks.test.ts permission tests)
18. NEVER render user-supplied text in any HTML-capable surface (future web client, email templates, push deep-links) without escaping at render time; mobile Text() widgets are safe by construction, storage stays raw per ADR-009
<!-- sync-end: hard-rules -->

---

## 🏗️ Layer Responsibilities

**Backend (Express + TypeScript, `backend/src/`):**
- **Controllers:** Parse request, validate params, call service, send response. NO business logic.
- **Services:** All business logic, database queries, socket emissions, validation rules.
- **Models:** Schema definitions, indexes, virtuals. NO business logic.
- **Middleware:** Auth verification, error handling, rate limiting.
- **Utils:** Pure functions, helpers, no side effects.

**Frontend (Flutter — Clean Architecture, `frontend/lib/`):**
- **Pages:** UI only, listen to Cubits, no business logic.
- **Cubits:** State management, orchestrate repositories, handle UI state.
- **Repositories:** Abstract data sources, handle caching strategy.
- **DataSources:** Raw API calls or local storage operations.
- **Models:** Immutable data classes with `fromJson`/`toJson`.
- **Services:** Cross-cutting concerns (socket, notifications).

---

<!-- sync-start: api-conventions -->
## 📋 API Conventions

### Response Envelope
Every endpoint responds with:

```
Success:  { "success": true, "data": { ... } }
Error:    { "success": false, "error": "Human-readable message" }
```

### Error Handling
- Use `AppError` class from `middleware/error.middleware.ts`
- Always throw, never return error responses manually
- Use `asyncHandler` wrapper for all async route handlers
- Centralized error middleware catches everything and formats response

### Naming Conventions
- **Files:** kebab-case (`task.service.ts`, `auth.middleware.ts`)
- **Classes/Interfaces:** PascalCase (`ITask`, `TaskModel`, `AppError`)
- **Functions/Variables:** camelCase (`createTask`, `householdId`)
- **Constants:** UPPER_SNAKE_CASE (`JWT_SECRET`, `POPULATE_FIELDS`)
- **Database collections:** plural lowercase (`users`, `households`, `tasks`)

### TypeScript Rules
- `strict: true` in tsconfig — no `any` unless absolutely necessary
- Use `unknown` instead of `any` for unknown types
- All function params and return types must be typed
- Use `AppError` for expected errors, let unexpected errors bubble to error middleware
- Prefer `const` over `let`, never use `var`

### Dart/Flutter Rules
- All models must be immutable (`final` fields)
- Use `equatable` for all Cubit states
- Use `copyWith` pattern for state updates
- No business logic in widgets — delegate to Cubits
- All async operations in Cubits must handle errors explicitly
<!-- sync-end: api-conventions -->

---

<!-- sync-start: database-models -->
## 🗄️ Database Models

Tables below mirror `backend/src/models/*.ts` field by field. All five schemas use
`{ timestamps: true }` (adding `createdAt` / `updatedAt`) unless noted, and all except
RefreshToken spread `jsonSchemaOptions` from `utils/toJSON.ts`, which exposes a virtual
`id`, drops `_id` and `__v`, and strips any `password` that leaked into a document.

### User (`users`)
| Field | Type | Notes |
|-------|------|-------|
| email | String | required, unique, lowercase, trim, indexed |
| password | String | required, minlength 6, `select: false` (bcrypt hash, never returned) |
| name | String | required, trim |
| avatarUrl | String | optional |
| households | ObjectId[] | ref Household |
| createdAt / updatedAt | Date | from `timestamps: true` |

### Household (`households`)
| Field | Type | Notes |
|-------|------|-------|
| name | String | required, trim |
| inviteCode | String | required, unique, uppercase, exactly 8 chars (min/maxlength 8), indexed |
| members | IHouseholdMember[] | embedded subdocument array, default `[]` |
| createdBy | ObjectId | ref User, required |
| createdAt / updatedAt | Date | from `timestamps: true` |

**Embedded `IHouseholdMember`** (`_id: false`):
| Field | Type | Notes |
|-------|------|-------|
| user | ObjectId | ref User, required |
| role | Enum | `admin` / `member`, default `member` |
| joinedAt | Date | default `Date.now` |

### Task (`tasks`)
| Field | Type | Notes |
|-------|------|-------|
| householdId | ObjectId | ref Household, required, indexed |
| title | String | required, trim |
| description | String | optional |
| assignedTo | ObjectId[] | ref User |
| createdBy | ObjectId | ref User, required |
| status | Enum | `pending` / `completed`, default `pending`, indexed |
| priority | Enum | `low` / `medium` / `high`, default `medium` |
| category | Enum | `cleaning` / `cooking` / `shopping` / `maintenance` / `other`, default `other` |
| dueDate | Date | optional |
| completedAt | Date | set on completion |
| completedBy | ObjectId | ref User, set on completion |
| isRecurring | Boolean | default false |
| recurrenceRule | IRecurrenceRule | embedded subdocument, default `undefined` |
| parentTaskId | ObjectId | ref Task, default `null`, indexed — links generated occurrences to their series |
| isDeleted | Boolean | default `false`, indexed — soft delete (TD-046); DELETE sets this instead of removing the document |
| deletedAt | Date | set when `isDeleted` is set true, cleared on restore |
| createdAt / updatedAt | Date | from `timestamps: true` |

**Embedded `IRecurrenceRule`** (`_id: false`):
| Field | Type | Notes |
|-------|------|-------|
| type | Enum | `daily` / `weekly` / `monthly` / `custom` |
| interval | Number | default 1 |
| daysOfWeek | Number[] | each 0–6 (0 = Sunday), default `undefined` |
| dayOfMonth | Number | 1–31 |

**Indexes:** `{ householdId: 1, status: 1, dueDate: 1 }` (compound), plus the single-field
indexes on `householdId`, `status`, `parentTaskId` and `isDeleted` (TD-046).

### ShoppingItem (`shoppingitems`)
| Field | Type | Notes |
|-------|------|-------|
| householdId | ObjectId | ref Household, required, indexed |
| name | String | required, trim |
| quantity | Number | default 1, min 0 |
| unit | String | default `'uds'` |
| category | Enum | `fridge` / `pantry` / `cleaning` / `personal` / `other`, default `other` |
| isPurchased | Boolean | default false, indexed — **note: `isPurchased`, not `purchased`** |
| purchasedAt | Date | set on purchase |
| purchasedBy | ObjectId | ref User, set on purchase |
| addedBy | ObjectId | ref User, required — **note: `addedBy`, not `createdBy`** |
| isRecurring | Boolean | default false |
| recurrenceIntervalDays | Number | optional |
| lastAddedAt | Date | optional in the schema; set to now by `createItem` |
| estimatedPrice | Number | optional |
| createdAt / updatedAt | Date | from `timestamps: true` |

**Indexes:** `{ householdId: 1, isPurchased: 1, createdAt: -1 }` (compound), plus the
single-field indexes on `householdId` and `isPurchased`.

### RefreshToken (`refreshtokens`)
| Field | Type | Notes |
|-------|------|-------|
| token | String | required, unique, indexed — stores `sha256(jwt)` as 64-char hex, never the raw JWT (TD-023) |
| userId | ObjectId | ref User, required, indexed |
| expiresAt | Date | required; TTL index (`expireAfterSeconds: 0`) purges expired rows |
| createdAt | Date | `timestamps: { createdAt: true, updatedAt: false }` — no `updatedAt` |

Does **not** apply `jsonSchemaOptions`: these documents are internal and never serialized
to clients.
<!-- sync-end: database-models -->

---

<!-- sync-start: testing-standards -->
## 🧪 Testing Standards

Testing stack installed: Jest + Supertest + mongodb-memory-server (backend); flutter_test + bloc_test (frontend). CI runs the full suite on every PR — 298 backend tests (20 suites) and 249 frontend tests, all in ONE blocking step: the `test/widgets/offline_banner_test.dart` allow-failure carve-out was removed on 2026-08-17 once TD-040 was root-caused and fixed.

- **Backend:** Jest + Supertest for integration tests
- **Frontend:** `flutter_test` for widget tests, `bloc_test` for Cubit tests
- **Test files:** `*.test.ts` in `backend/src/tests/`, `*_test.dart` in `frontend/test/`
- **Database:** Use `mongodb-memory-server` for isolated backend tests
- **Coverage target:** 80%+ on services and controllers, 70%+ on Cubits
- **Test naming:** `describe('endpoint or function', () => { it('should do X when Y', ...) })`
- **Every test must be independent** — clean state before/after each test
- **No test should depend on external services** (no real MongoDB, no real Redis)
- **AAA pattern:** Arrange → Act → Assert in every test

**Required high-value test scenarios (cover first):**
1. Refresh token rotation under concurrency (backend rotation + frontend single-flight pattern)
2. Recurrence anti-duplicate guard (±1 day window)
3. Never delete the household's last admin
4. Idempotency of write operations under retry (401 refresh retry, socket reconnect)
5. Member-leave lifecycle (unassign pending tasks on leave/removal, preserve created tasks, last-admin protection) — covered by households.test.ts (TD-018 resolved).
6. Widget rendering of offline/sync states (TaskTile unsynced/deleted, offline banner with pending count)
<!-- sync-end: testing-standards -->

---

<!-- sync-start: git-workflow -->
## 🌿 Git Workflow

- **Branch naming:** `feat/description`, `fix/description`, `chore/description`, `refactor/description`
- **Commit messages:** Use conventional commits:
  - `feat(backend): add pagination to tasks endpoint`
  - `fix(frontend): fix socket reconnection on token refresh`
  - `refactor(backend): extract membership check to helper`
  - `chore: update dependencies`
- NEVER use bulk git add on frontend/ or frontend/lib; always explicit file paths — avoids accidentally sweeping in generated/build artifacts or the uncommitted local override on `project.pbxproj`. `frontend/lib/config/constants.dart` no longer carries a local override (TD-017 resolved via `--dart-define`)
- **PR requirements:**
  - All tests pass
  - TypeScript typecheck passes (`npm run typecheck`)
  - Flutter analyze passes (`flutter analyze`)
  - No `console.log` in production code (use logger)
  - Update Swagger docs if API changes
  - Update README if setup process changes
  - Include "💡 Proposed Improvements" section in PR description

### Local-only configuration (NEVER commit)

One file carries a local override that must NEVER be committed:
- `ios/Runner.xcodeproj/project.pbxproj`: Bundle Identifier changed to avoid Personal Team conflicts

This file is protected with `git update-index --assume-unchanged`. To verify:
```bash
git ls-files -v | grep '^h'
```
Should show only `project.pbxproj` with a lowercase 'h' prefix (assume-unchanged flag). `frontend/lib/config/constants.dart` no longer needs this protection — it reads its config via `--dart-define` instead of a hardcoded local value (TD-017).

To temporarily allow commits (rare, only for legitimate changes):
```bash
git update-index --no-assume-unchanged <file>
<!-- sync-end: git-workflow -->
# make change, commit
git update-index --assume-unchanged <file>
```

---

<!-- sync-start: local-dev-setup -->
## 🏃 Local Development Setup

### Backend
```bash
cd backend
npm install
cp .env.example .env    # Fill in MONGODB_URI, JWT secrets, REDIS_URL
npm run dev             # Starts on http://localhost:3000
```

### Frontend
```bash
cd frontend
flutter create --org com.homesync --project-name homesync .  # Generate native scaffolding
flutter pub get
flutter run
```

**Backend URL config** in `frontend/lib/config/constants.dart` — `API_BASE_URL` defaults to the production Railway backend; `flutter run` with no flags talks to production, not to a local server. Local development requires an explicit `--dart-define=API_BASE_URL=...` override:
- Android emulator: `http://10.0.2.2:3000`
- iOS simulator: `http://localhost:3000`
- Physical device: `http://<your-LAN-IP>:3000`

### Seed Data
```bash
cd backend
npx ts-node src/scripts/seed.ts
<!-- sync-end: local-dev-setup -->
# Creates: user test@test.com / password123, household "Casa de prueba" (code CASADEMO)
```

### API Documentation
Swagger UI available at: `http://localhost:3000/api/docs`

---

<!-- sync-start: frontend-theme -->
## 🎨 Frontend Theme

- **Primary:** Indigo `#6366F1`
- **Secondary:** Violet `#8B5CF6`
- **Background:** Slate-50 `#F8FAFC`
- **Design system:** Material 3
- **Font:** Inter (via `google_fonts`)
- **Language:** Spanish UI labels, date formatting with `intl` package
<!-- sync-end: frontend-theme -->

---

## 🔍 Continuous Improvement Protocol

On EVERY code change, the AI assistant MUST include a section called "💡 Proposed Improvements" at the end of the response, listing:

1. **Technical debt identified:** Any shortcuts or suboptimal patterns found
2. **Refactoring opportunities:** Code that could be restructured for better quality
3. **Missing edge cases:** Scenarios not currently handled
4. **Performance concerns:** Potential bottlenecks or inefficiencies
5. **Security hardening:** Additional security measures that could be applied
6. **Test gaps:** Scenarios that should be tested but aren't

These proposals don't need to be implemented immediately, but they MUST be documented. Track them in the Technical Debt Registry (`docs/TECH_DEBT.md`).

---

<!-- sync-start: working-with-ai -->
## 🤖 Working with AI Assistants

When generating code for this project:

1. **Always follow existing patterns** — check how similar features are implemented before writing new code
2. **Use the response envelope** — `{ success, data?, error? }` for all API responses
3. **Emit socket events** — after any create/update/delete operation that affects household data
4. **Check membership** — verify user belongs to household before any household-scoped operation
5. **Handle errors gracefully** — use `AppError` for expected errors, let unexpected ones bubble
6. **Write typed code** — no `any`, all params and returns typed
7. **Add JSDoc comments** — for all exported functions and classes
8. **Update Swagger docs** — if adding/modifying API endpoints
9. **Consider realtime** — any data change should propagate to connected clients
10. **Test your changes** — verify existing tests still pass
11. **Propose improvements** — always include "💡 Proposed Improvements" section
12. **Think in production** — consider security, performance, scalability, observability
<!-- sync-end: working-with-ai -->

---

## 🗂️ Decisión sobre AGENTS.legacy.md (2026-08-17)

`AGENTS.legacy.md` era el manual completo del proyecto (761 líneas) que quedó fuera de
seguimiento al reducirse `AGENTS.md` en el PR #32.

**Verificación:** su contenido resultó ser **byte a byte idéntico a `CLAUDE.md`**, salvo
por la sustitución del literal `CLAUDE.md` por `AGENTS.md` en las autorreferencias
(comprobado con `sed 's/AGENTS\.md/CLAUDE.md/g' AGENTS.legacy.md | diff - CLAUDE.md`, sin
diferencias). No era, por tanto, un documento con contenido propio: era una copia previa
del mismo manual.

**Decisión:** eliminado, no renombrado a `AGENTS.full.md`. Un tercer archivo con el mismo
texto solo añade superficie de desincronización, y `CLAUDE.md` —que está versionado y es
la fuente canónica— ya conserva el 100% de su contenido. Las secciones normativas que un
agente necesita para no romper nada (Hard Rules, convenciones de TypeScript/Dart, modelos
de BD, Testing Standards, Git Workflow, seed data) se copiaron literalmente a este archivo
en el commit que acompaña a esta nota.

**Coste asumido:** esas secciones existen ahora en dos sitios (`AGENTS.md` y `CLAUDE.md`)
y pueden divergir. Se aceptó a cambio de que un agente que solo lea `AGENTS.md` no opere
sin las reglas duras. Mitigación pendiente: el check de CI propuesto en `IMPROVEMENTS.md`
(2026-08-17) puede extenderse para comparar ambos bloques y fallar si divergen.

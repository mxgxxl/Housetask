# HomeSync — Project Guide for AI Coding Assistants

## 🎯 Project Overview

**HomeSync** is a real-time household organization mobile app for couples and families. Users create a "household", invite members via invite code, assign tasks, manage a shared shopping list, and see changes sync live across all connected devices.

**Current status:** MVP built in 2 days. Foundation is solid but needs hardening for production. We are now in the stabilization and scaling phase.

---

## 🏆 Development Philosophy

This project aims for **professional, production-grade quality**. All AI assistants working on this codebase MUST follow these principles:

1. **Quality over speed:** If a solution takes longer but produces better technical quality (better architecture, more tests, better error handling, better scalability), choose that solution. Do not optimize for "quick and dirty".

2. **Propose improvements:** On every code pass, the assistant MUST identify and propose at least one technical improvement beyond what was explicitly requested. This can be:
   - A refactor that improves readability or maintainability
   - A missing edge case that should be handled
   - A performance optimization
   - A security hardening opportunity
   - A test that should be added
   - A better architectural pattern

3. **Challenge the status quo:** If existing code can be restructured for better quality, propose the restructuring. Do not blindly follow existing patterns if they are suboptimal.

4. **No technical debt:** Avoid shortcuts that create future problems. If a shortcut is necessary due to time constraints, document it explicitly with a `// TODO(tech-debt):` comment and explain the proper solution.

5. **Think in production:** Every feature must consider: error handling, edge cases, security, performance, scalability, observability, and rollback strategy.

6. **Document decisions:** When making architectural choices, explain WHY in code comments or in this file's Architecture Decision Records section.

---

## 🏗️ Architecture

This is a **monorepo** with two main components:

```
/
├── backend/          → Node.js REST + realtime API
├── frontend/         → Flutter mobile app (iOS/Android)
├── railway.toml      → Deployment config
├── CLAUDE.md         → This file — AI assistant guide
└── README.md         → Project overview
```

### Backend Architecture (Express + TypeScript)

```
backend/src/
├── config/           → database.ts, redis.ts, socket.ts
├── models/           → Mongoose schemas (User, Household, Task, ShoppingItem, RefreshToken)
├── controllers/      → Thin HTTP handlers, delegate to services
├── services/         → Business logic, database operations, socket emissions
├── middleware/       → auth.middleware.ts, error.middleware.ts
├── routes/           → Express route definitions
├── types/            → TypeScript interfaces and type definitions
├── utils/            → jwt.ts, response.ts, logger.ts, asyncHandler.ts, toJSON.ts
├── scripts/          → seed.ts (demo data)
└── app.ts            → Entry point
```

**Layer responsibilities:**
- **Controllers:** Parse request, validate params, call service, send response. NO business logic.
- **Services:** All business logic, database queries, socket emissions, validation rules.
- **Models:** Schema definitions, indexes, virtuals. NO business logic.
- **Middleware:** Auth verification, error handling, rate limiting.
- **Utils:** Pure functions, helpers, no side effects.

### Frontend Architecture (Flutter — Clean Architecture)

```
frontend/lib/
├── main.dart / app.dart       → Entry point + DI composition root
├── config/                    → constants.dart, theme.dart, routes.dart
├── core/                      → errors (failures), utils (UI helpers)
├── data/
│   ├── models/                → User, Member, Household, Task, RecurrenceRule, ShoppingItem
│   ├── datasources/
│   │   ├── local/             → SharedPreferences (tokens, user, household)
│   │   └── remote/            → ApiService (Dio + auth/refresh interceptors)
│   └── repositories/          → auth, household, task, shopping
├── presentation/
│   ├── cubit/                 → AuthCubit, HouseholdCubit, TaskCubit, ShoppingCubit, SocketCubit
│   ├── pages/                 → splash, login, register, main shell, home, tasks, calendar, shopping, profile
│   └── widgets/               → user avatar, task tile, common components
└── services/                  → socket_service.dart, notification_service.dart
```

**Layer responsibilities:**
- **Pages:** UI only, listen to Cubits, no business logic.
- **Cubits:** State management, orchestrate repositories, handle UI state.
- **Repositories:** Abstract data sources, handle caching strategy.
- **DataSources:** Raw API calls or local storage operations.
- **Models:** Immutable data classes with `fromJson`/`toJson`.
- **Services:** Cross-cutting concerns (socket, notifications).

---

## 📐 Architecture Decision Records (ADRs)

Detailed ADRs live in docs/ADRs.md. Index:

- [ADR-001: Monorepo structure](docs/ADRs.md#adr-001)
- [ADR-002: Socket.io with Redis adapter](docs/ADRs.md#adr-002)
- [ADR-003: Cubits over Blocs in Flutter](docs/ADRs.md#adr-003)
- [ADR-004: JWT with refresh token rotation](docs/ADRs.md#adr-004)
- [ADR-005: Embedded members in Household (TO BE MIGRATED)](docs/ADRs.md#adr-005)
- [ADR-006: Timezone strategy for dates and recurrence](docs/ADRs.md#adr-006)
- [ADR-007: Idempotency-Key semantics](docs/ADRs.md#adr-007)
- [ADR-008: Forward-only cursor pagination](docs/ADRs.md#adr-008)
- [ADR-009: Edge validation, raw storage, escape at render](docs/ADRs.md#adr-009)
- [ADR-010: Offline-first with last-write-wins](docs/ADRs.md#adr-010)

---

## 🛠️ Tech Stack

### Backend
| Technology | Purpose |
|------------|---------|
| Node.js 20 | Runtime |
| Express | HTTP framework |
| TypeScript (strict) | Type safety |
| MongoDB + Mongoose | Database |
| Redis + ioredis | Pub/Sub for Socket.io scaling |
| Socket.io + Redis adapter | Realtime communication |
| JWT + bcrypt | Authentication |
| express-rate-limit | Rate limiting |
| Swagger (swagger-ui-express) | API documentation at `/api/docs` |
| firebase-admin | Push notifications (FCM) — sends via `notification.service.ts`, no-op when `FIREBASE_SERVICE_ACCOUNT` is unset (PDR-008) |

### Frontend
| Technology | Purpose |
|------------|---------|
| Flutter 3.27+ / Dart 3.6+ | Cross-platform mobile |
| flutter_bloc (Cubits) | State management |
| equatable | Value equality for states |
| Dio | HTTP client with interceptors |
| socket_io_client | Realtime communication |
| shared_preferences | Local token storage |
| table_calendar | Calendar view |
| flutter_local_notifications | Local task reminders |
| google_fonts (Inter) | Typography |
| flutter_slidable | Swipe actions on list items |
| firebase_core, firebase_messaging | Push notifications (FCM) — `NotificationService`, no-op-safe until a real Firebase project is wired up (TD-049, PDR-008) |

### Deployment
| Service | Purpose |
|---------|---------|
| Railway | Backend hosting (Docker) |
| MongoDB Atlas | Production database |
| Redis Cloud | Production Redis |

---

## 🔐 Authentication Flow

1. **Register/Login** → returns `accessToken` (15 min) + `refreshToken` (7 days)
2. **Access token** sent as `Authorization: Bearer <token>` header
3. **Refresh token** stored SHA-256 hashed in the refreshtokens collection (rotated on use, deleted on logout); a DB leak never yields usable sessions
4. **Frontend** auto-refreshes on 401 with single-flight pattern (deduplicates concurrent refresh calls)
5. **If refresh fails** → force logout via `onSessionExpired` callback

**Security rules:**
- Passwords hashed with bcrypt, never returned in responses
- Failed login/register return generic message (never reveal if email exists)
- Credential endpoints rate-limited: 5 requests / 15 min / IP
- Every other `/api/*` route is additionally rate-limited globally: 100 requests / 15 min / IP (`app.ts`'s `buildGlobalLimiter`, TD-006), `/api/auth/*` exempted from this counter (it already has the stricter limiter above) via a `skip` on `req.originalUrl` — a request there is never double-limited
- Password field has `select: false` in Mongoose schema
- Replay detection revokes the full token family on two triggers: valid signature + missing row, OR stored userId mismatch with the JWT payload; every family revocation emits a security log (`logger.warn` with userId) as the audit hook for Sentry (TD-009)
- Production boot fails fast (`utils/env.ts`'s `validateProductionEnv`, called from `server.ts` before anything binds) when `CORS_ORIGINS` is empty, `MONGODB_URI` is unset, or either JWT secret is under 32 characters (TD-016) — a misconfigured production process crashing visibly beats it silently degrading `CORS_ORIGINS` to `*` or running with a forgeable JWT secret

---

## 📡 Realtime (Socket.io)

**Connection:** `io(url, { auth: { token } })` — authenticates with JWT access token.

**Rooms:** Each household has a room `household_<id>`. Users join on connect and can rejoin via `household:join` event.

**Server → Client events:**
| Event | Payload | Trigger |
|-------|---------|---------|
| `task:created` | Task object | New task created |
| `task:updated` | Task object | Task fields modified |
| `task:completed` | Task object | Task marked complete |
| `task:deleted` | `{ id, householdId }` | Task hard-deleted |
| `shopping:created` | ShoppingItem | New item added |
| `shopping:updated` | ShoppingItem | Item modified |
| `shopping:purchased` | ShoppingItem | Item marked purchased |
| `shopping:deleted` | `{ id, householdId }` | Item removed |
| `household:member_joined` | Member + Household | User joined household |
| `household:member_left` | Member + Household | User left/removed |
| `tasks:batch_created` | `{ tasks[], count }` | Recurring catch-up generation |
| `tasks:purged` | `{ householdId, deleted }` | Admin purges the trash (TD-048); only emitted when `deleted > 0` |
| `pet:adopt_requested` | AdoptionRequest: `{ id, householdId, species, name, requestedBy, status: 'pending', createdAt, updatedAt }` | 2+ member household proposes an adoption (PDR-001) |
| `pet:adopted` | Pet: `{ id, householdId, species, name, adoptedAt, adoptedBy, hunger, mood, lastFedAt, lastPlayedAt, cosmetics, activeCosmetic, createdAt, updatedAt }` (hunger/mood decayed to now) | A DIFFERENT member confirms a pending adoption, OR a single-member household adopts instantly on propose (no confirmation step — PDR-001) |
| `pet:adopt_cancelled` | `{ householdId }` | Pending adoption request cancelled by its requester or a household admin |
| `pet:updated` | Pet (same shape as `pet:adopted`) | Pet fed, played with, a cosmetic bought, or the active cosmetic changed |

**Client → Server events:**
| Event | Payload | Purpose |
|-------|---------|---------|
| `household:join` | householdId | Join room without reconnecting |
| `household:leave` | householdId | Leave room |

---

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

---

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

---

## 🔄 Recurring Tasks System

- When a recurring task is completed, the next occurrence is auto-generated
- **Anti-duplicate guard:** checks if pending task with same title exists within ±1 day of next due date
- **Catch-up endpoint:** `POST /tasks/generate-instances` generates missed occurrences (max 52 iterations per series)
- **parentTaskId** links generated instances back to the original series
- Recurrence types: `daily`, `weekly`, `monthly`, `custom`
- Frontend calls catch-up automatically when entering a household
- **Batch payload limit:** `tasks:batch_created` MUST be emitted in chunks of at most 20 tasks per event (multiple events if a catch-up exceeds 20) to keep socket payloads small

---

## ⚡ Performance Patterns

- **Membership cache:** `assertMembership` runs on every household-scoped operation. To avoid one MongoDB query per request, cache membership in Redis with a short TTL (e.g. 60s), key `membership:<householdId>:<userId>`. Invalidate on `household:member_joined` / `household:member_left` events.
- **Populate strategy:** prefer a single `.populate()` call with an array of paths over multiple sequential populate calls.
- **List endpoints:** always paginated (cursor-based). Never return unbounded collections.
- **Cache bypass for destructive ops:** the membership cache (TTL 60s) MUST NOT be used for destructive or authorization-critical operations (delete household, remove member, change role, last-admin checks). Those MUST query MongoDB directly so a removed member never retains authorization for up to 60s.
- **Single membership checkpoint:** the requireMembership middleware on nested household routers is the only membership verification for HTTP operations, and the designated point where the Redis membership cache (TTL 60s) and the destructive-op bypass will be plugged in Phase 2.

---

## 🧪 Testing Standards

Testing stack installed: Jest + Supertest + mongodb-memory-server (backend); flutter_test + bloc_test (frontend). CI runs the full suite on every PR — 298 backend tests (20 suites), 216 frontend tests in the main blocking step, plus `test/widgets/offline_banner_test.dart` run separately with allow-failure (TD-040).

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

---

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

---

## 🔍 Continuous Improvement Protocol

On EVERY code change, the AI assistant MUST include a section called "💡 Proposed Improvements" at the end of the response, listing:

1. **Technical debt identified:** Any shortcuts or suboptimal patterns found
2. **Refactoring opportunities:** Code that could be restructured for better quality
3. **Missing edge cases:** Scenarios not currently handled
4. **Performance concerns:** Potential bottlenecks or inefficiencies
5. **Security hardening:** Additional security measures that could be applied
6. **Test gaps:** Scenarios that should be tested but aren't

These proposals don't need to be implemented immediately, but they MUST be documented. Track them in the "Technical Debt Registry" section below.

---

## 📝 Technical Debt Registry

The full registry (~47 entries, all history) lives in [Full Technical Debt Registry](docs/TECH_DEBT.md). Below is a short list of TDs that are NOT yet Resolved.

**Currently open TDs**

| ID | Description | Severity | Status |
|----|-------------|----------|--------|
| TD-001 | Members embedded in Household document | High | Planned (Phase 2) |
| TD-007 | No optimistic updates in frontend | Medium | Planned (Phase 2) |
| TD-010 | No database backups | Medium | Planned (Phase 3) |
| TD-013 | Recurrence computed in UTC without household timezone | Medium | Planned (Phase 2) |
| TD-034 | No deploy-order safety net between backend and Flutter app | Medium | Planned (Phase 3) |
| TD-039 | Offline conflict resolution uses last-write-wins; concurrent edits on multiple devices can overwrite | Low | Deferred (Phase 2) |
| TD-040 | flutter test hangs on loaded hosts (offline_banner_test.dart) | Low | Mitigated in CI; root cause still open |
| TD-049 | No real Firebase project connected for push notifications (PDR-008) — code is in place, no push actually delivers until a Firebase project + `flutterfire configure` + APNs key are set up manually | High | Planned (before beta push notifications can work) |

---

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
# make change, commit
git update-index --assume-unchanged <file>
```

---

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
# Creates: user test@test.com / password123, household "Casa de prueba" (code CASADEMO)
```

### API Documentation
Swagger UI available at: `http://localhost:3000/api/docs`

---

## 📦 Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| PORT | HTTP port (default 3000) | No |
| MONGODB_URI | MongoDB connection string | Yes |
| JWT_SECRET | Access token signing secret (≥32 chars) | Yes |
| JWT_REFRESH_SECRET | Refresh token signing secret (≥32 chars) | Yes |
| JWT_ACCESS_EXPIRES | Access token lifetime (default 15m) | No |
| JWT_REFRESH_EXPIRES | Refresh token lifetime (default 7d) | No |
| REDIS_URL | Redis connection URL | Yes |
| REDIS_COMMAND_TIMEOUT_MS | Timeout in ms for application Redis commands (default 2500; pub/sub connections are not affected) | No |
| SENTRY_DSN | Sentry error tracking DSN; empty or absent disables Sentry (no-op) | No |
| CORS_ORIGINS | Comma-separated allowed origins (empty = allow *) | No |
| NODE_ENV | development / production | No |

---

## 🔔 Sentry Error Tracking & Alerts (TD-037)

Backend and frontend both report through the no-op-when-no-DSN pattern (SENTRY_DSN above). Every `captureServerError` call on the backend carries **structured tags** — indexed by Sentry, unlike free-form `extra` context, so they're what dashboard alert rules and issue filtering actually key off:

| Tag | Meaning | Present when |
|-----|---------|---------------|
| `category` | Which hardened call site reported the error: `http_5xx`, `mongo_connection`, `socket_auth`, `socket_room`, or `economy_grant` | Always |
| `route` | Express route path | `http_5xx` only |
| `userId` | Authenticated user id | Known at the call site (e.g. not yet known on a failed socket handshake auth) |
| `householdId` | Household id | Known at the call site (household-scoped HTTP routes/socket rooms) |

Backend call sites: `middleware/error.middleware.ts` (the 5xx catch-all), `config/database.ts` (Mongo connection `error` event), `config/socket.ts` (handshake auth failure, `joinRoomSafely`/`leaveRoomSafely`), `services/economy.service.ts` (`grantCoins`'s unexpected-error path only — a duplicate-key or daily-cap outcome is expected, not reported).

Frontend breadcrumbs (`SentryService.addBreadcrumb`, categories `auth`/`task`/`pet`) mark key flows — login, task completion, pet adopt/confirm/feed/play/cosmetic-buy — in the timeline attached to whatever error Sentry captures next, even when the flow itself succeeded.

**Configuring alerts** (Sentry dashboard, not code — there is no alert-as-code API in use here): Project Settings → Alerts → Create Alert Rule, filtering on the tags above.

1. **Mongo connection instability** — condition: `category` equals `mongo_connection`; action: notify when count > 3 in 5 minutes. A single blip is Mongoose retrying; a burst means the database is genuinely unreachable.
2. **Socket auth failure spike** — condition: `category` equals `socket_auth`; action: notify when count > 20 in 15 minutes. Some background rate is normal (an access token expiring mid-session before the client refreshes and reconnects); a spike suggests a client-side token-refresh regression — a stolen/replayed *refresh* token is a different signal, already covered by `captureSecurityWarning` (see Authentication Flow).
3. **5xx on a household-scoped route** — condition: `category` equals `http_5xx` AND `route` contains `/households/`; action: notify on any occurrence. This is the app's core surface; a 5xx there is never expected, unlike a best-effort background failure.

`userId`/`householdId` are deliberately not alert *conditions* (too high-cardinality — one rule per household doesn't scale) but are useful for triaging an already-fired alert: search Sentry issues by `userId:<id>` to see everything one user hit.

---

## 📲 Push Notifications (FCM, PDR-008)

**Backend:** `notification.service.ts` initializes Firebase Admin lazily from `FIREBASE_SERVICE_ACCOUNT` (a JSON string env var, never a committed file) — same no-op-when-unconfigured pattern as Sentry (TD-009): absent or malformed JSON disables sending without breaking anything else. `sendPushNotification(userId, title, body, data?)` looks up every `DeviceToken` for the user and sends a multicast via `sendEachForMulticast`; a token FCM reports as `messaging/registration-token-not-registered` is deleted automatically.

**Device endpoints** (`/api/devices`, JWT-authenticated, not household-scoped — a token belongs to a user, who may be in several households):

| Method | Path | Body | Notes |
|--------|------|------|-------|
| POST | `/api/devices/register` | `{ token, platform: 'ios'\|'android' }` | Upsert on `{userId, token}`; if `token` already belonged to a different user (shared device) it is transferred. Idempotency-Key protected (Hard Rule 13). |
| DELETE | `/api/devices/:token` | — | Removes the caller's own token; idempotent no-op if it doesn't exist or belongs to someone else. |

**Triggers**, both in `task.service.ts`, both fire-and-forget (try/catch around the send call — a notification failure must never fail the task write, same pattern as `grantCoins`):

- `createTask`: pushes every assignee other than whoever created the task ("Nueva tarea asignada").
- `completeTask`: pushes the task's creator when someone else completes it ("Tarea completada").

**Frontend:** `NotificationService` (already existed for local task reminders) gained `requestPermission()`, `getToken()`, `registerToken()`, `listenForTokenRefresh()`, and `showLocalNotification()` — the last one is what makes a foreground push visible, since FCM does not show a system banner while the app is open. `AuthCubit` calls `initPushNotifications()` after authenticating and `unregisterToken()` on logout, before the session is cleared (the DELETE call needs a valid access token). Tapping a notification that opened the app from the background (`onMessageOpenedApp`) navigates to the main shell via `Routes.navigatorKey` — there is no per-task deep-link route yet, so it does not open the specific task.

**TD-049 (open):** this repo ships no real Firebase project — no `google-services.json`/`GoogleService-Info.plist`, and the `com.google.gms.google-services` Gradle plugin is deliberately not applied (it would hard-fail the Android build without that json file present). Every FCM call on both sides degrades to a caught, logged no-op until a real Firebase project is connected (`flutterfire configure`, or the two config files placed manually, plus the Xcode Push Notifications + Background Modes capability with an uploaded APNs key for iOS) — a manual/external step, not automatable here. Local task reminders (`flutter_local_notifications`) are unaffected either way.

---

## 🎨 Frontend Theme

- **Primary:** Indigo `#6366F1`
- **Secondary:** Violet `#8B5CF6`
- **Background:** Slate-50 `#F8FAFC`
- **Design system:** Material 3
- **Font:** Inter (via `google_fonts`)
- **Language:** Spanish UI labels, date formatting with `intl` package

---

## 🚀 Deployment

### Backend (Railway)
- Multi-stage Dockerfile in `backend/Dockerfile` (Node 20-alpine)
- `railway.toml` configured for Docker builder
- Start command: `node backend/dist/server.js`
- Set all environment variables in Railway dashboard

### Deployment order (MANDATORY after TD-027)
The paginated envelope (commit 9f9f629 backend / 597515e frontend) is a breaking change between the two halves of the monorepo. Deploy order MUST be:
1. Deploy backend (Railway picks up the new startCommand).
2. During the deploy window, run `npm run migrate:refresh-tokens` once (TD-024 one-time wipe).
3. Release the Flutter app to the stores.
Publishing the app first would make every list break for users until the backend catches up.

### Frontend
- Android: applicationId `com.homesync.app`, minSdkVersion 23 (PDR-005)
- iOS: Bundle ID `com.homesync.app`
- Build with: `flutter build apk --release` / `flutter build ios --release`

---

## 🌍 Environments

Frontend uses `String.fromEnvironment()` for configuration (TD-017), read in `frontend/lib/config/constants.dart`:
- `API_BASE_URL`: backend host, no path suffix (default: `https://housetask-production.up.railway.app` — production; local development requires an explicit `--dart-define=API_BASE_URL=http://localhost:3000` override)
- `ENVIRONMENT`: `development` / `production` flag (default: `development`)
- `SENTRY_DSN`: error tracking, independent define read directly in `services/sentry_service.dart` — see that file's doc comment for why it is deliberately not part of `AppConfig` (default: empty, no-op)

Set via `--dart-define=KEY=value` flags on `flutter run` / `flutter build`. See `frontend/README.md` for the full commands. `constants.dart` needs no machine-local edits and carries no `--assume-unchanged` protection.

---

## 🔄 CI/CD

Two separate systems, deliberately not coupled by a branch-protection gate (see TD-034):

- **Railway = continuous deployment.** Auto-deploys on every push to `main`, independent of GitHub Actions' outcome — see "Deployment" above.
- **GitHub Actions (`.github/workflows/ci.yml`) = continuous integration.** Verifies a push/PR; it does not deploy anything itself.
  - `backend` (ubuntu-latest, every PR + push to main): `npm ci`, typecheck, build, test. No secrets or service containers: the suite starts its own in-memory MongoDB (`mongodb-memory-server`) and never touches Redis or a real database — see "Testing Standards".
  - `frontend` (ubuntu-latest, every PR + push to main): `flutter analyze` (report-only on the repo's pre-existing `info`-level lints via `--no-fatal-infos`; still blocking on anything higher), then Flutter tests in two steps (TD-044): one blocking step runs every `*_test.dart` under `test/` and `test/widgets/` together (found via `find`, so a new test file needs no workflow edit to be covered) except `test/widgets/offline_banner_test.dart`, which stays isolated in its own step with a bounded timeout and `continue-on-error` — that one file hangs on loaded hosts even alone, a known host-level issue, not yet root-caused (TD-040). Finishes with `flutter build apk --debug` as an Android smoke test.
  - `frontend-ios` (macos-latest, **`main` only**): `flutter build ios --simulator --debug --no-codesign`. Skipped on PRs — macOS runner minutes cost several times more than Linux, and a simulator build mainly catches native-project drift, which a PR's Linux jobs already cover for everything else.
  - Path-based skip: a `changes` job (`dorny/paths-filter@v3`) gates `backend`/`frontend` on whether their paths (or `ci.yml` itself) actually changed, so a docs-only PR no longer burns ~10 min running the full suite.
  - Concurrency: one run per branch/ref, `cancel-in-progress: true` — a superseded push's CI run is canceled rather than left to burn minutes to completion.
  - Caches: `~/.pub-cache` (keyed on `pubspec.lock`), `~/.gradle/{caches,wrapper}` (keyed on the Gradle files), plus `subosito/flutter-action`'s own SDK-install cache and `actions/setup-node`'s npm cache.

---

## 🔮 Roadmap

### Phase 1 — Stabilization (NOW)
- [x] ~~Cursor-based pagination (TD-002)~~
- [x] ~~Offline mode with Hive (TD-003)~~
- [x] ~~Input sanitization and validation (TD-004)~~
- [x] ~~Integration tests + install test stack (TD-005)~~
- [x] ~~Error tracking with Sentry (TD-009)~~
- [x] ~~Idempotency-Key on write POSTs (TD-014)~~
- [x] ~~express.json payload limit (TD-015)~~
- [x] ~~CORS fail-fast in production (TD-016)~~

### Phase 2 — Robustness
- [ ] Optimistic updates (TD-007)
- [x] ~~Global rate limiting (TD-006)~~
- [x] ~~CI/CD with GitHub Actions (TD-008)~~
- [ ] Refactor members to separate collection (TD-001)
- [x] ~~Granular task permissions (TD-011)~~
- [x] ~~ESLint + Prettier + no-console (TD-012)~~
- [ ] Household-timezone-aware recurrence (TD-013)
- [x] ~~Env-based frontend config via --dart-define (TD-017)~~
- [x] ~~Member-leave lifecycle (TD-018)~~

### Phase 3 — Production
- [ ] MongoDB backups (TD-010)
- [ ] APM monitoring (Prometheus + Grafana)
- [ ] Load testing (k6)
- [ ] Performance optimization
- [ ] API versioning (see also TD-034: deploy-order safety net)

---

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

---

## ✅ Phase 1 Completion

As of this commit, Phase 1 (Stabilization) is COMPLETE. All TD items in Phase 1 are resolved. The application is ready for beta release.

> A commit cannot contain its own hash — the hash is derived from the commit's content (tree, parent, message, timestamp) only after `git commit` runs, so it can't be embedded inside that same content. Run `git log -1 --format=%H -- CLAUDE.md` (or `git log --oneline -5`) to find the actual commit that introduced this section.

**Beta release checklist:**
- [ ] Report sentry-cocoa Package.swift bug upstream (TD-038)
- [ ] Connect a real Firebase project for push notifications (TD-049): `flutterfire configure`, Xcode Push Notifications + Background Modes capability with an APNs key, `FIREBASE_SERVICE_ACCOUNT` in Railway
- [ ] Install JDK + Android SDK (deferred, see TD-008 notes)
- [ ] Configure TestFlight (iOS) and Google Play Internal Testing (Android)
- [ ] Rotate any secrets that appeared in transcripts or logs
- [ ] Smoke test on real devices (iOS + Android)
- [ ] Announce beta to early users

Note: this section originally claimed Phase 1 complete while TD-002, TD-015, TD-016 were still listed Planned (Phase 1) in the Roadmap checklist above — a stale checkbox, not a stale claim: all three were already implemented (TD-016 resolved same-day via PR #22; TD-002 and TD-015 were found already implemented, verified 2026-08-16, see docs/TECH_DEBT.md), the Roadmap checklist just hadn't been revisited to reflect it. Now fixed — the Phase 1 checklist above is fully checked, matching this section's claim.

---

## 📦 Product Decisions

Las decisiones de producto (monetización, gamificación, UX de alto nivel) viven en docs/PRODUCT_DECISIONS.md como PDRs. Léelo antes de implementar cualquier feature nueva: el código implementa los PDRs, no las redefine.

---

## 📞 Key Files Quick Reference

| File | Purpose |
|------|---------|
| `backend/src/app.ts` | Express app entry point |
| `backend/src/config/socket.ts` | Socket.io setup with Redis adapter |
| `backend/src/middleware/auth.middleware.ts` | JWT verification |
| `backend/src/middleware/error.middleware.ts` | Centralized error handling |
| `backend/src/middleware/validate.ts` | Generic Zod validate(schema) middleware (TD-028) — safeParse's req.body, 400 with `{ error, details }` on failure, replaces req.body with parsed/coerced output on success |
| `backend/src/schemas/` | Zod request-validation schemas, one file per domain (task/household/auth.schema.ts), applied to routes via validate() (TD-028) |
| `backend/src/utils/response.ts` | `sendSuccess` / `sendError` helpers |
| `backend/src/services/task.service.ts` | Task business logic + recurrence |
| `backend/src/services/household-stats.service.ts` | `GET /households/:householdId/stats?period=` load/completion stats (any member, PDR-007) |
| `backend/src/config/economy.ts` | Tunable economy constants (coin amounts, cooldowns, cosmetics catalog) — PDR-001 |
| `backend/src/config/swagger.ts` | OpenAPI spec served at `/api/docs` |
| `backend/src/models/Pet.ts` | Household pet schema (hunger/mood decay, cosmetics) — PDR-001 |
| `backend/src/models/AdoptionRequest.ts` | Pending 2+ member adoption proposal, deleted on confirm/cancel/expiry — PDR-001 |
| `backend/src/models/EconomyLedger.ts` | Append-only coin ledger; balance is always `sum(amount)` — PDR-001 |
| `backend/src/services/pet.service.ts` | Pet/adoption business logic + socket emissions |
| `backend/src/services/economy.service.ts` | Coin balance, lazy hunger/mood decay, grantCoins anti-farm rules |
| `backend/src/services/notification.service.ts` | Firebase Admin push notifications: `sendPushNotification`, device token register/remove (PDR-008) |
| `backend/src/models/DeviceToken.ts` | FCM device token per user, unique on `{userId, token}` — PDR-008 |
| `backend/src/scripts/purge-trash.ts` | `--days N` (default 30) global trash purge, meant for a scheduled job — shares `taskService.purgeDeletedTasks` with the admin-only `POST .../tasks/purge` endpoint (TD-048) |
| `frontend/lib/config/constants.dart` | API URLs and app config — set via `--dart-define` (API_BASE_URL/ENVIRONMENT), see README.md; no longer protected with --assume-unchanged (TD-017) |
| `frontend/lib/data/datasources/remote/api_service.dart` | Dio client with auth interceptors |
| `frontend/lib/services/socket_service.dart` | Socket.io singleton |
| `frontend/lib/services/notification_service.dart` | Local task reminders + FCM push registration/foreground display (PDR-008) |
| `frontend/lib/presentation/cubit/task_cubit.dart` | Task state management |
| `frontend/lib/presentation/cubit/pet_cubit.dart` | Pet/adoption/economy state management |
| `frontend/lib/presentation/pages/pet_page.dart` | Pet tab: adoption flow, care view (feed/play) |
| `frontend/lib/presentation/pages/pet_shop_page.dart` | Cosmetics shop UI |
| `frontend/lib/presentation/pages/calendar_page.dart` | Mes/Semana selector; week view reuses spanning bars logic from month view |
| `frontend/lib/presentation/pages/recurring_tasks_page.dart` | Recurrentes tab (TD-035): one row per recurring series (`TaskCubit.recurringTasks`), reusing `TaskTile` + `TaskFormPage` navigation |
| `frontend/lib/presentation/pages/stats_page.dart` | Household stats view (PDR-007), reached from Profile's AppBar (bar_chart icon); period toggle (30 días/Todo) via `StatsCubit` |

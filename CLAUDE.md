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

Document key architectural decisions here. Format: Context → Decision → Consequences.

### ADR-001: Monorepo structure
- **Context:** Need backend and frontend to evolve together with shared context.
- **Decision:** Single repository with `backend/` and `frontend/` folders.
- **Consequences:** Easier to keep API contracts in sync, single CI/CD pipeline, but larger repo size.

### ADR-002: Socket.io with Redis adapter
- **Context:** Realtime sync across multiple server instances requires pub/sub.
- **Decision:** Use Socket.io with Redis adapter so events broadcast across all instances.
- **Consequences:** Requires Redis dependency, but enables horizontal scaling.

### ADR-003: Cubits over Blocs in Flutter
- **Context:** State management needed. Blocs add boilerplate with events. Cubits are simpler.
- **Decision:** Use Cubits (`flutter_bloc`) for state management.
- **Consequences:** Less boilerplate, easier to test, but less structured for complex event flows.

### ADR-004: JWT with refresh token rotation
- **Context:** Need secure auth for mobile app with long-lived sessions.
- **Decision:** Short-lived access tokens (15m) + long-lived refresh tokens (7d) with rotation on use.
- **Consequences:** More complex auth flow, but better security. Refresh tokens stored in DB and invalidated on use.

### ADR-005: Embedded members in Household (TO BE MIGRATED)
- **Context:** Initial MVP embedded members array in Household document for simplicity.
- **Decision:** Keep embedded for MVP, but plan migration to separate `HouseholdMember` collection.
- **Consequences:** Simple reads for MVP, but will hit MongoDB 16MB document limit with large households. Migration planned in Phase 2.

### ADR-006: Timezone strategy for dates and recurrence
- **Context:** Recurring tasks, dueDate and the ±1-day anti-duplicate guard are ambiguous without a defined timezone.
- **Decision:** Store ALL timestamps in UTC (MongoDB Date). Compute recurrence and the ±1-day guard in UTC for now. Frontend displays dates in the device's local timezone. Households will gain a `timeZone` field (IANA string, default = creator's TZ at creation) and recurrence computation will migrate to household TZ in Phase 2.
- **Consequences:** Consistent behavior across devices and DST changes today; known UX edge case (a "daily at 9am" task drifts on DST change) until TD-013 is implemented.

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
3. **Refresh token** stored in `refreshtokens` MongoDB collection (rotated on use, deleted on logout)
4. **Frontend** auto-refreshes on 401 with single-flight pattern (deduplicates concurrent refresh calls)
5. **If refresh fails** → force logout via `onSessionExpired` callback

**Security rules:**
- Passwords hashed with bcrypt, never returned in responses
- Failed login/register return generic message (never reveal if email exists)
- Credential endpoints rate-limited: 5 requests / 15 min / IP
- Password field has `select: false` in Mongoose schema

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

### User
| Field | Type | Notes |
|-------|------|-------|
| email | String | unique, lowercase, indexed |
| password | String | bcrypt hashed, `select: false` |
| name | String | required |
| avatarUrl | String | optional |
| households | ObjectId[] | ref Household |

### Household
| Field | Type | Notes |
|-------|------|-------|
| name | String | required |
| inviteCode | String | unique, 8 chars uppercase, indexed |
| members | IHouseholdMember[] | embedded: `{ user, role, joinedAt }` |
| createdBy | ObjectId | ref User |

### Task
| Field | Type | Notes |
|-------|------|-------|
| householdId | ObjectId | required, indexed |
| title | String | required |
| description | String | optional |
| assignedTo | ObjectId[] | ref User |
| createdBy | ObjectId | ref User, required |
| status | Enum | `pending` / `completed`, default `pending` |
| priority | Enum | `low` / `medium` / `high`, default `medium` |
| category | Enum | `cleaning` / `cooking` / `shopping` / `maintenance` / `other` |
| dueDate | Date | optional |
| completedAt | Date | set on completion |
| completedBy | ObjectId | set on completion |
| isRecurring | Boolean | default false |
| recurrenceRule | Object | `{ type, interval, daysOfWeek, dayOfMonth }` |
| parentTaskId | ObjectId | links recurring instances, indexed |

**Indexes:** `{ householdId: 1, status: 1, dueDate: 1 }` (compound)

### ShoppingItem
| Field | Type | Notes |
|-------|------|-------|
| householdId | ObjectId | required, indexed |
| name | String | required |
| quantity | Number | default 1 |
| category | String | optional |
| purchased | Boolean | default false |
| purchasedAt | Date | set on purchase |
| purchasedBy | ObjectId | set on purchase |
| createdBy | ObjectId | ref User |

### RefreshToken
| Field | Type | Notes |
|-------|------|-------|
| token | String | hashed, unique |
| userId | ObjectId | ref User |
| expiresAt | Date | TTL index for auto-cleanup |

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

---

## 🧪 Testing Standards

**⚠️ IMPORTANT — Target state, not yet installed:** The testing stack described below (Jest, Supertest, mongodb-memory-server, bloc_test) is NOT currently installed in the repo. Before writing tests, the assistant MUST first install the dependencies (see TD-005 / Phase 1). Do NOT assume tests can be executed until setup is complete.

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

---

## 🚫 Hard Rules (Never Break These)

1. NEVER store passwords in plain text or return them in responses
2. NEVER reveal whether an email exists in register/login error messages
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
13. NEVER allow write POSTs without idempotency protection: every POST that creates a resource MUST accept an `Idempotency-Key` header; backend MUST dedupe via Redis with a TTL; frontend MUST generate one stable UUID per logical operation (surviving 401 retries). On duplicate key detection the backend MUST return the original resource with HTTP 200 and MUST NOT re-emit socket events. (MUST be enforced — currently NOT implemented, see TD-014)
14. NEVER configure `express.json()` without a payload size limit (e.g. `limit: '100kb'`). (MUST be enforced — currently NOT implemented, see TD-015)
15. NEVER ship production with empty `CORS_ORIGINS`: when `NODE_ENV=production` it MUST be non-empty and the server MUST fail fast at startup otherwise; wildcard `*` is only acceptable in development. (MUST be enforced — currently NOT implemented, see TD-016)
16. NEVER leave orphaned references when a member leaves a household: their pending assigned tasks MUST be unassigned (removed from `assignedTo`), tasks they created MUST be preserved, and the UI MUST render "Former member" for dangling user refs. (MUST be enforced — currently NOT implemented, see TD-018)
17. NEVER allow edit/delete of a task by anyone other than the creator or an admin; any member may complete tasks and purchase shopping items. (MUST be enforced — currently NOT implemented, see TD-011, implement in Phase 2)

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

Track all identified technical debt here. Format: ID | Description | Severity | Proposed Solution | Status | Owner | Created

| ID | Description | Severity | Proposed Solution | Status | Owner | Created |
|----|-------------|----------|-------------------|--------|-------|---------|
| TD-001 | Members embedded in Household document | High | Migrate to separate HouseholdMember collection | Planned (Phase 2) | TBD | 2026-08-08 |
| TD-002 | No pagination on list endpoints | High | Implement cursor-based pagination | Planned (Phase 1) | TBD | 2026-08-08 |
| TD-003 | No offline support in frontend | High | Implement Hive caching + sync queue | Planned (Phase 1) | TBD | 2026-08-08 |
| TD-004 | No input sanitization | High | Add express-mongo-sanitize + XSS escaping | Planned (Phase 1) | TBD | 2026-08-08 |
| TD-005 | No test coverage (stack not installed) | High | Add Jest + Supertest + mongodb-memory-server + bloc_test | Planned (Phase 1) | TBD | 2026-08-08 |
| TD-006 | Rate limiting only on auth endpoints | Medium | Add global + per-endpoint rate limiting | Planned (Phase 2) | TBD | 2026-08-08 |
| TD-007 | No optimistic updates in frontend | Medium | Implement optimistic UI updates | Planned (Phase 2) | TBD | 2026-08-08 |
| TD-008 | No CI/CD pipeline | Medium | Configure GitHub Actions | Planned (Phase 2) | TBD | 2026-08-08 |
| TD-009 | No error tracking (Sentry not installed) | Medium | Integrate Sentry backend + frontend | Planned (Phase 1) | TBD | 2026-08-08 |
| TD-010 | No database backups | Medium | Configure MongoDB Atlas backups | Planned (Phase 3) | TBD | 2026-08-08 |
| TD-011 | No resource-level authorization on tasks (any member can delete) | High | Creator-or-admin rule for edit/delete; any member can complete | Planned (Phase 2) | TBD | 2026-08-10 |
| TD-012 | No ESLint/Prettier with no-console rule | Medium | Add lint config + pre-commit hook | Planned (Phase 2) | TBD | 2026-08-10 |
| TD-013 | Recurrence computed in UTC without household timezone | Medium | Add household.timeZone + TZ-aware recurrence | Planned (Phase 2) | TBD | 2026-08-10 |
| TD-014 | No idempotency on write POSTs (retry can duplicate) | High | Idempotency-Key header + Redis dedupe | Planned (Phase 1) | TBD | 2026-08-10 |
| TD-015 | No express.json payload size limit | Medium | Add limit option | Planned (Phase 1) | TBD | 2026-08-10 |
| TD-016 | CORS_ORIGINS empty = * allowed in production | High | Fail-fast at startup in production | Planned (Phase 1) | TBD | 2026-08-10 |
| TD-017 | constants.dart with hardcoded local backend URL | Low | Migrate to --dart-define / env-based config | Planned (Phase 2) | TBD | 2026-08-10 |
| TD-018 | Member-leave lifecycle not handled (orphaned assignedTo refs, no "Former member" UI) | High | Unassign pending tasks on leave/removal + Former member fallback in UI | Planned (Phase 2) | TBD | 2026-08-10 |

---

## 🌿 Git Workflow

- **Branch naming:** `feat/description`, `fix/description`, `chore/description`, `refactor/description`
- **Commit messages:** Use conventional commits:
  - `feat(backend): add pagination to tasks endpoint`
  - `fix(frontend): fix socket reconnection on token refresh`
  - `refactor(backend): extract membership check to helper`
  - `chore: update dependencies`
- **PR requirements:**
  - All tests pass
  - TypeScript typecheck passes (`npm run typecheck`)
  - Flutter analyze passes (`flutter analyze`)
  - No `console.log` in production code (use logger)
  - Update Swagger docs if API changes
  - Update README if setup process changes
  - Include "💡 Proposed Improvements" section in PR description

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

**Backend URL config** in `frontend/lib/config/constants.dart`:
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
| CORS_ORIGINS | Comma-separated allowed origins (empty = allow *) | No |
| NODE_ENV | development / production | No |
| SENTRY_DSN | Sentry error tracking DSN | No |

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
- Start command: `node backend/dist/app.js`
- Set all environment variables in Railway dashboard

### Frontend
- Android: applicationId `com.homesync.app`, minSdkVersion 21
- iOS: Bundle ID `com.homesync.app`
- Build with: `flutter build apk --release` / `flutter build ios --release`

---

## 🔮 Roadmap

### Phase 1 — Stabilization (NOW)
- [ ] Cursor-based pagination (TD-002)
- [ ] Offline mode with Hive (TD-003)
- [ ] Input sanitization and validation (TD-004)
- [ ] Integration tests + install test stack (TD-005)
- [ ] Error tracking with Sentry (TD-009)
- [ ] Idempotency-Key on write POSTs (TD-014)
- [ ] express.json payload limit (TD-015)
- [ ] CORS fail-fast in production (TD-016)

### Phase 2 — Robustness
- [ ] Optimistic updates (TD-007)
- [ ] Global rate limiting (TD-006)
- [ ] CI/CD with GitHub Actions (TD-008)
- [ ] Refactor members to separate collection (TD-001)
- [ ] Granular task permissions (TD-011)
- [ ] ESLint + Prettier + no-console (TD-012)
- [ ] Household-timezone-aware recurrence (TD-013)
- [ ] Env-based frontend config via --dart-define (TD-017)
- [ ] Member-leave lifecycle (TD-018)

### Phase 3 — Production
- [ ] MongoDB backups (TD-010)
- [ ] APM monitoring (Prometheus + Grafana)
- [ ] Load testing (k6)
- [ ] Performance optimization
- [ ] API versioning

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

## 📞 Key Files Quick Reference

| File | Purpose |
|------|---------|
| `backend/src/app.ts` | Express app entry point |
| `backend/src/config/socket.ts` | Socket.io setup with Redis adapter |
| `backend/src/middleware/auth.middleware.ts` | JWT verification |
| `backend/src/middleware/error.middleware.ts` | Centralized error handling |
| `backend/src/utils/response.ts` | `sendSuccess` / `sendError` helpers |
| `backend/src/services/task.service.ts` | Task business logic + recurrence |
| `frontend/lib/config/constants.dart` | API URLs and app config |
| `frontend/lib/data/datasources/remote/api_service.dart` | Dio client with auth interceptors |
| `frontend/lib/services/socket_service.dart` | Socket.io singleton |
| `frontend/lib/presentation/cubit/task_cubit.dart` | Task state management |

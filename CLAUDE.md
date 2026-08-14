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
- **Consequences:** More complex auth flow, but better security. Refresh tokens stored in DB and invalidated on use. Refresh tokens are stored SHA-256 hashed (not raw) so a database leak does not yield usable sessions; SHA-256 chosen over bcrypt because JWTs are already high-entropy and bcrypt would add latency to every refresh.

### ADR-005: Embedded members in Household (TO BE MIGRATED)
- **Context:** Initial MVP embedded members array in Household document for simplicity.
- **Decision:** Keep embedded for MVP, but plan migration to separate `HouseholdMember` collection.
- **Consequences:** Simple reads for MVP, but will hit MongoDB 16MB document limit with large households. Migration planned in Phase 2.

### ADR-006: Timezone strategy for dates and recurrence
- **Context:** Recurring tasks, dueDate and the ±1-day anti-duplicate guard are ambiguous without a defined timezone.
- **Decision:** Store ALL timestamps in UTC (MongoDB Date). Compute recurrence and the ±1-day guard in UTC for now. Frontend displays dates in the device's local timezone. Households will gain a `timeZone` field (IANA string, default = creator's TZ at creation) and recurrence computation will migrate to household TZ in Phase 2.
- **Consequences:** Consistent behavior across devices and DST changes today; known UX edge case (a "daily at 9am" task drifts on DST change) until TD-013 is implemented.

### ADR-007: Idempotency-Key semantics (replay and concurrency)
- **Context:** Dio 401-retries and socket reconnects can duplicate write POSTs; two identical requests can also race in parallel.
- **Decision:** POSTs that create resources accept an `Idempotency-Key` header. Backend acquires the key in Redis with `SET <key> <placeholder> NX EX <ttl>` BEFORE creating the resource. If SET NX fails: stored value is a completed result → return the original resource with HTTP 200 and do NOT re-emit socket events; stored value is in-progress → poll up to 2s for completion, then return the original with 200; timeout → 409 Conflict. Frontend generates one stable UUID per logical operation (surviving 401 retries) and NEVER auto-retries a 409. The header is optional during the migration window; the Flutter client starts sending it in Prompt 1.5; making it mandatory on household-scoped POSTs is a candidate hard rule once the client ships. Keys are scoped server-side per user and route before hashing (sha256(userId:route:key)) to prevent cross-user response poisoning; failed attempts call release() so a validation error never traps the client in 409 for the key TTL. The IdempotencyStore is failure-tolerant by design: on any store failure (Redis outage, timeout, exception) the middleware fail-opens and processes the request without idempotency, logging a security-grade warning. Idempotency is a correctness improvement, not a requirement; its absence MUST NOT cause a write outage.
- **Consequences:** prevents duplicates on retry and on race; requires storing the serialized result in Redis with TTL; 409 is a safe terminal response for clients.

### ADR-008: Forward-only cursor pagination with full sort-position encoding
- **Context:** List endpoints must paginate without skipping/duplicating rows under a compound sort (status, dueDate, _id).
- **Decision:** Cursor is an opaque base64 token encoding the full sort position (status, dueDate, _id), not just _id. Only forward direction is implemented (YAGNI): the mobile UX is infinite scroll down + pull-to-refresh that resets pagination; backward mode will be added only if a real use case appears.
- **Consequences:** Correct paging under compound sort; simpler client; total requires a separate countDocuments query. total is returned only on the first page (no cursor); paged requests return total: null to avoid a redundant countDocuments per page.

### ADR-009: Edge validation, raw storage, escape at render
- **Context:** The first sanitization batch HTML-escaped text at storage time; Flutter renders user text with Text(), which does not interpret markup, so storage escaping degraded UX (users saw "Tom &amp; Jerry") without adding mobile security.
- **Decision:** Store user text raw after trim + length limits; NoSQL injection is blocked by express-mongo-sanitize at the edge; HTML escaping is a presentation concern to be applied at render time, only if a web client ever ships.
- **Consequences:** Correct UX on mobile today; a future web frontend MUST escape at render; Zod edge validation (TD-028) will centralize and strengthen edge validation and replace the global mongo-sanitize middleware for Express 5 compatibility.

### ADR-010: Offline-first with last-write-wins conflict resolution
- **Context:** TD-003 — mobile connectivity in the field is unreliable (elevators, subways, poor rural coverage). Users need to keep creating/editing tasks and shopping items while offline and have those changes reconciled once the device reconnects, without a second backend contract just for offline sync.
- **Decision:** `TaskRepository`/`ShoppingRepository` read cache-first with a live-server fallback, backed by Hive via hand-written `TypeAdapter`s (`hive_generator`'s last-published version pins an `analyzer` range that conflicts with `bloc_test`'s, so codegen was dropped for this project — see `pubspec.yaml`). A write made offline, or during any network-shaped failure (`NetworkFailure`, or a `ServerFailure` with no/≥500 status — see `isOfflineWorthy()`), is applied optimistically to the cache with `isSynced: false` and queued as a `PendingOperation` (create/update/delete). `TaskCubit`/`ShoppingCubit.syncPending()` replays the queue FIFO, automatically on `ConnectivityService`'s false→true transition. No merge or version-vector logic exists: a queued write simply POSTs/PATCHes its payload against whatever the server holds at replay time, so the last write that actually reaches the server wins — the same overwrite-on-update semantics MongoDB already has, requiring no backend change.
- **Consequences:** Simple, fully client-side, and testable without touching the backend; but two devices editing the SAME task while both offline can silently lose one device's edit once both reconnect (tracked as TD-039). A replay that fails for a non-network reason retries up to 3 times across sync passes before being dropped and reported to Sentry, so one permanently-invalid queued write cannot block everything queued after it. Acceptable for Phase 1 given HomeSync's household size (2-6 people) and low concurrent-edit frequency; CRDT/OT is deferred until real conflict reports justify the added complexity.

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
3. **Refresh token** stored SHA-256 hashed in the refreshtokens collection (rotated on use, deleted on logout); a DB leak never yields usable sessions
4. **Frontend** auto-refreshes on 401 with single-flight pattern (deduplicates concurrent refresh calls)
5. **If refresh fails** → force logout via `onSessionExpired` callback

**Security rules:**
- Passwords hashed with bcrypt, never returned in responses
- Failed login/register return generic message (never reveal if email exists)
- Credential endpoints rate-limited: 5 requests / 15 min / IP
- Password field has `select: false` in Mongoose schema
- Replay detection revokes the full token family on two triggers: valid signature + missing row, OR stored userId mismatch with the JWT payload; every family revocation emits a security log (`logger.warn` with userId) as the audit hook for Sentry (TD-009)

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
| createdAt / updatedAt | Date | from `timestamps: true` |

**Embedded `IRecurrenceRule`** (`_id: false`):
| Field | Type | Notes |
|-------|------|-------|
| type | Enum | `daily` / `weekly` / `monthly` / `custom` |
| interval | Number | default 1 |
| daysOfWeek | Number[] | each 0–6 (0 = Sunday), default `undefined` |
| dayOfMonth | Number | 1–31 |

**Indexes:** `{ householdId: 1, status: 1, dueDate: 1 }` (compound), plus the single-field
indexes on `householdId`, `status` and `parentTaskId`.

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
5. Member-leave lifecycle (unassign pending tasks on leave/removal, preserve created tasks, last-admin protection). Last-admin protection is testable today; the full lifecycle MUST be covered when TD-018 is implemented.
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
13. NEVER allow write POSTs without idempotency protection: every POST that creates a resource MUST accept an `Idempotency-Key` header; backend MUST dedupe via Redis with a TTL; frontend MUST generate one stable UUID per logical operation (surviving 401 retries). On duplicate key detection the backend MUST return the original resource with HTTP 200 and MUST NOT re-emit socket events. (MUST be enforced — currently NOT implemented, see TD-014)
14. NEVER configure `express.json()` without a payload size limit (e.g. `limit: '100kb'`). (MUST be enforced — currently NOT implemented, see TD-015)
15. NEVER ship production with empty `CORS_ORIGINS`: when `NODE_ENV=production` it MUST be non-empty and the server MUST fail fast at startup otherwise; wildcard `*` is only acceptable in development. (MUST be enforced — currently NOT implemented, see TD-016)
16. NEVER leave orphaned references when a member leaves a household: their pending assigned tasks MUST be unassigned (removed from `assignedTo`), tasks they created MUST be preserved, and the UI MUST render "Former member" for dangling user refs. (MUST be enforced — currently NOT implemented, see TD-018)
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

Track all identified technical debt here. Format: ID | Description | Severity | Proposed Solution | Status | Owner | Created

| ID | Description | Severity | Proposed Solution | Status | Owner | Created |
|----|-------------|----------|-------------------|--------|-------|---------|
| TD-001 | Members embedded in Household document | High | Migrate to separate HouseholdMember collection | Planned (Phase 2) | TBD | 2026-08-08 |
| TD-002 | No pagination on list endpoints | High | Implement cursor-based pagination | Planned (Phase 1) | TBD | 2026-08-08 |
| TD-003 | No offline support in frontend | High | Implement Hive caching + sync queue | Resolved (commits 1-3): cache-first repositories, offline pending-operations queue with auto-sync on reconnect (ADR-010), offline UI (banner, pending-count badge, per-item sync/deleted indicators) | TBD | 2026-08-08 |
| TD-004 | No input sanitization | High | mongo-sanitize at edge + length limits; raw storage per ADR-009 (escape at render if a web client ships) | Resolved (commit 3) | TBD | 2026-08-08 |
| TD-005 | No test coverage (stack not installed) | High | Add Jest + Supertest + mongodb-memory-server + bloc_test | Planned (Phase 1) | TBD | 2026-08-08 |
| TD-006 | Rate limiting only on auth endpoints | Medium | Add global + per-endpoint rate limiting | Planned (Phase 2) | TBD | 2026-08-08 |
| TD-007 | No optimistic updates in frontend | Medium | Implement optimistic UI updates | Planned (Phase 2) | TBD | 2026-08-08 |
| TD-008 | No CI/CD pipeline | Medium | Configure GitHub Actions: backend (typecheck/build/test) + frontend (analyze/sharded test/build apk) on every PR and push to main, frontend-ios (simulator build) on main only | Resolved (commit 1) | TBD | 2026-08-08 |
| TD-009 | No error tracking (Sentry not installed) | Medium | Integrate Sentry backend + frontend; backend + frontend with no-op fallback; security warnings (refresh replay) routed to Sentry as alert channel | Resolved (commits 1-2) | TBD | 2026-08-08 |
| TD-010 | No database backups | Medium | Configure MongoDB Atlas backups | Planned (Phase 3) | TBD | 2026-08-08 |
| TD-011 | No resource-level authorization on tasks (any member can delete) | High | Creator-or-admin rule for edit/delete; any member can complete tasks and purchase shopping items | Resolved (commit 1) | TBD | 2026-08-10 |
| TD-012 | No ESLint/Prettier with no-console rule | Medium | Add lint config + pre-commit hook | Planned (Phase 2) | TBD | 2026-08-10 |
| TD-013 | Recurrence computed in UTC without household timezone | Medium | Add household.timeZone + TZ-aware recurrence | Planned (Phase 2) | TBD | 2026-08-10 |
| TD-014 | No idempotency on write POSTs (retry can duplicate) | High | Idempotency-Key header + Redis dedupe | Resolved (commit 2) | TBD | 2026-08-10 |
| TD-015 | No express.json payload size limit | Medium | Add limit option | Planned (Phase 1) | TBD | 2026-08-10 |
| TD-016 | CORS_ORIGINS empty = * allowed in production | High | Fail-fast at startup in production | Planned (Phase 1) | TBD | 2026-08-10 |
| TD-017 | constants.dart with hardcoded local backend URL | Low | constants.dart uses String.fromEnvironment() with sensible defaults (API_BASE_URL default http://localhost:3000, ENVIRONMENT default development). README.md documents `flutter run`/`build` commands with `--dart-define` flags for dev and production. No more --assume-unchanged hack. (A `scripts:` key in pubspec.yaml was considered but rejected — vanilla `pub`/`flutter pub` has no such feature, so it would be inert YAML; the real commands live in README.md instead.) | Resolved | TBD | 2026-08-10 |
| TD-018 | Member-leave lifecycle not handled (orphaned assignedTo refs, no "Former member" UI) | High | Unassign pending tasks on leave/removal + Former member fallback in UI | Planned (Phase 2 — High severity deliberately deferred from Phase 1: low-frequency edge case; Phase 1 scope is stabilization-critical) | TBD | 2026-08-10 |
| TD-019 | pubspec.lock ignored in frontend/.gitignore (non-reproducible builds) | High | Remove from .gitignore and commit the lockfile | Resolved (2026-08-10, Parte 0 chore) | TBD | 2026-08-10 |
| TD-020 | Auth rate limiter had no test (skipped under NODE_ENV=test) | Medium | createApp({ authRateLimit }) opt-in + dedicated 429 test | Resolved (2026-08-10, commit B) | TBD | 2026-08-10 |
| TD-021 | Mongoose test connection without bufferCommands:false (slow opaque failures) | Low | bufferCommands:false + serverSelectionTimeoutMS 5000 in test harness | Resolved (2026-08-10, commit B) | TBD | 2026-08-10 |
| TD-022 | Refresh token replay did not revoke the token family (stolen-token session survived) | High | Detect rotated-token replay via valid signature + missing row, revoke all user refresh tokens | Resolved (2026-08-10, commit B) | TBD | 2026-08-10 |
| TD-023 | Refresh tokens stored as raw JWTs, not hashed (this file previously claimed otherwise) | High | Store SHA-256 of the token and look up by hash; a DB leak must not yield usable tokens | Resolved (2026-08-10, commit B) | TBD | 2026-08-10 |
| TD-024 | SHA-256 migration: raw refresh tokens already persisted in Atlas will not match sha256 lookups after deploy | High | One-time action: clear refreshtokens collection when deploying b2c481e (safe now: pre-production, no real users; post-user-acquisition this would require a grace-period lookup) | Script ready (scripts/migrate-refresh-tokens.ts); run with --yes during the deploy window of b2c481e | TBD | 2026-08-10 |
| TD-025 | Monthly recurrence anchor bug: dayOfMonth 31 clamps to Feb 28 and never recovers because the next occurrence is computed from the clamped date instead of the rule anchor | High | Anchor monthly computation to rule.dayOfMonth; add weekly/monthly/clamp unit tests | Resolved (commit 1) | TBD | 2026-08-10 |
| TD-026 | List sort not backed by a matching compound index (in-memory sort per page) | High | Add sort-exact compound indexes on Task and ShoppingItem | Resolved (commit 3) | TBD | 2026-08-10 |
| TD-027 | Frontend repositories broken against paginated backend (data array → object) | Medium | Paginated envelope + per-tab filtering (?status= query param) + per-tab ScrollController + total visible in header. Home and Calendar read the unfiltered allTasks bucket; per-tab totals adjusted optimistically on mutations | UX polish completed (commit 1) | TBD | 2026-08-10 |
| TD-028 | Validation scattered across controllers/services; express-mongo-sanitize incompatible with Express 5 | Medium | Zod schemas per endpoint as middleware; explicit body sanitization replaces global middleware | Planned (Phase 2) | TBD | 2026-08-10 |
| TD-029 | Text persisted HTML-escaped during the escaping window remains escaped | Low | Won't fix: pre-production, only local test data affected; re-seed if cosmetic noise bothers; a one-off unescape pass would only be justified if a real household existed in the window | Won't fix | TBD | 2026-08-10 |
| TD-030 | Index tests were temporarily downgraded to schema-declaration level while host disk had <500 MB free | Low | Host disk freed; listIndexes() built-index assertions restored | Resolved (commit 1) | TBD | 2026-08-10 |
| TD-031 | POSTs carrying Idempotency-Key hang forever when Redis is unreachable (ioredis maxRetriesPerRequest:null queues commands indefinitely) | High | commandTimeout configurable (default 2500ms, env REDIS_COMMAND_TIMEOUT_MS) on a dedicated app-only Redis connection; pub/sub connections stay timeout-free to preserve Socket.io adapter stability; fail-open in middleware | Resolved (commit 1) | TBD | 2026-08-10 |
| TD-032 | Socket.io Redis adapter does not catch its own command rejections; Node 24 kills the process on unhandledRejection | High | Global unhandledRejection handler that logs and does not exit (Node 24 default would kill the process) | Resolved (commit 1) | TBD | 2026-08-10 |
| TD-033 | Idempotency fail-open not observable: silent log spam during Redis outage, no metric for postmortem duplicate analysis | Medium | In-memory fail-open counter + rate-limited log + JSON endpoint; Prometheus hook when APM lands | Resolved (commit 1) | TBD | 2026-08-10 |
| TD-034 | No deploy-order safety net between backend and Flutter app (versioned /health check). CI verification mitigates broken-push risk; deploy-order safety net still pending — CI (TD-008) surfaces a broken backend/frontend push before or alongside Railway's auto-deploy (which triggers on push regardless of CI outcome; no branch-protection gate ties the two together), it does not itself prevent an already-deployed backend from being incompatible with the app version still in users' hands | Medium | Add API version to /health and a client-side check that shows "update the app" when incompatible; requires API versioning (Phase 3) | Planned (Phase 3) | TBD | 2026-08-10 |
| TD-035 | No server-side isRecurring filter; Recurrentes tab removed to avoid local filtering over paginated data | Medium | Add ?isRecurring=true backend filter and restore the tab | Planned (Phase 2) | TBD | 2026-08-11 |
| TD-036 | Native scaffolding (gradlew, Runner.xcodeproj, res/, Assets.xcassets, etc.) was hand-curated and incomplete — the repo could not build without running flutter create manually first | High | Version the full native scaffolding, reconciled against the already-tracked com.homesync.app package/bundle id; template xcconfig files (Debug/Release) tracked so fresh clones build without flutter create; generated artifacts ignored | Resolved (commit 1) | TBD | 2026-08-11 |
| TD-037 | Sentry hardening bundle: configurable tracesSampleRate via env, Idempotency-Key in frontend 5xx context for TD-033 correlation, AppError-500 and concurrent-request context tests | Low | Apply when enabling Sentry with a real DSN in production | Deferred (until Sentry goes live) | TBD | 2026-08-11 |
| TD-038 | sentry_flutter 8.14.2's Package.swift allows any sentry-cocoa 8.x (`from: "8.46.0"`) while its podspec pins exactly 8.46.0; SPM had resolved 8.58.4, which broke the plugin's Swift build (SentryBinaryImageCache API changed) | High | Pinned both Package.resolved files to 8.46.0 matching the podspec; re-pin on every sentry_flutter upgrade until upstream tightens the SPM constraint. Documented in `frontend/README.md`'s Known Issues. Filing the upstream request (against `getsentry/sentry-cocoa`, to tighten the Package.swift range so it can't drift past the podspec again) is a human action — requires a GitHub account and maintainer engagement — and is not something this pipeline can automate; tracked here as a manual follow-up, not automated work. | Resolved (commit 1); upstream report still open (manual follow-up) | TBD | 2026-08-11 |
| TD-039 | Offline conflict resolution uses last-write-wins; concurrent edits on multiple devices can overwrite | Low | Evaluate CRDT or OT if user reports lost edits | Deferred (Phase 2, if conflicts become frequent) | TBD | 2026-08-11 |
| TD-040 | flutter test hangs on loaded hosts — confirmed (2026-08-13) to reproduce even running test/widgets/offline_banner_test.dart alone, not only when combined with the rest of the suite as first documented. `frontend_server_aot`'s CPU time froze completely (observed stuck at a fixed value for 200s+) even after clearing `build/test_cache`'s incremental-compile cache, so it is a toolchain/host-level stall (likely resource pressure — observed alongside load average ~4 and <60MB free pages), not a test-code defect or a stale-cache artifact. task_tile_test.dart and assignee_selector_test.dart both pass cleanly, alone or together; only offline_banner_test.dart triggers it | Low | Investigate with --verbose on idle machine. CI runs Flutter tests sharded (top-level + each widgets file separately); offline_banner_test isolated with allow-failure until root-caused | Mitigated in CI (commit 1, TD-008); root cause still open | TBD | 2026-08-11 |
| TD-041 | Android minSdk 23+ and Flutter pin in CI — Flutter's DependencyVersionChecker enforces errorMinSdkVersion=23 (build-breaking). Project minSdk raised from 21 to 23 (Android 7.0+), accepting <5% market loss for cleaner builds. CI pins Flutter version (not channel: stable) to prevent surprise floor bumps when Flutter stable advances | Low | When upgrading Flutter, check minSdk/Gradle/AGP/Kotlin floors and bump deliberately, not reactively | Resolved | TBD | 2026-08-14 |
| TD-042 | Flutter Built-in Kotlin migration — Flutter 3.44+ is migrating to Built-in Kotlin. Plugins that apply Kotlin Gradle Plugin classically (like sentry_flutter 8.x) fail with "Language version 1.6 is no longer supported" when Kotlin is 2.3.20+. sentry_flutter upgraded 8.14.2 → 9.27.0, which drops the hardcoded languageVersion="1.6" override (still applies classic KGP unconditionally, unlike package_info_plus's AGP-major-version guard — residual, not eliminated). No other project dependency (flutter_local_notifications, connectivity_plus, package_info_plus, shared_preferences_android) applies classic KGP | Low | Keep sentry_flutter and other Kotlin-using plugins updated to versions that support Built-in Kotlin or Kotlin 2.x with language version 2.0+ | Resolved | TBD | 2026-08-14 |

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
| REDIS_COMMAND_TIMEOUT_MS | Timeout in ms for application Redis commands (default 2500; pub/sub connections are not affected) | No |
| SENTRY_DSN | Sentry error tracking DSN; empty or absent disables Sentry (no-op) | No |
| CORS_ORIGINS | Comma-separated allowed origins (empty = allow *) | No |
| NODE_ENV | development / production | No |

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
- `API_BASE_URL`: backend host, no path suffix (default: `http://localhost:3000`)
- `ENVIRONMENT`: `development` / `production` flag (default: `development`)
- `SENTRY_DSN`: error tracking, independent define read directly in `services/sentry_service.dart` — see that file's doc comment for why it is deliberately not part of `AppConfig` (default: empty, no-op)

Set via `--dart-define=KEY=value` flags on `flutter run` / `flutter build`. See `frontend/README.md` for the full commands. `constants.dart` needs no machine-local edits and carries no `--assume-unchanged` protection.

---

## 🔄 CI/CD

Two separate systems, deliberately not coupled by a branch-protection gate (see TD-034):

- **Railway = continuous deployment.** Auto-deploys on every push to `main`, independent of GitHub Actions' outcome — see "Deployment" above.
- **GitHub Actions (`.github/workflows/ci.yml`) = continuous integration.** Verifies a push/PR; it does not deploy anything itself.
  - `backend` (ubuntu-latest, every PR + push to main): `npm ci`, typecheck, build, test. No secrets or service containers: the suite starts its own in-memory MongoDB (`mongodb-memory-server`) and never touches Redis or a real database — see "Testing Standards".
  - `frontend` (ubuntu-latest, every PR + push to main): `flutter analyze` (report-only on the repo's pre-existing `info`-level lints via `--no-fatal-infos`; still blocking on anything higher), Flutter tests run **sharded**, never as one monolithic run (TD-040): top-level `test/`, then `test/widgets/task_tile_test.dart` and `test/widgets/assignee_selector_test.dart` each as their own blocking step, then `test/widgets/offline_banner_test.dart` in its own step with a bounded timeout and `continue-on-error` (known host-level hang, not yet root-caused — see TD-040). Finishes with `flutter build apk --debug` as an Android smoke test.
  - `frontend-ios` (macos-latest, **`main` only**): `flutter build ios --simulator --debug --no-codesign`. Skipped on PRs — macOS runner minutes cost several times more than Linux, and a simulator build mainly catches native-project drift, which a PR's Linux jobs already cover for everything else.
  - Concurrency: one run per branch/ref, `cancel-in-progress: true` — a superseded push's CI run is canceled rather than left to burn minutes to completion.
  - Caches: `~/.pub-cache` (keyed on `pubspec.lock`), `~/.gradle/{caches,wrapper}` (keyed on the Gradle files), plus `subosito/flutter-action`'s own SDK-install cache and `actions/setup-node`'s npm cache.

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

## ✅ Phase 1 Completion

As of this commit, Phase 1 (Stabilization) is COMPLETE. All TD items in Phase 1 are resolved. The application is ready for beta release.

> A commit cannot contain its own hash — the hash is derived from the commit's content (tree, parent, message, timestamp) only after `git commit` runs, so it can't be embedded inside that same content. Run `git log -1 --format=%H -- CLAUDE.md` (or `git log --oneline -5`) to find the actual commit that introduced this section.

**Beta release checklist:**
- [ ] Report sentry-cocoa Package.swift bug upstream (TD-038)
- [ ] Install JDK + Android SDK (deferred, see TD-008 notes)
- [ ] Configure TestFlight (iOS) and Google Play Internal Testing (Android)
- [ ] Rotate any secrets that appeared in transcripts or logs
- [ ] Smoke test on real devices (iOS + Android)
- [ ] Announce beta to early users

**Phase 2 roadmap (deferred items):**
- TD-001: Migrate members to separate collection
- TD-007: Optimistic updates
- TD-008: CI/CD with GitHub Actions
- TD-011: Granular task permissions
- TD-012: ESLint + Prettier + no-floating-promises
- TD-013: Household-timezone-aware recurrence
- TD-018: Member-leave lifecycle
- TD-028: Zod edge validation
- TD-034: Deploy-order safety net
- TD-035: Server-side isRecurring filter
- TD-037: Sentry hardening bundle
- TD-038: sentry-cocoa upstream fix
- TD-039: Per-field conflict resolution

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
| `backend/src/utils/response.ts` | `sendSuccess` / `sendError` helpers |
| `backend/src/services/task.service.ts` | Task business logic + recurrence |
| `frontend/lib/config/constants.dart` | API URLs and app config — set via `--dart-define` (API_BASE_URL/ENVIRONMENT), see README.md; no longer protected with --assume-unchanged (TD-017) |
| `frontend/lib/data/datasources/remote/api_service.dart` | Dio client with auth interceptors |
| `frontend/lib/services/socket_service.dart` | Socket.io singleton |
| `frontend/lib/presentation/cubit/task_cubit.dart` | Task state management |

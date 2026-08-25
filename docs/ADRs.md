# Architecture Decision Records (ADRs)

Document key architectural decisions here. Format: Context → Decision → Consequences.

<a id="adr-001"></a>
### ADR-001: Monorepo structure
- **Context:** Need backend and frontend to evolve together with shared context.
- **Decision:** Single repository with `backend/` and `frontend/` folders.
- **Consequences:** Easier to keep API contracts in sync, single CI/CD pipeline, but larger repo size.

<a id="adr-002"></a>
### ADR-002: Socket.io with Redis adapter
- **Context:** Realtime sync across multiple server instances requires pub/sub.
- **Decision:** Use Socket.io with Redis adapter so events broadcast across all instances.
- **Consequences:** Requires Redis dependency, but enables horizontal scaling.

<a id="adr-003"></a>
### ADR-003: Cubits over Blocs in Flutter
- **Context:** State management needed. Blocs add boilerplate with events. Cubits are simpler.
- **Decision:** Use Cubits (`flutter_bloc`) for state management.
- **Consequences:** Less boilerplate, easier to test, but less structured for complex event flows.

<a id="adr-004"></a>
### ADR-004: JWT with refresh token rotation
- **Context:** Need secure auth for mobile app with long-lived sessions.
- **Decision:** Short-lived access tokens (15m) + long-lived refresh tokens (7d) with rotation on use.
- **Consequences:** More complex auth flow, but better security. Refresh tokens stored in DB and invalidated on use. Refresh tokens are stored SHA-256 hashed (not raw) so a database leak does not yield usable sessions; SHA-256 chosen over bcrypt because JWTs are already high-entropy and bcrypt would add latency to every refresh.

<a id="adr-005"></a>
### ADR-005: Embedded members in Household — SUPERSEDED (2026-08-25)
- **Status:** **Superseded by the `HouseholdMember` collection.** TD-001 completed the migration on 2026-08-25; this record is kept for the history of why the embedded form existed, not as current design.
- **Context:** Initial MVP embedded members array in Household document for simplicity.
- **Decision (original):** Keep embedded for MVP, but plan migration to separate `HouseholdMember` collection.
- **Consequences (original):** Simple reads for MVP, but will hit MongoDB 16MB document limit with large households.
- **What replaced it:** membership is a document in `householdmembers` (`{householdId, userId, role, joinedAt}`), unique on `{householdId, userId}`. The API contract did NOT change — `serializeHousehold` composes the same `members: [{user, role, joinedAt}]` array from the collection, sorted by `joinedAt` so member lists do not reshuffle — which is what let the Flutter client stay a complete no-op through a migration it could not have been rolled back for.
- **The part worth remembering:** the embedded array was not the only copy. `User.households` held the same edge from the other side and fed the socket handshake's room resolution, so the migration had to remove TWO denormalizations, not one; and `User.households` also shipped in the auth response, where the client picks its active household — a dependency the design had not recorded and which nearly broke released apps. Both fields were `$unset` from stored documents on 2026-08-25 (see docs/TECH_DEBT.md).
- **The other lesson:** the embedded array was incidentally providing a write conflict that serialized concurrent removals, which is what kept Hard Rule 9 atomic. Removing it silently removed that protection; `removeMemberInTransaction` now writes the household document on purpose to keep it.

<a id="adr-006"></a>
### ADR-006: Timezone strategy for dates and recurrence
- **Context:** Recurring tasks, dueDate and the ±1-day anti-duplicate guard are ambiguous without a defined timezone.
- **Decision:** Store ALL timestamps in UTC (MongoDB Date). Compute recurrence and the ±1-day guard in UTC for now. Frontend displays dates in the device's local timezone. Households will gain a `timeZone` field (IANA string, default = creator's TZ at creation) and recurrence computation will migrate to household TZ in Phase 2.
- **Consequences:** Consistent behavior across devices and DST changes today; known UX edge case (a "daily at 9am" task drifts on DST change) until TD-013 is implemented.

<a id="adr-007"></a>
### ADR-007: Idempotency-Key semantics (replay and concurrency)
- **Context:** Dio 401-retries and socket reconnects can duplicate write POSTs; two identical requests can also race in parallel.
- **Decision:** POSTs that create resources accept an `Idempotency-Key` header. Backend acquires the key in Redis with `SET <key> <placeholder> NX EX <ttl>` BEFORE creating the resource. If SET NX fails: stored value is a completed result → return the original resource with HTTP 200 and do NOT re-emit socket events; stored value is in-progress → poll up to 2s for completion, then return the original with 200; timeout → 409 Conflict. Frontend generates one stable UUID per logical operation (surviving 401 retries) and NEVER auto-retries a 409. The header is optional during the migration window; the Flutter client starts sending it in Prompt 1.5; making it mandatory on household-scoped POSTs is a candidate hard rule once the client ships. Keys are scoped server-side per user and route before hashing (sha256(userId:route:key)) to prevent cross-user response poisoning; failed attempts call release() so a validation error never traps the client in 409 for the key TTL. The IdempotencyStore is failure-tolerant by design: on any store failure (Redis outage, timeout, exception) the middleware fail-opens and processes the request without idempotency, logging a security-grade warning. Idempotency is a correctness improvement, not a requirement; its absence MUST NOT cause a write outage.
- **Consequences:** prevents duplicates on retry and on race; requires storing the serialized result in Redis with TTL; 409 is a safe terminal response for clients.

<a id="adr-008"></a>
### ADR-008: Forward-only cursor pagination with full sort-position encoding
- **Context:** List endpoints must paginate without skipping/duplicating rows under a compound sort (status, dueDate, _id).
- **Decision:** Cursor is an opaque base64 token encoding the full sort position (status, dueDate, _id), not just _id. Only forward direction is implemented (YAGNI): the mobile UX is infinite scroll down + pull-to-refresh that resets pagination; backward mode will be added only if a real use case appears.
- **Consequences:** Correct paging under compound sort; simpler client; total requires a separate countDocuments query. total is returned only on the first page (no cursor); paged requests return total: null to avoid a redundant countDocuments per page.

<a id="adr-009"></a>
### ADR-009: Edge validation, raw storage, escape at render
- **Context:** The first sanitization batch HTML-escaped text at storage time; Flutter renders user text with Text(), which does not interpret markup, so storage escaping degraded UX (users saw "Tom &amp; Jerry") without adding mobile security.
- **Decision:** Store user text raw after trim + length limits; NoSQL injection is blocked by express-mongo-sanitize at the edge; HTML escaping is a presentation concern to be applied at render time, only if a web client ever ships.
- **Consequences:** Correct UX on mobile today; a future web frontend MUST escape at render; Zod edge validation (TD-028, resolved) centralizes and strengthens shape/format validation for tasks, households, and auth. It does NOT replace `express-mongo-sanitize` (still active in `app.ts`) or require an Express 5 migration (still on Express 4) — that part of the original plan is unimplemented; Zod and mongo-sanitize currently run as complementary layers (shape/format vs. NoSQL-operator stripping).

<a id="adr-010"></a>
### ADR-010: Offline-first with last-write-wins conflict resolution
- **Context:** TD-003 — mobile connectivity in the field is unreliable (elevators, subways, poor rural coverage). Users need to keep creating/editing tasks and shopping items while offline and have those changes reconciled once the device reconnects, without a second backend contract just for offline sync.
- **Decision:** `TaskRepository`/`ShoppingRepository` read cache-first with a live-server fallback, backed by Hive via hand-written `TypeAdapter`s (`hive_generator`'s last-published version pins an `analyzer` range that conflicts with `bloc_test`'s, so codegen was dropped for this project — see `pubspec.yaml`). A write made offline, or during any network-shaped failure (`NetworkFailure`, or a `ServerFailure` with no/≥500 status — see `isOfflineWorthy()`), is applied optimistically to the cache with `isSynced: false` and queued as a `PendingOperation` (create/update/delete). `TaskCubit`/`ShoppingCubit.syncPending()` replays the queue FIFO, automatically on `ConnectivityService`'s false→true transition. No merge or version-vector logic exists: a queued write simply POSTs/PATCHes its payload against whatever the server holds at replay time, so the last write that actually reaches the server wins — the same overwrite-on-update semantics MongoDB already has, requiring no backend change.
- **Consequences:** Simple, fully client-side, and testable without touching the backend; but two devices editing the SAME task while both offline can silently lose one device's edit once both reconnect (tracked as TD-039). A replay that fails for a non-network reason retries up to 3 times across sync passes before being dropped and reported to Sentry, so one permanently-invalid queued write cannot block everything queued after it. Acceptable for Phase 1 given HomeSync's household size (2-6 people) and low concurrent-edit frequency; CRDT/OT is deferred until real conflict reports justify the added complexity.

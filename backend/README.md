# HomeSync — Backend

REST + realtime API for HomeSync, a household organization app for couples/families.

**Stack:** Node.js · Express · TypeScript (strict) · MongoDB (Mongoose) · Redis (ioredis) · Socket.io (Redis adapter) · JWT auth.

## Setup

```bash
cd backend
npm install
cp .env.example .env   # then fill in MONGODB_URI, JWT secrets, REDIS_URL
npm run dev            # nodemon + ts-node on http://localhost:3000
```

Other scripts:

- `npm run build` — compile TypeScript to `dist/`
- `npm start` — run the compiled server (`node dist/app.js`)
- `npm run typecheck` — strict type check without emitting
- `npx ts-node src/scripts/seed.ts` — seed demo data (idempotent): user
  `test@test.com` / `password123`, household "Casa de prueba" (invite code
  `CASADEMO`), 5 tasks (2 recurring), 3 shopping items

## API docs

Interactive Swagger UI is served at **`/api/docs`** (OpenAPI 3.0).

## Deployment (Railway)

The repo ships a `backend/Dockerfile` (multi-stage, Node 20-alpine) and a
root `railway.toml` configured for the `DOCKERFILE` builder. Railway builds
with the repo root as context and starts the app with
`node backend/dist/app.js` on port 3000. Set the environment variables from
the table above in the Railway service.

### Environment variables

| Var                  | Description                                             |
| -------------------- | ------------------------------------------------------- |
| `PORT`               | HTTP port (default 3000)                                |
| `MONGODB_URI`        | MongoDB connection string (Atlas or local)              |
| `JWT_SECRET`         | Access-token signing secret (≥ 32 chars)                |
| `JWT_REFRESH_SECRET` | Refresh-token signing secret (≥ 32 chars)               |
| `JWT_ACCESS_EXPIRES` | Access-token lifetime (default `15m`)                   |
| `JWT_REFRESH_EXPIRES`| Refresh-token lifetime (default `7d`)                   |
| `REDIS_URL`          | Redis connection URL                                    |
| `CORS_ORIGINS`       | Comma-separated allowed origins (empty = allow `*`)     |
| `FIREBASE_SERVICE_ACCOUNT` | Firebase service account JSON, as a **string** (not a file) — enables push notifications (PDR-008). Absent = feature disabled, no-op (see [Push notifications](#push-notifications-fcm-pdr-008)) |

## Response envelope

Every endpoint responds with:

```json
{ "success": true,  "data": { ... } }
{ "success": false, "error": "message" }
```

## Auth

- Access token: JWT, 15 min, payload `{ userId, email }`, sent as `Authorization: Bearer <token>`.
- Refresh token: JWT, 7 days, persisted in the `refreshtokens` collection (rotated on use, deleted on logout).
- Credential endpoints (`/register`, `/login`) are rate-limited to 5 requests / 15 min / IP.
- Failed login/register return a generic message and never reveal whether an email exists.

### Endpoints

| Method | Path                 | Auth | Body                       |
| ------ | -------------------- | ---- | -------------------------- |
| POST   | `/api/auth/register` | —    | `{ email, password, name }`|
| POST   | `/api/auth/login`    | —    | `{ email, password }`      |
| POST   | `/api/auth/refresh`  | —    | `{ refreshToken }`         |
| POST   | `/api/auth/logout`   | —    | `{ refreshToken }`         |
| GET    | `/api/auth/me`       | ✔    | —                          |

## Users

| Method | Path             | Body                  |
| ------ | ---------------- | --------------------- |
| GET    | `/api/users/me`  | —                     |
| PATCH  | `/api/users/me`  | `{ name?, avatarUrl? }` |

## Devices (push notifications, PDR-008)

| Method | Path                       | Auth | Body                              |
| ------ | -------------------------- | ---- | ---------------------------------- |
| POST   | `/api/devices/register`    | ✔    | `{ token, platform: 'ios'\|'android' }` |
| DELETE | `/api/devices/:token`      | ✔    | —                                   |

Not household-scoped — a device token belongs to a user, who may belong to
several households. `register` upserts on `(userId, token)`; if `token`
already belonged to a different user (e.g. a shared device) that row is
deleted first, so the token always tracks whoever registered it most
recently. `DELETE` removes only the caller's own token and is idempotent
(no-op on an unknown or already-removed token). See
[Push notifications](#push-notifications-fcm-pdr-008) below for how these
tokens get used.

## Households

| Method | Path                                       | Notes                              |
| ------ | ------------------------------------------ | ---------------------------------- |
| POST   | `/api/households`                          | `{ name }` → creator becomes admin |
| POST   | `/api/households/join`                     | `{ inviteCode }`                   |
| GET    | `/api/households/:id`                       | members only, members populated    |
| GET    | `/api/households/:id/members`              | members only                       |
| DELETE | `/api/households/:id/members/:userId`      | admin only, can't remove last admin|

## Idempotency-Key (optional)

Resource-creating POSTs accept an optional `Idempotency-Key` header:
`POST /api/households`, `POST /api/households/join`,
`POST /api/households/:householdId/tasks`, `POST /api/households/:householdId/shopping`,
`POST /api/devices/register`.

| Situation                                   | Response                                          |
| ------------------------------------------- | ------------------------------------------------- |
| No header                                    | Unchanged behaviour — every call creates          |
| First call with key K                        | `201` with the created resource                   |
| Repeat of K, original finished               | `200` with the **stored** body; nothing recreated, no socket event re-emitted |
| Repeat of K while the original is in flight  | Waits up to 2s for the result, then `200`; `409` if it never arrives |
| Original failed (4xx/5xx)                    | Key released, so the same K can be retried        |

Send one stable UUID per logical user action and reuse it across retries
(including retries after a 401 refresh). Keys are scoped per user and route,
stored hashed, and expire after 24h. Never auto-retry a `409`. See ADR-007.

## Cursor pagination

List endpoints return a page object instead of a bare array:

```json
{
  "success": true,
  "data": {
    "items": [ /* ... */ ],
    "nextCursor": "eyJzIjoicGVuZGluZyIsImQiOm51bGwsImlkIjoiNjZi..." ,
    "hasMore": true,
    "total": 23
  }
}
```

- `total` counts every row matching the filter and is returned **only on the first
  page** (no `cursor`); paged requests get `total: null` to avoid an identical
  `countDocuments` on every scroll step.
- `hasMore` is true when rows exist after this page; when false, `nextCursor` is `null`.
- `cursor` is **opaque**: base64 JSON encoding the full sort position, not just an id.
  Clients must pass it back verbatim and never construct or parse one.
- Forward-only: fetch the next page with `?cursor=<nextCursor>`; to restart, omit it.
  See ADR-008 in the root `CLAUDE.md`.

## Tasks (household-scoped)

| Method | Path                                                        |
| ------ | ---------------------------------------------------------- |
| GET    | `/api/households/:householdId/tasks?status=&limit=&cursor=` |
| POST   | `/api/households/:householdId/tasks`                       |
| PATCH  | `/api/households/:householdId/tasks/:taskId`               |
| PATCH  | `/api/households/:householdId/tasks/:taskId/complete`      |
| DELETE | `/api/households/:householdId/tasks/:taskId`               |
| POST   | `/api/households/:householdId/tasks/purge?days=`           |

Listing order: pending tasks first, then by `dueDate` ascending (`_id` descending
breaks ties).

`GET` is **paginated** — see [Cursor pagination](#cursor-pagination). Query params:

| Param    | Type   | Notes                                                       |
| -------- | ------ | ----------------------------------------------------------- |
| `status` | enum   | `pending` \| `completed`; combines with the cursor          |
| `limit`  | int    | default 50, min 1, max 100; out of range → 400              |
| `cursor` | string | opaque token from `nextCursor`; malformed → 400             |

`POST .../tasks/purge` is admin-only and hard-deletes soft-deleted tasks
older than `?days=` (default 30) — see [Trash purge](#trash-purge-td-048)
below for the equivalent script and cron setup.

## Shopping (household-scoped)

| Method | Path                                                          |
| ------ | ------------------------------------------------------------ |
| GET    | `/api/households/:householdId/shopping`                      |
| POST   | `/api/households/:householdId/shopping`                      |
| PATCH  | `/api/households/:householdId/shopping/:itemId`              |
| PATCH  | `/api/households/:householdId/shopping/:itemId/purchase`     |
| DELETE | `/api/households/:householdId/shopping/:itemId`              |

Listing order: not-purchased items first, then newest first (`_id` descending).

`GET` is **paginated** — see [Cursor pagination](#cursor-pagination). Query params:

| Param    | Type   | Notes                                            |
| -------- | ------ | ------------------------------------------------ |
| `limit`  | int    | default 50, min 1, max 100; out of range → 400   |
| `cursor` | string | opaque token from `nextCursor`; malformed → 400  |

## Trash purge (TD-048)

TD-046's soft delete (`isDeleted`/`deletedAt` on Task) never removes the
document, only hides it — with no cleanup, the `tasks` collection
accumulates deleted rows forever. Two ways to purge trash older than a
retention window, sharing the same query
(`taskService.purgeDeletedTasks`, `isDeleted: true, deletedAt: { $lt: cutoff }`):

- **`POST /api/households/:householdId/tasks/purge?days=`** — admin-only,
  scoped to one household. Used by the "Vaciar papelera" button in the
  frontend's Papelera view. `days` defaults to 30; responds
  `{ deleted: <count> }`. Broadcasts `tasks:purged` when anything was
  actually deleted.
- **`src/scripts/purge-trash.ts`** — global (every household), meant for a
  scheduled job:

  ```bash
  npx ts-node src/scripts/purge-trash.ts            # purge trash older than 30 days
  npx ts-node src/scripts/purge-trash.ts --days 60   # custom retention window
  ```

  Logs how many tasks were purged. Safe to run repeatedly — nothing left to
  purge just logs 0 and exits cleanly.

### Scheduling the script on Railway (optional)

Railway supports **Cron Jobs** as a service type, separate from the main web
service:

1. In the Railway project, add a new service → **Cron Job**, pointing at the
   same repo/image as the backend service (or a dedicated Dockerfile target
   that just runs the script).
2. Set its start command to
   `node backend/dist/scripts/purge-trash.js --days 30` (compiled output —
   `npm run build` already emits `scripts/` alongside the rest of `dist/`).
3. Set the same `MONGODB_URI` environment variable as the main backend
   service (the script only touches MongoDB — no Redis, no HTTP).
4. Set a daily schedule, e.g. `0 3 * * *` (03:00 UTC, low-traffic window).

This is optional: the admin-only HTTP endpoint above works standalone
without any cron configured, for a household that wants to purge on demand.

## Realtime (Socket.io)

Connect with the access token: `io(url, { auth: { token } })`. On connect the
socket joins a room per household (`household_<id>`). Uses the Redis adapter so
events broadcast across every server instance.

Server → client events (scoped to `household_<id>`):

- `task:created`, `task:updated`, `task:completed`, `task:deleted`, `tasks:purged`
- `shopping:created`, `shopping:updated`, `shopping:purchased`, `shopping:deleted`
- `household:member_joined`, `household:member_left`

Client → server events: `household:join`, `household:leave` (re-join a room
after creating/joining a household without reconnecting).

## Push notifications (FCM, PDR-008)

`notification.service.ts` sends via Firebase Admin, initialized lazily from
`FIREBASE_SERVICE_ACCOUNT` — same no-op-when-unconfigured pattern as Sentry
(TD-009): missing or malformed JSON disables the feature without breaking
anything else. Two triggers, both fire-and-forget (a notification failure
never fails the task write):

- Creating a task pushes every assignee other than whoever created it
  ("Nueva tarea asignada").
- Completing a task pushes the creator, if someone else completed it
  ("Tarea completada").

Device tokens are managed via the [Devices](#devices-push-notifications-pdr-008)
endpoints above.

### Railway setup

1. Create a Firebase project and a service account with the **Firebase
   Cloud Messaging API** enabled (Firebase Console → Project Settings →
   Service Accounts → Generate new private key). This downloads a
   `firebase-service-account.json` file — **do not commit it**.
2. In Railway: your service → **Variables** → **New Variable** → name
   `FIREBASE_SERVICE_ACCOUNT` → paste the **entire JSON file content** as
   the value (as a single-line or multi-line string, Railway accepts both —
   this backend does `JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT)`).
3. Redeploy. `notification.service.ts` picks it up on the next cold start
   (the Firebase Admin app is initialized once, lazily, on the first push
   attempt).

Without this variable set, every push notification silently no-ops — task
creation/completion still work normally, they just don't notify anyone. See
`frontend/README.md`'s "Push notifications (FCM) setup" (TD-049) for the
additional mobile-side (Android/iOS) setup this feature needs before pushes
are actually delivered to a device.

## Project layout

```
src/
├── config/       database.ts · redis.ts · socket.ts
├── models/       User · Household · Task · ShoppingItem · RefreshToken · DeviceToken
├── controllers/  auth · household · task · shopping · user · device
├── middleware/   auth.middleware · error.middleware
├── routes/       auth · household · task · shopping · user · device
├── services/     auth · household · task · shopping · notification
├── types/        index.ts
├── utils/        jwt · response · logger · asyncHandler · toJSON
└── app.ts        entry point
```

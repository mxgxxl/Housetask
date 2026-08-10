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

## Households

| Method | Path                                       | Notes                              |
| ------ | ------------------------------------------ | ---------------------------------- |
| POST   | `/api/households`                          | `{ name }` → creator becomes admin |
| POST   | `/api/households/join`                     | `{ inviteCode }`                   |
| GET    | `/api/households/:id`                       | members only, members populated    |
| GET    | `/api/households/:id/members`              | members only                       |
| DELETE | `/api/households/:id/members/:userId`      | admin only, can't remove last admin|

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

- `total` counts every row matching the filter, ignoring the cursor.
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

Listing order: pending tasks first, then by `dueDate` ascending (`_id` descending
breaks ties).

`GET` is **paginated** — see [Cursor pagination](#cursor-pagination). Query params:

| Param    | Type   | Notes                                                       |
| -------- | ------ | ----------------------------------------------------------- |
| `status` | enum   | `pending` \| `completed`; combines with the cursor          |
| `limit`  | int    | default 50, min 1, max 100; out of range → 400              |
| `cursor` | string | opaque token from `nextCursor`; malformed → 400             |

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

## Realtime (Socket.io)

Connect with the access token: `io(url, { auth: { token } })`. On connect the
socket joins a room per household (`household_<id>`). Uses the Redis adapter so
events broadcast across every server instance.

Server → client events (scoped to `household_<id>`):

- `task:created`, `task:updated`, `task:completed`, `task:deleted`
- `shopping:created`, `shopping:updated`, `shopping:purchased`, `shopping:deleted`
- `household:member_joined`, `household:member_left`

Client → server events: `household:join`, `household:leave` (re-join a room
after creating/joining a household without reconnecting).

## Project layout

```
src/
├── config/       database.ts · redis.ts · socket.ts
├── models/       User · Household · Task · ShoppingItem · RefreshToken
├── controllers/  auth · household · task · shopping · user
├── middleware/   auth.middleware · error.middleware
├── routes/       auth · household · task · shopping · user
├── services/     auth · household · task · shopping
├── types/        index.ts
├── utils/        jwt · response · logger · asyncHandler · toJSON
└── app.ts        entry point
```

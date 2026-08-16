# HomeSync

Organize household tasks and shopping with your partner or family, in realtime.

HomeSync is a mobile app (iOS/Android) backed by a Node.js API. Create a
household, invite people with a code, assign tasks, keep a shared shopping
list, care for a shared household pet, and see changes sync live across
devices.

## Monorepo layout

| Folder      | What it is                                                              |
| ----------- | ---------------------------------------------------------------------- |
| `backend/`  | Express + TypeScript API — auth, households, tasks, shopping, Socket.io |
| `frontend/` | Flutter app — clean/feature architecture with `flutter_bloc`           |

See [`backend/README.md`](backend/README.md) and
[`frontend/README.md`](frontend/README.md) for setup details.

## Stack

- **Backend:** Node.js, Express, TypeScript (strict), MongoDB (Mongoose),
  Redis (ioredis), Socket.io (Redis adapter), JWT auth, bcrypt,
  `express-rate-limit` (auth + global rate limiting), `firebase-admin`
  (push notifications, no-op until a Firebase project is configured — see
  [Configuración](#configuración)).
- **Frontend:** Flutter, `flutter_bloc` (Cubits), Dio (+ auto token refresh),
  `socket_io_client`, `shared_preferences`, Hive (offline cache),
  `table_calendar`, `flutter_local_notifications`, `firebase_messaging`
  (push notifications), `sentry_flutter`, `google_fonts` (Inter).
- **Deploy target:** Railway (backend, EU region — Amsterdam) + MongoDB Atlas
  (Paris) + Redis Cloud, chosen together to keep the whole request path
  inside the EU and minimize latency for Spain-based users; payments with
  Paddle are a future step.

## Quick start

```bash
# 1) Backend
cd backend
npm install
cp .env.example .env        # set MONGODB_URI, JWT secrets, REDIS_URL
npm run dev                 # http://localhost:3000

# 2) Frontend (separate terminal)
cd frontend
flutter create --org com.homesync --project-name homesync .   # native scaffolding
flutter pub get
flutter run --dart-define=ENVIRONMENT=development --dart-define=API_BASE_URL=http://localhost:3000
```

`API_BASE_URL` is set via `--dart-define`, not by editing
`frontend/lib/config/constants.dart` (TD-017) — the file needs no
machine-local edits and defaults to the production backend when the flag is
omitted. Common local values: `http://10.0.2.2:3000` (Android emulator),
`http://localhost:3000` (iOS simulator), or your machine's LAN IP (physical
device). See [`frontend/README.md`](frontend/README.md) for the full set of
`--dart-define` flags, including `SENTRY_DSN`.

## Core flow

Register → Login → Create household → share invite code → add task → get
notified when someone assigns you a task or completes one of yours → mark it
done → add a shopping item → mark purchased → check the household's
completion stats → adopt and care for a shared pet with coins earned from
completing tasks. Open on two devices and watch tasks, shopping, and the pet
stay in sync in realtime. Deleted tasks land in a recoverable trash
(Papelera) instead of disappearing immediately.

## Features recientes

Shipped today across PRs #15–#22:

- **Push notifications (PDR-008):** push notification when someone assigns
  you a task, or completes a task you created. Backend via Firebase Admin
  (`firebase-admin`); frontend via `firebase_messaging`. See
  [Configuración](#configuración) — delivering real pushes still needs a
  Firebase project connected manually.
- **Estadísticas del hogar (PDR-007):** completion rate, top completer, and
  per-member load breakdown, viewable from the Profile tab (30 días / Todo
  toggle).
- **Purge policy de papelera (TD-048):** tasks in the trash are purged
  permanently after 30 days by default — automatically via a scheduled
  script (`backend/src/scripts/purge-trash.ts`), or on demand via an
  admin-only endpoint.
- **Member-leave lifecycle (TD-018):** a departed or removed member's
  pending task assignments are automatically unassigned (tasks they created
  are preserved); the UI shows "Ex-miembro" instead of a stale avatar.

## Realtime events

The server broadcasts to a room per household (`household_<id>`):

- `task:created` · `task:updated` · `task:completed` · `task:deleted` ·
  `tasks:batch_created` (recurring catch-up) · `tasks:purged` (trash purge)
- `shopping:created` · `shopping:updated` · `shopping:purchased` ·
  `shopping:deleted`
- `household:member_joined` · `household:member_left`
- `pet:adopt_requested` · `pet:adopted` · `pet:adopt_cancelled` ·
  `pet:updated`

See `CLAUDE.md`'s Realtime section for the full payload shape of each event.

## Security

- **Rate limiting:** credential endpoints (`/api/auth/*`) at 5 requests /
  15 min / IP; every other `/api/*` route additionally limited globally to
  100 requests / 15 min / IP (never double-counted — `/api/auth/*` is
  exempt from the global counter since it already has the stricter limit).
- **CORS fail-fast:** in production, an empty `CORS_ORIGINS` (or a missing
  `MONGODB_URI` / a JWT secret under 32 characters) makes the server refuse
  to start, rather than silently degrading to `CORS_ORIGINS: '*'` or a
  forgeable secret.
- **Input validation:** every request body is validated at the edge with
  Zod schemas before it reaches a service.
- **Idempotency:** every resource-creating POST accepts an optional
  `Idempotency-Key` header, deduped via Redis, so a network retry can never
  create a duplicate.

## Configuración

**Backend** (`backend/.env`, see `backend/.env.example`):

| Variable | Required | Notes |
| --- | --- | --- |
| `MONGODB_URI` | Yes | MongoDB connection string |
| `JWT_SECRET` / `JWT_REFRESH_SECRET` | Yes | ≥32 characters each |
| `REDIS_URL` | Yes | Redis connection URL |
| `CORS_ORIGINS` | In production | Comma-separated allowed origins |
| `SENTRY_DSN` | No | Error tracking; absent = no-op |
| `FIREBASE_SERVICE_ACCOUNT` | No | Push notifications; absent = no-op, task flows work normally without it |

**Frontend** (`--dart-define` flags on `flutter run` / `flutter build`, not
`.env` files):

| Flag | Notes |
| --- | --- |
| `API_BASE_URL` | Backend host; defaults to the production Railway backend |
| `ENVIRONMENT` | `development` / `production` |
| `SENTRY_DSN` | Error tracking; absent = no-op |

**Configuración pendiente:** `FIREBASE_SERVICE_ACCOUNT` and a real Firebase
project connection (`google-services.json` / `GoogleService-Info.plist` /
Xcode Push Notifications capability) are required before push notifications
actually deliver to a device — this is a manual, external setup step, not
something the codebase can do on its own. See `IMPROVEMENTS.md` → "Configuración
pendiente" for the exact checklist.

## Notes

- All API responses use the envelope `{ success, data?, error? }`.
- See `CLAUDE.md` for the full AI-assistant guide (architecture, hard
  rules, tech debt registry) and `docs/PRODUCT_DECISIONS.md` for product
  decisions (PDRs).

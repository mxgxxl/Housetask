# HomeSync

Organize household tasks and shopping with your partner or family, in realtime.

HomeSync is a mobile app (iOS/Android) backed by a Node.js API. Create a
household, invite people with a code, assign tasks, keep a shared shopping
list, and see changes sync live across devices.

## Monorepo layout

| Folder      | What it is                                                              |
| ----------- | ---------------------------------------------------------------------- |
| `backend/`  | Express + TypeScript API — auth, households, tasks, shopping, Socket.io |
| `frontend/` | Flutter app — clean/feature architecture with `flutter_bloc`           |

See [`backend/README.md`](backend/README.md) and
[`frontend/README.md`](frontend/README.md) for setup details.

## Stack

- **Backend:** Node.js, Express, TypeScript (strict), MongoDB (Mongoose),
  Redis (ioredis), Socket.io (Redis adapter), JWT auth, bcrypt, rate limiting.
- **Frontend:** Flutter, `flutter_bloc` (Cubits), Dio (+ auto token refresh),
  `socket_io_client`, `shared_preferences`, `table_calendar`,
  `flutter_local_notifications`, `google_fonts` (Inter).
- **Deploy target:** Railway (backend); payments with Paddle are a future step.

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
flutter run
```

Point the app at the backend in `frontend/lib/config/constants.dart`
(`10.0.2.2` for the Android emulator, `localhost` for the iOS simulator, or
your LAN IP for a physical device).

## Core flow

Register → Login → Create household → share invite code → add task → complete
it → add shopping item → mark purchased. Open on two devices and watch tasks
and shopping stay in sync in realtime.

## Realtime events

The server broadcasts to a room per household (`household_<id>`):

- `task:created` · `task:updated` · `task:completed` · `task:deleted`
- `shopping:created` · `shopping:updated` · `shopping:purchased` · `shopping:deleted`
- `household:member_joined` · `household:member_left`

## Notes

- Firebase is **not** used for Auth/Firestore/Realtime DB — only Firebase
  Cloud Messaging is planned later for remote push. Local reminders already
  fire one hour before a task's due date.
- All API responses use the envelope `{ success, data?, error? }`.

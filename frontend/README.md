# HomeSync — Flutter app

Mobile client (iOS/Android) for HomeSync. Clean, feature-based architecture
with `flutter_bloc` (Cubits), Dio, and Socket.io for realtime sync.

## Requirements

- Flutter SDK ≥ 3.10 (Dart ≥ 3.0)
- The HomeSync backend running (see `../backend`)

## First-time setup

This repo contains the app source (`lib/`), `pubspec.yaml`, and the
platform **customizations** for Phase 3. Because the Gradle wrapper and the
Xcode project include generated/binary files that aren't committed here,
generate the native scaffolding once, then the committed config files apply
on top:

```bash
cd frontend

# Generate the native platform scaffolding (gradle wrapper, Xcode project…).
# This keeps lib/, pubspec.yaml and the committed platform config files.
flutter create --org com.homesync --project-name homesync .

flutter pub get
flutter run
```

`flutter create .` will not overwrite `lib/` or `pubspec.yaml`. If it
regenerates a platform file, re-apply the Phase 3 settings below.

## Configuration

The backend URL and build environment are set via `--dart-define`, not by
editing source files — `lib/config/constants.dart` reads them through
`String.fromEnvironment` (TD-017) and is safe to commit as-is on every
machine, no `git update-index --assume-unchanged` needed.

### Running

Development (defaults shown are also what you get with no `--dart-define`
flags at all):

```bash
flutter run --dart-define=ENVIRONMENT=development --dart-define=API_BASE_URL=http://localhost:3000
```

Common `API_BASE_URL` values for local development:

- Android emulator: `http://10.0.2.2:3000` (maps to host machine's `localhost`)
- iOS simulator: `http://localhost:3000`
- Physical device: `http://<your-machine-LAN-IP>:3000`

Production (Railway backend):

```bash
flutter run --dart-define=ENVIRONMENT=production --dart-define=API_BASE_URL=https://housetask-production.up.railway.app
```

### Building releases

```bash
flutter build apk --release --dart-define=ENVIRONMENT=production --dart-define=API_BASE_URL=https://housetask-production.up.railway.app
flutter build ios --release --dart-define=ENVIRONMENT=production --dart-define=API_BASE_URL=https://housetask-production.up.railway.app
```

Sentry (`SENTRY_DSN`) is a separate, independent define — see
`services/sentry_service.dart` for why it's kept out of `AppConfig`. Append
`--dart-define=SENTRY_DSN=...` to any command above to enable error tracking.

## Architecture

```
lib/
├── main.dart / app.dart          Entry point + DI composition root
├── config/                       constants · theme · routes
├── core/                         errors (failures) · utils (ui helpers)
├── data/
│   ├── models/                   User · Member · Household · Task ·
│   │                             RecurrenceRule · ShoppingItem (fromJson/toJson)
│   ├── datasources/
│   │   ├── local/                SharedPreferences (tokens, user, household)
│   │   └── remote/               ApiService (Dio + auth/refresh interceptors)
│   └── repositories/             auth · household · task · shopping
├── presentation/
│   ├── cubit/                    AuthCubit · HouseholdCubit · TaskCubit ·
│   │                             ShoppingCubit · SocketCubit
│   ├── pages/                    splash · login · register · main shell ·
│   │                             home · tasks · task form · calendar ·
│   │                             shopping · shopping form · profile ·
│   │                             household setup
│   └── widgets/                  user avatar · task tile · common
└── services/                     socket_service · notification_service
```

### State management (Cubits)

- **AuthCubit** — check session, login, register, logout, update name.
- **HouseholdCubit** — active household, members, create/join/switch.
- **TaskCubit** — task CRUD, filtering, completion, realtime upserts.
- **ShoppingCubit** — shopping CRUD, mark purchased, realtime upserts.
- **SocketCubit** — connects Socket.io with the JWT, joins the household
  room, and forwards realtime events to the three cubits above.

### API client

`ApiService` (Dio) injects `Authorization: Bearer <token>`, transparently
refreshes on `401` (single-flight, retries the original request once), and
forces logout via `onSessionExpired` when the refresh fails.

### Realtime

`SocketService` (singleton) connects with `auth.token`, auto-reconnects with
backoff, and exposes `onTaskUpdated` / `onShoppingUpdated` /
`onHouseholdUpdated`. Completing a task on one device updates the other live.

## Theme

Indigo `#6366F1` / Violet `#8B5CF6` on Slate-50 `#F8FAFC`, Material 3, with
the Inter typeface via `google_fonts`.

## Phase 3 — Platform settings (already applied in committed files)

- **Android** (`android/app/build.gradle`, `AndroidManifest.xml`):
  `applicationId com.homesync.app`, `minSdkVersion 21`, INTERNET +
  notification permissions.
- **iOS** (`ios/Runner/Info.plist`): `NSLocalNotificationUsageDescription`;
  set the Bundle Identifier to `com.homesync.app` in Xcode.
- **Notifications** (`services/notification_service.dart`): schedules a local
  reminder **1 hour before** a task's `dueDate`. Remote push (FCM) is left as
  a future step — no Firebase Auth/Firestore is used.

## Offline support (TD-003)

Tasks and shopping items are cached in Hive and readable while offline.
Creates/updates/deletes made offline (or during a network-shaped failure) are
applied optimistically and queued; `TaskCubit`/`ShoppingCubit.syncPending()`
replays the queue automatically as soon as `ConnectivityService` reports the
device is back online. See ADR-010 in the root `CLAUDE.md` for the full design
(cache-first reads, the pending-operations queue, and why conflict resolution
is last-write-wins for now — TD-039).

## Known Issues

### sentry-cocoa version drift (TD-038)

`sentry_flutter` 8.14.2 ships a `Package.swift` that allows any `sentry-cocoa`
`8.x` (`from: "8.46.0"`), while its own `.podspec` pins exactly `8.46.0`. When
Swift Package Manager resolves the newest matching version instead of the
podspec's pin, it can land on a `sentry-cocoa` release (observed: 8.58.4)
whose Swift API has moved on — in this case `SentryBinaryImageCache` — which
breaks the plugin's iOS build.

**Workaround applied:** both `Package.resolved` files are pinned to `8.46.0`,
matching the podspec exactly. Re-pin on every `sentry_flutter` upgrade until
upstream tightens the `Package.swift` constraint to match the podspec.

**Not automated:** filing the upstream issue against `getsentry/sentry-cocoa`
to ask for that constraint to be tightened is a human action (a GitHub
account and maintainer engagement) and is intentionally left as a manual
follow-up rather than something this codebase can do for you.

## Full end-to-end flow

Register → Login → Create household → copy invite code → add task → complete
it → add a shopping item → mark purchased. Open on two devices to see tasks
and shopping sync in realtime.

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

`API_BASE_URL` defaults to the production Railway backend — running
`flutter run` with no `--dart-define` flags at all talks to production, not
to a local server. Local development against a backend on your machine
requires an explicit override:

```bash
flutter run --dart-define=ENVIRONMENT=development --dart-define=API_BASE_URL=http://localhost:3000
```

Common `API_BASE_URL` values for local development:

- Android emulator: `http://10.0.2.2:3000` (maps to host machine's `localhost`)
- iOS simulator: `http://localhost:3000`
- Physical device: `http://<your-machine-LAN-IP>:3000`

Production (Railway backend — same as the zero-flags default, shown
explicitly here for build scripts that want both defines spelled out):

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
  reminder **1 hour before** a task's `dueDate`, plus remote push via FCM
  (PDR-008) for task assignment/completion — see "Push notifications (FCM)
  setup" under Known Issues for the manual Firebase project connection this
  still needs. No Firebase Auth/Firestore is used, only Cloud Messaging.

## Offline support (TD-003)

Tasks and shopping items are cached in Hive and readable while offline.
Creates/updates/deletes made offline (or during a network-shaped failure) are
applied optimistically and queued; `TaskCubit`/`ShoppingCubit.syncPending()`
replays the queue automatically as soon as `ConnectivityService` reports the
device is back online. See ADR-010 in the root `CLAUDE.md` for the full design
(cache-first reads, the pending-operations queue, and why conflict resolution
is last-write-wins for now — TD-039).

## Known Issues

### Push notifications (FCM) setup required (TD-049)

All the Dart-side code for push notifications is in place —
`NotificationService.requestPermission()` / `getToken()` / `registerToken()`
/ `listenForTokenRefresh()` / foreground + tapped-notification handling, and
`AuthCubit` calling into it on login/logout (PDR-008) — but this repo does
**not** ship a real Firebase project connection. Every FCM call degrades to
a caught, logged no-op (`Firebase.initializeApp()` failing in `main.dart` is
expected and harmless) until the following manual setup is done:

1. Create a Firebase project (console.firebase.google.com) and add two apps
   to it: Android with package `com.homesync.app`, iOS with bundle id
   `com.homesync.app` (both match the ids already configured in this repo,
   PDR-005 / the Deployment section of the root `CLAUDE.md`).
2. Run `flutterfire configure` from `frontend/` (or download the two config
   files by hand): places `android/app/google-services.json` and
   `ios/Runner/GoogleService-Info.plist`. **Neither file is committed here**
   — they are project-specific credentials, same reasoning as `.env` (Hard
   Rule 6).
3. Apply the Android Gradle plugin the config file needs: add
   `id "com.google.gms.google-services"` to `android/app/build.gradle`'s
   `plugins {}` block and the matching classpath to `android/build.gradle`
   (or `android/settings.gradle`'s plugin block, depending on which
   convention `flutterfire configure` picks for this AGP version — TD-041).
   **This repo intentionally does not apply it yet** — doing so without a
   real `google-services.json` present would hard-fail every Android build,
   including CI's `flutter build apk --debug` smoke test.
4. iOS: in Xcode, enable the **Push Notifications** capability and
   **Background Modes → Remote notifications** for the Runner target (adds
   entries to `Runner.entitlements`), then upload an APNs authentication key
   (or certificate) to the Firebase project's Cloud Messaging settings —
   FCM cannot deliver to iOS without one.
5. Backend: set `FIREBASE_SERVICE_ACCOUNT` (see `backend/README.md`) in
   Railway so the two triggers (task assigned / task completed) actually
   send.

None of this is automatable from a coding session — it requires real
Firebase and Apple Developer account access. Tracked as TD-049.

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

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

Point the app at your backend in `lib/config/constants.dart`:

- Android emulator: `http://10.0.2.2:3000` (default — maps to host localhost)
- iOS simulator: `http://localhost:3000`
- Physical device: `http://<your-machine-LAN-IP>:3000`

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

## Full end-to-end flow

Register → Login → Create household → copy invite code → add task → complete
it → add a shopping item → mark purchased. Open on two devices to see tasks
and shopping sync in realtime.

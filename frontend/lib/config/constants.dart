/// App-wide constants: API endpoints, socket URL, and storage keys.
///
/// `host` and `environment` are set via `--dart-define` (see
/// `frontend/README.md`), so this file needs no machine-local edits and is
/// safe to commit as-is (TD-017). The default `host` points at the
/// production Railway backend; local development against `localhost` (or a
/// LAN IP / Android emulator alias) requires an explicit
/// `--dart-define=API_BASE_URL=...` override — see `frontend/README.md`.
class AppConfig {
  AppConfig._();

  /// Host of the backend. Defaults to production; override with
  /// `--dart-define=API_BASE_URL=...` for local development (e.g.
  /// `http://localhost:3000`, or `http://10.0.2.2:3000` on the Android
  /// emulator).
  static const String host = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://housetask-production.up.railway.app',
  );

  /// REST API base URL.
  static const String baseUrl = '$host/api';

  /// Socket.io server URL (no /api suffix).
  static const String socketUrl = host;

  /// Request timeout.
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 15);

  /// Build environment flag. Override with `--dart-define=ENVIRONMENT=production`.
  static const String environment = String.fromEnvironment(
    'ENVIRONMENT',
    defaultValue: 'development',
  );

  static bool get isProduction => environment == 'production';
  static bool get isDevelopment => environment == 'development';
}

/// Keys used with SharedPreferences.
class StorageKeys {
  StorageKeys._();

  static const String accessToken = 'hs_access_token';
  static const String refreshToken = 'hs_refresh_token';
  static const String userJson = 'hs_user';
  static const String currentHouseholdId = 'hs_current_household';
}

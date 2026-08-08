/// App-wide constants: API endpoints, socket URL, and storage keys.
///
/// For local development on the Android emulator, `10.0.2.2` maps to the
/// host machine's `localhost`. For a physical device use your machine's LAN
/// IP (e.g. `http://192.168.1.20:3000`). iOS simulator can use `localhost`.
class AppConfig {
  AppConfig._();

  /// Host of the backend. Override per-environment as needed.
  static const String host = 'http://10.0.2.2:3000';

  /// REST API base URL.
  static const String baseUrl = '$host/api';

  /// Socket.io server URL (no /api suffix).
  static const String socketUrl = host;

  /// Request timeout.
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 15);
}

/// Keys used with SharedPreferences.
class StorageKeys {
  StorageKeys._();

  static const String accessToken = 'hs_access_token';
  static const String refreshToken = 'hs_refresh_token';
  static const String userJson = 'hs_user';
  static const String currentHouseholdId = 'hs_current_household';
}

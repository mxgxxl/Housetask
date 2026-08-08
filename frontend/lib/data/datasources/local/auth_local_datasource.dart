import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../config/constants.dart';
import '../../models/user.dart';

/// Persists auth tokens, the cached user, and the active household id in
/// SharedPreferences.
class AuthLocalDataSource {
  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    final prefs = await _prefs;
    await prefs.setString(StorageKeys.accessToken, accessToken);
    await prefs.setString(StorageKeys.refreshToken, refreshToken);
  }

  Future<String?> getAccessToken() async =>
      (await _prefs).getString(StorageKeys.accessToken);

  Future<String?> getRefreshToken() async =>
      (await _prefs).getString(StorageKeys.refreshToken);

  Future<void> saveUser(User user) async {
    final prefs = await _prefs;
    await prefs.setString(StorageKeys.userJson, jsonEncode(user.toJson()));
  }

  Future<User?> getUser() async {
    final raw = (await _prefs).getString(StorageKeys.userJson);
    if (raw == null) return null;
    try {
      return User.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveCurrentHouseholdId(String? id) async {
    final prefs = await _prefs;
    if (id == null) {
      await prefs.remove(StorageKeys.currentHouseholdId);
    } else {
      await prefs.setString(StorageKeys.currentHouseholdId, id);
    }
  }

  Future<String?> getCurrentHouseholdId() async =>
      (await _prefs).getString(StorageKeys.currentHouseholdId);

  Future<bool> hasSession() async => (await getAccessToken()) != null;

  /// Wipe all persisted auth state (used on logout).
  Future<void> clear() async {
    final prefs = await _prefs;
    await prefs.remove(StorageKeys.accessToken);
    await prefs.remove(StorageKeys.refreshToken);
    await prefs.remove(StorageKeys.userJson);
    await prefs.remove(StorageKeys.currentHouseholdId);
  }
}

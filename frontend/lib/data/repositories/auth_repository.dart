import '../datasources/local/auth_local_datasource.dart';
import '../datasources/remote/api_service.dart';
import '../models/user.dart';

/// Handles authentication + local session persistence.
class AuthRepository {
  final ApiService _api;
  final AuthLocalDataSource _local;

  AuthRepository(this._api, this._local);

  Future<User> _handleAuthResult(Map<String, dynamic> data) async {
    final tokens = data['tokens'] as Map<String, dynamic>;
    await _local.saveTokens(
      accessToken: tokens['accessToken'] as String,
      refreshToken: tokens['refreshToken'] as String,
    );
    final user = User.fromJson(data['user'] as Map<String, dynamic>);
    await _local.saveUser(user);
    return user;
  }

  Future<User> register({
    required String name,
    required String email,
    required String password,
  }) async {
    final data = await _api.post('/auth/register', body: {
      'name': name,
      'email': email,
      'password': password,
    });
    return _handleAuthResult(data as Map<String, dynamic>);
  }

  Future<User> login({required String email, required String password}) async {
    final data = await _api.post('/auth/login', body: {
      'email': email,
      'password': password,
    });
    return _handleAuthResult(data as Map<String, dynamic>);
  }

  /// Return the current user, preferring the network but falling back to cache.
  Future<User> getMe() async {
    final data = await _api.get('/auth/me');
    final user = User.fromJson(data as Map<String, dynamic>);
    await _local.saveUser(user);
    return user;
  }

  /// Update the current user's editable profile fields.
  Future<User> updateProfile({String? name, String? avatarUrl}) async {
    final data = await _api.patch('/users/me', body: {
      if (name != null) 'name': name,
      if (avatarUrl != null) 'avatarUrl': avatarUrl,
    });
    final user = User.fromJson(data as Map<String, dynamic>);
    await _local.saveUser(user);
    return user;
  }

  Future<User?> cachedUser() => _local.getUser();

  Future<bool> hasSession() => _local.hasSession();

  Future<void> logout() async {
    final refreshToken = await _local.getRefreshToken();
    if (refreshToken != null) {
      try {
        await _api.post('/auth/logout', body: {'refreshToken': refreshToken});
      } catch (_) {
        // Best-effort: clear locally even if the server call fails.
      }
    }
    await _local.clear();
  }
}

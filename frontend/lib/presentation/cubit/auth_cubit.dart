import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/errors/failures.dart';
import '../../data/models/user.dart';
import '../../data/repositories/auth_repository.dart';
import '../../services/cache_service.dart';
import '../../services/notification_service.dart';
import '../../services/sentry_service.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthState extends Equatable {
  final AuthStatus status;
  final User? user;
  final bool loading;
  final String? error;

  const AuthState({
    this.status = AuthStatus.unknown,
    this.user,
    this.loading = false,
    this.error,
  });

  AuthState copyWith({
    AuthStatus? status,
    User? user,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [status, user, loading, error];
}

/// Manages authentication state: session check, login, register, logout.
class AuthCubit extends Cubit<AuthState> {
  final AuthRepository _repo;
  final CacheService _cache;
  final NotificationService _notifications;

  AuthCubit(this._repo, {CacheService? cache, NotificationService? notifications})
      : _cache = cache ?? CacheService(),
        _notifications = notifications ?? NotificationService(),
        super(const AuthState());

  /// Called on startup (SplashPage) to decide the initial route.
  Future<void> checkAuth() async {
    final hasSession = await _repo.hasSession();
    if (!hasSession) {
      emit(state.copyWith(status: AuthStatus.unauthenticated));
      return;
    }

    // Optimistically use the cached user, then refresh from the network.
    final cached = await _repo.cachedUser();
    if (cached != null) {
      await _adoptCache(cached);
      emit(state.copyWith(status: AuthStatus.authenticated, user: cached));
    }

    try {
      final user = await _repo.getMe();
      // Cheap when `cached` already claimed it (same id, no wipe), and the
      // only claim that happens when there was no cached user to go on.
      await _adoptCache(user);
      emit(state.copyWith(status: AuthStatus.authenticated, user: user));
    } on Failure {
      if (cached == null) {
        emit(state.copyWith(status: AuthStatus.unauthenticated));
      }
    }
  }

  Future<void> login(String email, String password) async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final user = await _repo.login(email: email, password: password);
      // No email/password in the breadcrumb — just the flow marker; Sentry
      // breadcrumbs are for tracing what led up to an error, not for PII.
      SentryService.addBreadcrumb('User logged in', category: 'auth');
      await _adoptCache(user);
      emit(state.copyWith(status: AuthStatus.authenticated, user: user, loading: false));
    } on Failure catch (f) {
      SentryService.addBreadcrumb('Login failed', category: 'auth', data: {'reason': f.message});
      emit(state.copyWith(loading: false, error: f.message));
    }
  }

  Future<void> register(String name, String email, String password) async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final user = await _repo.register(name: name, email: email, password: password);
      await _adoptCache(user);
      emit(state.copyWith(status: AuthStatus.authenticated, user: user, loading: false));
    } on Failure catch (f) {
      emit(state.copyWith(loading: false, error: f.message));
    }
  }

  /// Called when the API layer reports the session can't be refreshed.
  void onSessionExpired() {
    emit(const AuthState(status: AuthStatus.unauthenticated));
  }

  /// Make the local cache belong to [user] before anything can read or replay
  /// it (TD-062).
  ///
  /// The cache and the pending-write queue outlive a session: an expired
  /// session clears the tokens but never touches Hive, so without this a
  /// different account signing in on the same device inherits the previous
  /// one's queue and `syncPendingOperations` replays it under the new token —
  /// against households the new user does not belong to, which 403s, burns its
  /// three retries and is dropped.
  ///
  /// Called from EVERY entry into an authenticated session (login, register
  /// and the checkAuth restore), and always BEFORE emitting `authenticated`:
  /// SplashPage reacts to that state by loading the household, and the
  /// connectivity listener can fire a sync at any moment. Doing this late
  /// would mean doing it after the replay it exists to prevent.
  ///
  /// Only wipes on a mismatch, so the same user returning after an expiry
  /// keeps their queued work — the promise TD-061 §4.3 relies on.
  Future<void> _adoptCache(User user) async {
    if (_cache.cacheBelongsToSomeoneElse(user.id)) {
      await _cache.clearAll();
    }
    await _cache.claimCache(user.id);
  }

  Future<void> logout() async {
    // Runs BEFORE _repo.logout() clears the stored access token: unregisterToken
    // needs it to authenticate the DELETE call (PDR-008). A device that never
    // registered a token, or a Firebase-less build, is a silent no-op.
    await _notifications.unregisterToken();
    await _repo.logout();
    // Wipe every cached task/shopping/household/pending-op — the next login
    // may be a different user, and offline writes queued under this session
    // must not silently replay onto whatever account signs in next (TD-003).
    await _cache.clearAll();
    emit(const AuthState(status: AuthStatus.unauthenticated));
  }

  void updateUser(User user) {
    emit(state.copyWith(user: user));
  }

  /// Update the display name (Profile page).
  Future<void> updateName(String name) async {
    try {
      final user = await _repo.updateProfile(name: name);
      emit(state.copyWith(user: user));
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    }
  }
}

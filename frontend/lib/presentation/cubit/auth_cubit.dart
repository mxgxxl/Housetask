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
      emit(state.copyWith(status: AuthStatus.authenticated, user: cached));
    }

    try {
      final user = await _repo.getMe();
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
      emit(state.copyWith(status: AuthStatus.authenticated, user: user, loading: false));
    } on Failure catch (f) {
      emit(state.copyWith(loading: false, error: f.message));
    }
  }

  /// Called when the API layer reports the session can't be refreshed.
  void onSessionExpired() {
    emit(const AuthState(status: AuthStatus.unauthenticated));
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

import 'dart:async';
import 'package:dio/dio.dart';
import '../../../config/constants.dart';
import '../../../core/errors/failures.dart';
import '../../../services/sentry_service.dart';
import '../local/auth_local_datasource.dart';

/// How a refresh attempt ended (TD-063).
///
/// The three values exist because the two the code used to have — a token or
/// `null` — could not express the third: "the server never answered". That
/// gap is the whole of TD-063, so the type is deliberately three-valued
/// rather than a nullable token plus a flag.
enum _RefreshStatus {
  /// The server issued a new pair.
  rotated,

  /// The server said 401: this refresh token is dead, and so is the session.
  rejected,

  /// We could not ask. No response, a 5xx, a rate limit, or a captive portal
  /// answering 200 with something that is not our API. The session is NOT
  /// known to be dead, so it must survive.
  unreachable,
}

class _RefreshOutcome {
  final _RefreshStatus status;

  /// Only set when [status] is [_RefreshStatus.rotated].
  final String? accessToken;

  const _RefreshOutcome.rotated(String this.accessToken)
      : status = _RefreshStatus.rotated;
  const _RefreshOutcome.rejected()
      : status = _RefreshStatus.rejected,
        accessToken = null;
  const _RefreshOutcome.unreachable()
      : status = _RefreshStatus.unreachable,
        accessToken = null;
}

/// Thin HTTP client over Dio.
///
/// - Injects `Authorization: Bearer <accessToken>` on every request.
/// - On a 401, transparently refreshes the token once and retries; if the
///   refresh fails it clears the session and invokes [onSessionExpired].
/// - Unwraps the `{ success, data, error }` envelope, returning `data` or
///   throwing a [Failure].
class ApiService {
  final AuthLocalDataSource _local;
  late final Dio _dio;

  /// Called when the session can no longer be refreshed (forces logout).
  void Function()? onSessionExpired;

  // De-duplicates concurrent refresh attempts.
  Completer<_RefreshOutcome>? _refreshCompleter;

  /// Interceptor-free client used only for the refresh call, so a 401 on the
  /// refresh cannot recurse. Injectable for the same reason as [_dio].
  final Dio? _refreshDio;

  /// [dio] and [refreshDio] are injectable so tests can swap the HTTP adapter;
  /// production always uses the configured instances built here.
  ApiService(this._local, {Dio? dio, Dio? refreshDio}) : _refreshDio = refreshDio {
    _dio = dio ??
        Dio(
          BaseOptions(
            baseUrl: AppConfig.baseUrl,
            connectTimeout: AppConfig.connectTimeout,
            receiveTimeout: AppConfig.receiveTimeout,
            headers: {'Content-Type': 'application/json'},
          ),
        );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _local.getAccessToken();
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: _onError,
      ),
    );
  }

  Future<void> _onError(DioException e, ErrorInterceptorHandler handler) async {
    final options = e.requestOptions;
    final isRefreshCall = options.path.contains('/auth/refresh');
    final alreadyRetried = options.extra['retried'] == true;

    if (e.response?.statusCode == 401 && !isRefreshCall && !alreadyRetried) {
      final outcome = await _refreshToken();
      if (outcome.status == _RefreshStatus.rotated) {
        options.extra['retried'] = true;
        options.headers['Authorization'] = 'Bearer ${outcome.accessToken}';
        try {
          final clone = await _dio.fetch(options);
          return handler.resolve(clone);
        } on DioException catch (err) {
          return handler.reject(err);
        }
      } else if (outcome.status == _RefreshStatus.rejected) {
        // The server said no: the session really is dead.
        await _local.clear();
        onSessionExpired?.call();
      } else {
        // Unreachable (TD-063). The session is NOT known to be dead, so it
        // survives: throwing the user back to the login screen over a lift,
        // a WiFi-to-cellular handoff or a backend deploy is a bug, not a
        // security measure. The next request will get its own 401 and try
        // again, by then with a working connection.
        //
        // A breadcrumb rather than a captured event on purpose: offline this
        // fires once per burst of requests, so capturing would guarantee
        // noise. As a breadcrumb it costs nothing until something else is
        // reported, and then the timeline says a refresh had failed first —
        // which is otherwise invisible, since the refresh call deliberately
        // runs on an interceptor-free Dio.
        SentryService.addBreadcrumb(
          'refresh unreachable — session kept',
          category: 'auth',
          data: {'path': options.path},
        );
      }
    }
    handler.next(e);
  }

  /// Attempt a token refresh, coalescing concurrent callers onto one request.
  ///
  /// Never retries (TD-063 §2). Rotation is not idempotent — the backend's
  /// `findOneAndDelete` makes the delete the claim — so replaying a refresh
  /// whose response we did not see lands on the server's replay-detection
  /// path: it raises a security warning on the very channel used for stolen
  /// refresh tokens, and revokes the token family, including the pair this
  /// client never received. The useful retry is free anyway: the next request
  /// gets its own 401 and refreshes again, by then with a working connection.
  Future<_RefreshOutcome> _refreshToken() async {
    if (_refreshCompleter != null) return _refreshCompleter!.future;

    final completer = Completer<_RefreshOutcome>();
    _refreshCompleter = completer;

    _RefreshOutcome finish(_RefreshOutcome outcome) {
      completer.complete(outcome);
      return outcome;
    }

    try {
      final refreshToken = await _local.getRefreshToken();
      if (refreshToken == null) {
        // Nothing to refresh with: dead for certain, no request to make.
        return finish(const _RefreshOutcome.rejected());
      }

      // Bare Dio (no interceptors) to avoid recursion.
      final bare = _refreshDio ?? Dio(BaseOptions(baseUrl: AppConfig.baseUrl));
      final res = await bare.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refreshToken': refreshToken},
      );

      final data = res.data?['data'] as Map<String, dynamic>?;
      final newAccess = data?['accessToken'] as String?;
      final newRefresh = data?['refreshToken'] as String?;

      if (newAccess != null && newRefresh != null) {
        await _local.saveTokens(accessToken: newAccess, refreshToken: newRefresh);
        return finish(_RefreshOutcome.rotated(newAccess));
      }

      // A 2xx that carries no token pair did not come from our API. The
      // canonical source is a captive portal answering 200 with HTML, which
      // throws nothing and would otherwise read as "the server refused us".
      return finish(const _RefreshOutcome.unreachable());
    } on DioException catch (e) {
      return finish(_classify(e));
    } catch (_) {
      // Anything else (a cast failure on a body that is not our envelope,
      // for instance) is the same situation: we did not get an answer we can
      // read, which is not the same as being told no.
      return finish(const _RefreshOutcome.unreachable());
    } finally {
      _refreshCompleter = null;
    }
  }

  /// Allowlist by design (TD-063 decision 3): **only** a 401 means the session
  /// is dead. Everything else — no response, 5xx, 429, and 403 included —
  /// means we could not ask.
  ///
  /// 403 sits on the safe side on purpose: the backend never answers 403 on
  /// `/auth/refresh` (every failure there is an `AppError(..., 401)`), so a
  /// 403 on that route comes from a proxy, a WAF or a captive portal, not
  /// from us.
  _RefreshOutcome _classify(DioException e) {
    return e.response?.statusCode == 401
        ? const _RefreshOutcome.rejected()
        : const _RefreshOutcome.unreachable();
  }

  // ---- Generic verbs (return the unwrapped `data`) ----

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _request(() => _dio.get(path, queryParameters: query));

  /// [headers] carries per-request metadata such as `Idempotency-Key`. It is
  /// part of the RequestOptions, so the 401-retry below replays the very same
  /// key instead of minting a new one — which is what makes the retry safe.
  Future<dynamic> post(String path, {Object? body, Map<String, String>? headers}) =>
      _request(() => _dio.post(path, data: body, options: Options(headers: headers)));

  Future<dynamic> patch(String path, {Object? body, Map<String, String>? headers}) =>
      _request(() => _dio.patch(path, data: body, options: Options(headers: headers)));

  Future<dynamic> delete(String path, {Object? body}) =>
      _request(() => _dio.delete(path, data: body));

  /// Execute a request, unwrap the envelope, and normalize errors.
  Future<dynamic> _request(Future<Response<dynamic>> Function() run) async {
    try {
      final res = await run();
      final data = res.data;
      if (data is Map<String, dynamic>) {
        if (data['success'] == true) return data['data'];
        throw ServerFailure(
          (data['error'] ?? 'Request failed') as String,
          statusCode: res.statusCode,
        );
      }
      return data;
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  Failure _mapDioError(DioException e) {
    final status = e.response?.statusCode;
    final body = e.response?.data;
    String message = 'Network error, please try again';

    if (body is Map && body['error'] is String) {
      message = body['error'] as String;
    } else if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      message = 'Connection timed out';
    } else if (e.type == DioExceptionType.connectionError) {
      message = 'Cannot reach the server';
    }

    // No response at all — offline, DNS failure, or a timeout before one
    // arrived — is what makes a cache-first repository fall back / queue.
    // Distinct from a genuine 4xx, which is the server's real answer and must
    // reach the caller as an error, not be swallowed into an offline write.
    if (e.response == null) {
      return NetworkFailure(message);
    }

    if (status == 401) return AuthFailure(message);
    if (status == 409) {
      // Idempotency-Key collision: the original request is still in flight.
      // Only 401 is ever retried automatically (see _onError); retrying a 409
      // would hammer the server while its twin is mid-write.
      return const ConflictFailure(
        'Operation already in progress, please try again in a moment',
      );
    }

    // 5xx only: a 4xx is an expected client outcome (bad input, not found,
    // conflict) and reporting every one would bury genuine server failures
    // under client noise — the same rule the backend applies in reverse.
    if (status != null && status >= 500) {
      // Same header the repositories set (a uuid v4, see e.g.
      // task_repository.dart's _uuid.v4()) — when present, it lets a 5xx in
      // Sentry be correlated with the exact write that failed and with the
      // backend's own idempotency-store logs for TD-033 (fail-open metrics).
      // Not every request carries one (GET/DELETE never do).
      final idempotencyKey = e.requestOptions.headers['Idempotency-Key'] as String?;
      SentryService.captureException(
        e,
        stackTrace: e.stackTrace,
        context: {
          'status': status,
          'path': e.requestOptions.path,
          if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
        },
      );
    }

    return ServerFailure(message, statusCode: status);
  }
}

import 'dart:async';
import 'package:dio/dio.dart';
import '../../../config/constants.dart';
import '../../../core/errors/failures.dart';
import '../local/auth_local_datasource.dart';

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
  Completer<String?>? _refreshCompleter;

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
      final newToken = await _refreshToken();
      if (newToken != null) {
        options.extra['retried'] = true;
        options.headers['Authorization'] = 'Bearer $newToken';
        try {
          final clone = await _dio.fetch(options);
          return handler.resolve(clone);
        } on DioException catch (err) {
          return handler.reject(err);
        }
      } else {
        // Refresh failed → session is dead.
        await _local.clear();
        onSessionExpired?.call();
      }
    }
    handler.next(e);
  }

  /// Attempt a token refresh, coalescing concurrent callers onto one request.
  Future<String?> _refreshToken() async {
    if (_refreshCompleter != null) return _refreshCompleter!.future;

    final completer = Completer<String?>();
    _refreshCompleter = completer;

    try {
      final refreshToken = await _local.getRefreshToken();
      if (refreshToken == null) {
        completer.complete(null);
        return null;
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
        completer.complete(newAccess);
        return newAccess;
      }
      completer.complete(null);
      return null;
    } catch (_) {
      completer.complete(null);
      return null;
    } finally {
      _refreshCompleter = null;
    }
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

    if (status == 401) return AuthFailure(message);
    if (status == 409) {
      // Idempotency-Key collision: the original request is still in flight.
      // Only 401 is ever retried automatically (see _onError); retrying a 409
      // would hammer the server while its twin is mid-write.
      return const ConflictFailure(
        'Operation already in progress, please try again in a moment',
      );
    }
    return ServerFailure(message, statusCode: status);
  }
}

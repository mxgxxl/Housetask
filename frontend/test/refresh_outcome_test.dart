import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/config/constants.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TD-063 — what the app concludes from a refresh that did not return a token.
///
/// The bug was never the `catch (_)`: it was that `String?` had two values for
/// three outcomes, so "the server said no" and "the server never answered"
/// collapsed into one, and a lift or a backend deploy logged the user out.
///
/// The pairs that matter here are the contrasting ones — a revoked token (a
/// real 401) against a network failure, and against a 5xx. Same interceptor,
/// same original request, opposite conclusions. If either half could be
/// deleted without a test going red, the round would have fixed nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AuthLocalDataSource local;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    local = AuthLocalDataSource();
    await local.saveTokens(accessToken: 'expired-access', refreshToken: 'stored-refresh');
  });

  /// The protected call always 401s first; [onRefresh] decides how the refresh
  /// attempt ends, which is the whole subject of this file.
  ///
  /// Returns the wired service plus a flag the caller can read to tell whether
  /// the session was declared dead.
  ({ApiService api, List<bool> expired, _ScriptedAdapter refreshAdapter}) buildApi({
    required ResponseBody Function() onRefresh,
    List<ResponseBody Function()>? protected,
  }) {
    final protectedAdapter = _ScriptedAdapter(
      protected ?? [() => _json({'success': false, 'error': 'Unauthorized'}, 401)],
    );
    final refreshAdapter = _ScriptedAdapter([onRefresh]);

    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = protectedAdapter;
    final refreshDio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = refreshAdapter;

    final api = ApiService(local, dio: dio, refreshDio: refreshDio);
    final expired = <bool>[];
    api.onSessionExpired = () => expired.add(true);
    return (api: api, expired: expired, refreshAdapter: refreshAdapter);
  }

  ResponseBody networkError() => throw DioException(
        requestOptions: RequestOptions(path: '/auth/refresh'),
        type: DioExceptionType.connectionError,
        error: 'Failed host lookup',
      );

  group('the server answered: the session is dead', () {
    test('a revoked refresh token (401) clears the session', () async {
      // The backend answers 401 to every refresh failure: expired, rotated
      // away, or revoked by replay detection. This is the ONLY outcome that
      // may log the user out, and the round's main risk is loosening it.
      final t = buildApi(
        onRefresh: () => _json({'success': false, 'error': 'Invalid or expired refresh token'}, 401),
      );

      await expectLater(t.api.get('/tasks'), throwsA(isA<Object>()));

      expect(await local.hasSession(), isFalse);
      expect(t.expired, [true]);
    });

    test('no stored refresh token is dead too — there is nothing to ask with',
        () async {
      // An access token with no refresh token beside it: the shape left by a
      // partially cleared session.
      SharedPreferences.setMockInitialValues({
        StorageKeys.accessToken: 'expired-access',
      });

      final t = buildApi(onRefresh: () => _json({'success': true}, 200));

      await expectLater(t.api.get('/tasks'), throwsA(isA<Object>()));

      expect(t.expired, [true],
          reason: 'no request was even made; this is not an unreachable server');
    });
  });

  group('we could not ask: the session survives', () {
    /// Every case here used to end in a logout. The assertion is the same
    /// three lines each time on purpose — what changes is only the reason the
    /// refresh failed, which is exactly the axis TD-063 is about.
    Future<void> expectSessionKept(ResponseBody Function() onRefresh) async {
      final t = buildApi(onRefresh: onRefresh);

      await expectLater(t.api.get('/tasks'), throwsA(isA<Object>()));

      expect(await local.hasSession(), isTrue,
          reason: 'the tokens must survive: nobody said they were invalid');
      expect(t.expired, isEmpty,
          reason: 'a lift is not an expiry');
    }

    test('a network failure keeps the session', () async {
      // The case that opened the TD: a real 401 followed by losing the
      // connection before the refresh completes.
      await expectSessionKept(networkError);
    });

    test('a 5xx keeps the session', () async {
      // Railway deploys on every push to main, so this window is real and it
      // hits every user whose access token expires inside it — the only case
      // where the bug fires for everyone at once.
      await expectSessionKept(() => _json({'success': false, 'error': 'Bad gateway'}, 502));
    });

    test('a 429 keeps the session', () async {
      // /auth/refresh counts against the global limiter (100 req/15 min/IP),
      // shared between real users behind carrier-grade NAT.
      await expectSessionKept(() => _json({'success': false, 'error': 'Too many requests'}, 429));
    });

    test('a 403 keeps the session — it never comes from our API', () async {
      // Decision 3: the backend answers 401 to every refresh failure, so a
      // 403 on that route is a proxy, a WAF or a captive portal.
      await expectSessionKept(() => _json({'success': false, 'error': 'Forbidden'}, 403));
    });

    test('a 200 with no token pair keeps the session (captive portal)',
        () async {
      // The case that throws nothing at all: hotel WiFi answering 200 to
      // everything. It used to read as "the server refused us".
      await expectSessionKept(() => _json({'success': true, 'data': {}}, 200));
    });
  });

  group('the happy path still works', () {
    test('a rotated pair retries the original request with the new token',
        () async {
      final protectedAdapter = _ScriptedAdapter([
        () => _json({'success': false, 'error': 'Unauthorized'}, 401),
        () => _json({'success': true, 'data': {'ok': true}}, 200),
      ]);
      final dio = Dio(BaseOptions(baseUrl: 'http://test'))
        ..httpClientAdapter = protectedAdapter;
      final refreshDio = Dio(BaseOptions(baseUrl: 'http://test'))
        ..httpClientAdapter = _ScriptedAdapter([
          () => _json({
                'success': true,
                'data': {'accessToken': 'fresh-access', 'refreshToken': 'fresh-refresh'},
              }, 200),
        ]);
      final api = ApiService(local, dio: dio, refreshDio: refreshDio);
      var expired = false;
      api.onSessionExpired = () => expired = true;

      final data = await api.get('/tasks');

      expect(data, {'ok': true});
      expect(expired, isFalse);
      expect(protectedAdapter.requests.last.headers['Authorization'],
          'Bearer fresh-access');
      expect(await local.getAccessToken(), 'fresh-access',
          reason: 'the rotated pair must be persisted, or the next request '
              'would 401 again');
    });
  });

  group('single-flight', () {
    test('two concurrent 401s share one refresh, and a later one can retry',
        () async {
      final t = buildApi(
        onRefresh: networkError,
        protected: [() => _json({'success': false, 'error': 'Unauthorized'}, 401)],
      );

      await Future.wait([
        t.api.get('/tasks').catchError((Object _) => null),
        t.api.get('/shopping').catchError((Object _) => null),
      ]);

      expect(t.refreshAdapter.calls, 1,
          reason: 'the completer coalesces the burst — two refreshes would be '
              'two chances to trip replay detection');

      // And the completer must have been released, or the session would be
      // stuck unable to ever refresh again — a worse bug than the one fixed.
      await t.api.get('/tasks').catchError((Object _) => null);
      expect(t.refreshAdapter.calls, 2);
      expect(await local.hasSession(), isTrue);
    });
  });
}

/// Replies from a scripted queue, repeating the last entry once exhausted, and
/// counts calls so the single-flight test can assert how many refreshes
/// actually went out.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.responses);

  final List<ResponseBody Function()> responses;
  final List<RequestOptions> requests = [];
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final build = calls < responses.length ? responses[calls] : responses.last;
    calls++;
    return build();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, int status) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

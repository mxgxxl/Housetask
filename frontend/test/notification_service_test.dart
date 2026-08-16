import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/config/constants.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every outgoing request and replies 201 to all of them — same
/// pattern as idempotency_key_test.dart / task_repository_cache_test.dart.
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({'success': true, 'data': {'message': 'Device registered'}}),
      201,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      StorageKeys.accessToken: 'token',
      StorageKeys.refreshToken: 'refresh-token',
    });
  });

  // NotificationService is a process-wide singleton (like SocketService), so
  // these tests share one instance — each test attaches its own freshly
  // built ApiService/adapter via attachApi() rather than relying on any
  // isolation between tests.
  group('NotificationService.registerToken (PDR-008)', () {
    test('does nothing and does not throw when no ApiService is attached', () async {
      // Deliberately runs before any attachApi() call in this file/isolate.
      await expectLater(
        NotificationService().registerToken(token: 'irrelevant'),
        completes,
      );
    });

    test('POSTs the token to /devices/register with an Idempotency-Key header', () async {
      final adapter = _RecordingAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
        ..httpClientAdapter = adapter;
      final api = ApiService(AuthLocalDataSource(), dio: dio);
      NotificationService().attachApi(api);

      await NotificationService().registerToken(token: 'device-token-abc');

      expect(adapter.requests, hasLength(1));
      final request = adapter.requests.single;
      expect(request.path, '/devices/register');
      expect(request.method, 'POST');
      expect(request.data, containsPair('token', 'device-token-abc'));
      expect(request.headers['Idempotency-Key'], isNotNull);
    });

    test('sends platform "android" by default and "ios" under debugDefaultTargetPlatformOverride', () async {
      final adapter = _RecordingAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
        ..httpClientAdapter = adapter;
      final api = ApiService(AuthLocalDataSource(), dio: dio);
      NotificationService().attachApi(api);

      await NotificationService().registerToken(token: 'token-android');
      expect(adapter.requests.single.data, containsPair('platform', 'android'));

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await NotificationService().registerToken(token: 'token-ios');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      expect(adapter.requests.last.data, containsPair('platform', 'ios'));
    });

    test('generates a distinct Idempotency-Key for every call', () async {
      final adapter = _RecordingAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
        ..httpClientAdapter = adapter;
      final api = ApiService(AuthLocalDataSource(), dio: dio);
      NotificationService().attachApi(api);

      await NotificationService().registerToken(token: 'token-1');
      await NotificationService().registerToken(token: 'token-2');

      final keys = adapter.requests.map((r) => r.headers['Idempotency-Key']).toSet();
      expect(keys, hasLength(adapter.requests.length));
    });
  });

  group('NotificationService.unregisterToken (PDR-008)', () {
    test('does not throw when no real FCM token is available (no Firebase project configured)', () async {
      final adapter = _RecordingAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
        ..httpClientAdapter = adapter;
      final api = ApiService(AuthLocalDataSource(), dio: dio);
      NotificationService().attachApi(api);

      // getToken() calls the real FirebaseMessaging.instance, which throws in
      // this test environment (no Firebase project wired up) — caught
      // internally and treated as "no token", so this must complete cleanly
      // without ever reaching the network.
      await expectLater(NotificationService().unregisterToken(), completes);
      expect(adapter.requests, isEmpty);
    });
  });
}

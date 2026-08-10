import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/config/constants.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/repositories/task_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every outgoing request and replies from a scripted queue, so the
/// test can inspect exactly which headers Dio put on the wire — including on
/// the retry the 401 interceptor performs.
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<ResponseBody Function()> responses;
  int _index = 0;

  _RecordingAdapter(this.responses);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final build = _index < responses.length ? responses[_index] : responses.last;
    _index++;
    return build();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, int status) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Real storage keys: a mismatched key silently yields a null token, which
    // would skip the refresh path entirely and make the retry test vacuous.
    SharedPreferences.setMockInitialValues({
      StorageKeys.accessToken: 'stale-token',
      StorageKeys.refreshToken: 'refresh-token',
    });
  });

  test('generates a distinct Idempotency-Key per create call', () async {
    final adapter = _RecordingAdapter([
      () => _json({
            'success': true,
            'data': {'id': 't1', 'householdId': 'h1', 'title': 'A', 'status': 'pending'},
          }, 201),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
      ..httpClientAdapter = adapter;
    final repo = TaskRepository(ApiService(AuthLocalDataSource(), dio: dio));

    await repo.create('h1', {'title': 'A'});
    await repo.create('h1', {'title': 'B'});

    final keys = adapter.requests.map((r) => r.headers['Idempotency-Key']).toList();
    expect(keys, hasLength(2));
    expect(keys[0], isNotNull);
    // Two distinct user actions must never share a key, or the second would
    // replay the first's response instead of creating anything.
    expect(keys[0], isNot(equals(keys[1])));
  });

  test('replays the SAME Idempotency-Key on the 401 refresh retry', () async {
    final adapter = _RecordingAdapter([
      // 1) create → 401, triggering the refresh flow
      () => _json({'success': false, 'error': 'Invalid or expired token'}, 401),
      // 2) retry of the original create succeeds
      () => _json({
            'success': true,
            'data': {'id': 't1', 'householdId': 'h1', 'title': 'A', 'status': 'pending'},
          }, 201),
    ]);
    // The refresh runs on its own interceptor-free client; scripting it here is
    // what lets the retry actually happen instead of the session being dropped.
    final refreshAdapter = _RecordingAdapter([
      () => _json({
            'success': true,
            'data': {'accessToken': 'fresh-token', 'refreshToken': 'fresh-refresh'},
          }, 200),
    ]);

    final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
      ..httpClientAdapter = adapter;
    final refreshDio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
      ..httpClientAdapter = refreshAdapter;
    final repo = TaskRepository(
      ApiService(AuthLocalDataSource(), dio: dio, refreshDio: refreshDio),
    );

    final task = await repo.create('h1', {'title': 'A'});

    final createRequests =
        adapter.requests.where((r) => r.path.contains('/tasks')).toList();
    final keys = createRequests.map((r) => r.headers['Idempotency-Key']).toSet();

    expect(task.id, 't1');
    // The 401 must actually have been retried, otherwise the assertion below
    // would be trivially true.
    expect(createRequests, hasLength(2));
    expect(refreshAdapter.requests, hasLength(1));
    // Both attempts of the SAME logical create carry one key: the retry reuses
    // the original RequestOptions instead of minting a new uuid.
    expect(keys, hasLength(1));
    expect(keys.single, isNotNull);
    // And the retry carries the refreshed bearer token.
    expect(createRequests.last.headers['Authorization'], 'Bearer fresh-token');
  });
}

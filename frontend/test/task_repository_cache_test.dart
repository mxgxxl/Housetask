import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/repositories/task_repository.dart';
import 'package:homesync/services/cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// TD-045: TaskRepository.list() used to call CacheService.saveTasks — a
/// full replace of the household's cache — on the first page of EVERY
/// list() call, including a status-filtered one (Pendientes/Completadas).
/// Since saveTasks() replaces rather than merges, visiting a status tab
/// silently evicted every task in the OTHER statuses from the offline
/// cache. Exercises the real TaskRepository + Hive-backed CacheService (not
/// FakeTaskRepository, which other tests use) since the bug lived in
/// exactly that integration, scripting HTTP responses the same way
/// idempotency_key_test.dart does.
class _RecordingAdapter implements HttpClientAdapter {
  final List<ResponseBody Function()> responses;
  int _index = 0;

  _RecordingAdapter(this.responses);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

Map<String, dynamic> _pageEnvelope(List<Map<String, dynamic>> items) => {
      'success': true,
      'data': {
        'items': items,
        'nextCursor': null,
        'hasMore': false,
        'total': items.length,
      },
    };

Map<String, dynamic> _taskJson(String id, {required String status}) => {
      'id': id,
      'householdId': 'h1',
      'title': 'Tarea $id',
      'status': status,
      'priority': 'medium',
      'category': 'other',
      'assignedTo': <dynamic>[],
      'isRecurring': false,
      'isDeleted': false,
    };

TaskRepository _repoWith(_RecordingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
    ..httpClientAdapter = adapter;
  return TaskRepository(ApiService(AuthLocalDataSource(), dio: dio));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('homesync_td045_test');
    await CacheService().init(testDirectory: tempDir.path);
  });

  tearDown(() async {
    await CacheService().clearAll();
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
      '1. a status=pending first page merges into the cache — previously '
      'cached completed tasks survive', () async {
    CacheService().saveTasks('h1', [
      buildTask('done1', completed: true),
      buildTask('pending1'),
    ]);

    final adapter = _RecordingAdapter([
      () => _json(_pageEnvelope([_taskJson('pending1', status: 'pending')]), 200),
    ]);
    await _repoWith(adapter).list('h1', status: 'pending');

    final cachedIds = CacheService().getTasks('h1').map((t) => t.id).toSet();
    expect(cachedIds, {'done1', 'pending1'});
  });

  test(
      '2. an UNFILTERED first page still replaces the cache — a task '
      'deleted server-side disappears from it', () async {
    CacheService().saveTasks('h1', [buildTask('a'), buildTask('b')]);

    final adapter = _RecordingAdapter([
      () => _json(_pageEnvelope([_taskJson('a', status: 'pending')]), 200),
    ]);
    await _repoWith(adapter).list('h1');

    expect(CacheService().getTasks('h1').map((t) => t.id), ['a']);
  });

  test(
      '3. a status-filtered page overwrites an existing id in place — no '
      'duplicate row for a task that changed status', () async {
    CacheService().saveTasks('h1', [buildTask('t1')]); // pending

    final adapter = _RecordingAdapter([
      () => _json(_pageEnvelope([_taskJson('t1', status: 'completed')]), 200),
    ]);
    await _repoWith(adapter).list('h1', status: 'completed');

    final cached = CacheService().getTasks('h1');
    expect(cached, hasLength(1));
    expect(cached.single.status, 'completed');
  });

  test(
      '4. the offline cache fallback still filters by status after a merge',
      () async {
    CacheService().saveTasks('h1', [
      buildTask('done1', completed: true),
      buildTask('pending1'),
    ]);

    // A 5xx maps to a ServerFailure isOfflineWorthy() treats as a cache-
    // fallback trigger, same as being genuinely offline (see
    // TaskRepository.list's doc comment).
    final adapter = _RecordingAdapter([
      () => _json({'success': false, 'error': 'down'}, 500),
    ]);
    final repo = _repoWith(adapter);
    final page = await repo.list('h1', status: 'completed');

    expect(repo.lastListWasFromCache, isTrue);
    expect(page.items.map((t) => t.id), ['done1']);
  });
}

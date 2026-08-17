import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/models/pending_operation.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/repositories/task_repository.dart';
import 'package:homesync/services/cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Durability of the Hive writers (TD-059).
///
/// These exercise the real [CacheService] methods against injected box
/// doubles, which is the only way to reach the failure branch: real Hive
/// gives no way to force a write error.
void main() {
  late FakeBox<Task> tasks;
  late FakeBox<PendingOperation> pending;

  setUp(() {
    tasks = FakeBox<Task>();
    pending = FakeBox<PendingOperation>();
    CacheService().debugInjectBoxes(tasks: tasks, pendingOperations: pending);
  });

  tearDown(() => CacheService().debugResetBoxes());

  PendingOperation op(String id) => PendingOperation(
        id: id,
        type: PendingOperationType.create,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        payload: const {'title': 'x'},
        timestamp: DateTime.utc(2026, 1, 1),
        idempotencyKey: 'key-$id',
      );

  Task task(String id) => Task(
        id: id,
        householdId: 'h1',
        title: 'T$id',
        status: 'pending',
        priority: 'medium',
        category: 'other',
        assignedTo: const [],
        isSynced: true,
      );

  group('the writers return a Future that reflects the write', () {
    test('saveTask resolves once the write succeeded', () async {
      await expectLater(CacheService().saveTask(task('a')), completes);
      expect(tasks.entries.keys, ['a']);
    });

    test('saveTask surfaces a write failure instead of swallowing it',
        () async {
      tasks.failWrites = true;

      await expectLater(CacheService().saveTask(task('a')), throwsA(anything));
      expect(tasks.entries, isEmpty,
          reason: 'a failed write must not appear to have landed');
    });

    test('addPendingOperation surfaces a write failure', () async {
      pending.failWrites = true;

      await expectLater(
          CacheService().addPendingOperation(op('a')), throwsA(anything));
      expect(pending.entries, isEmpty);
    });

    test('removePendingOperation surfaces a write failure', () async {
      await CacheService().addPendingOperation(op('a'));
      pending.failWrites = true;

      await expectLater(
          CacheService().removePendingOperation('a'), throwsA(anything));
      expect(pending.entries.keys, ['a'],
          reason: 'the entry is still queued if its removal never landed');
    });

    test('saveTasks reports failure even though it writes N entries',
        () async {
      tasks.failWrites = true;

      await expectLater(
          CacheService().saveTasks('h1', [task('a'), task('b')]),
          throwsA(anything));
    });
  });

  group('best-effort policy', bestEffortTests);

  group('writes stay visible synchronously (the TD-059 keystore trap)', () {
    // Hive applies a put to its in-memory keystore synchronously and returns
    // a Future only for the disk flush, so a caller that does not await still
    // observes the write. If any writer is ever rewritten with an `async`
    // body it would suspend at its first await and defer the write past the
    // caller's next synchronous read — which is exactly what broke 6 tests
    // during this migration. These lock that property down.
    test('saveTask is visible before its Future resolves', () {
      final pendingWrite = CacheService().saveTask(task('a'));

      expect(tasks.entries.keys, ['a'],
          reason: 'the write must land in memory without awaiting');
      return pendingWrite;
    });

    test('saveTasks is visible before its Future resolves', () {
      final pendingWrite = CacheService().saveTasks('h1', [task('a'), task('b')]);

      expect(tasks.entries.keys, ['a', 'b']);
      return pendingWrite;
    });

    test('addPendingOperation is visible before its Future resolves', () {
      final pendingWrite = CacheService().addPendingOperation(op('a'));

      expect(pending.entries.keys, ['a']);
      return pendingWrite;
    });
  });
}

/// Serves one canned HTTP response to every request.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.body);
  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<List<int>>? s,
          Future<void>? c) async =>
      ResponseBody.fromString(jsonEncode(body), 200, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });

  @override
  void close({bool force = false}) {}
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

Map<String, dynamic> _taskJson(String id) => {
      'id': id,
      'householdId': 'h1',
      'title': 'Tarea $id',
      'status': 'pending',
      'priority': 'medium',
      'category': 'other',
      'assignedTo': <dynamic>[],
      'isRecurring': false,
      'isDeleted': false,
    };

/// Best-effort policy (TD-059): the server already holds this data, so a
/// failed cache write must be reported but must NOT fail the caller.
void bestEffortTests() {
  late FakeBox<Task> tasks;
  late FakeBox<PendingOperation> pending;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tasks = FakeBox<Task>();
    pending = FakeBox<PendingOperation>();
    CacheService().debugInjectBoxes(tasks: tasks, pendingOperations: pending);
  });

  tearDown(() => CacheService().debugResetBoxes());

  TaskRepository repo(Map<String, dynamic> body) {
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
      ..httpClientAdapter = _StubAdapter(body);
    return TaskRepository(ApiService(AuthLocalDataSource(), dio: dio));
  }

  test('list() still returns its page when the cache write fails', () async {
    tasks.failWrites = true;
    final r = repo(_pageEnvelope([_taskJson('a'), _taskJson('b')]));

    final page = await r.list('h1');

    expect(page.items.map((t) => t.id), ['a', 'b'],
        reason: 'a disk that refuses writes must not break reading');
    expect(tasks.entries, isEmpty);
  });

  test('create() online still returns the server task when caching fails',
      () async {
    tasks.failWrites = true;
    final r = repo({'success': true, 'data': _taskJson('server-1')});

    final task = await r.create('h1', {'title': 'Tarea'});

    expect(task.id, 'server-1');
  });
}

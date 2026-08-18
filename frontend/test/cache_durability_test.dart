import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/models/pending_operation.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/repositories/task_repository.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';
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

  group('propagation policy', propagationTests);

  group('cubit feedback', cubitFeedbackTests);

  group('queue id remap (TD-057)', remapTests);

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

/// Propagation policy (TD-059): an offline write the user was promised would
/// sync must NOT report success if it could not be persisted.
void propagationTests() {
  late FakeBox<Task> tasks;
  late FakeBox<PendingOperation> pending;
  late FakeConnectivityService connectivity;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tasks = FakeBox<Task>();
    pending = FakeBox<PendingOperation>();
    connectivity = FakeConnectivityService()..online = false;
    CacheService().debugInjectBoxes(tasks: tasks, pendingOperations: pending);
  });

  tearDown(() => CacheService().debugResetBoxes());

  TaskRepository repo() {
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
      ..httpClientAdapter = _StubAdapter(const {'success': true, 'data': {}});
    return TaskRepository(ApiService(AuthLocalDataSource(), dio: dio),
        connectivity: connectivity);
  }

  test('offline create succeeds normally when both writes land', () async {
    final task = await repo().create('h1', {'title': 'Tarea'});

    expect(task.isSynced, isFalse);
    expect(tasks.entries, hasLength(1));
    expect(pending.entries, hasLength(1),
        reason: 'entity and queued operation both persisted');
  });

  test('offline create throws when the entity write fails', () async {
    tasks.failWrites = true;

    await expectLater(
        repo().create('h1', {'title': 'Tarea'}), throwsA(anything));
    expect(pending.entries, isEmpty,
        reason: 'nothing queued for an entity that never landed');
  });

  test('offline create rolls the entity back when queueing fails', () async {
    pending.failWrites = true;

    await expectLater(
        repo().create('h1', {'title': 'Tarea'}), throwsA(anything));
    expect(tasks.entries, isEmpty,
        reason: 'an unsynced entity with no queued operation could never sync, '
            'so it must not be left behind');
  });

  test('offline delete restores the previous entity when queueing fails',
      () async {
    await CacheService().saveTask(const Task(
      id: 't1',
      householdId: 'h1',
      title: 'Original',
      status: 'pending',
      priority: 'medium',
      category: 'other',
      assignedTo: [],
      isSynced: true,
    ));
    pending.failWrites = true;

    await expectLater(repo().delete('h1', 't1'), throwsA(anything));

    final restored = tasks.entries['t1'] as Task;
    expect(restored.isDeleted, isFalse,
        reason: 'the delete mark must be undone, not left applied');
    expect(restored.isSynced, isTrue);
  });
}

/// The cubit must turn a local-persistence failure into a distinct, visible
/// message — not swallow it, and not word it like an offline success.
void cubitFeedbackTests() {
  test('createTask surfaces the local-write message, not the offline notice',
      () async {
    final repo = FakeTaskRepository()
      ..throwOnCreate = const FileSystemException('no space left on device');
    final cubit = TaskCubit(repo, FakeNotificationService());
    await cubit.load('h1');

    final task = await cubit.createTask({'title': 'Tarea'});

    expect(task, isNull);
    expect(cubit.state.error, kLocalWriteErrorMessage);
    expect(cubit.state.error, isNot(kOfflineNoticeMessage),
        reason: 'a lost write must never read as a queued one');
  });
}

/// Queue id remapping (TD-057): the translation from a local id to the
/// server's must land on disk, not in a variable that dies with the call.
void remapTests() {
  late FakeBox<PendingOperation> pending;

  setUp(() {
    pending = FakeBox<PendingOperation>();
    CacheService().debugInjectBoxes(pendingOperations: pending);
  });

  tearDown(() => CacheService().debugResetBoxes());

  PendingOperation op(
    String id, {
    required String? entityId,
    PendingOperationType type = PendingOperationType.update,
    PendingOperationEntity entity = PendingOperationEntity.task,
  }) =>
      PendingOperation(
        id: id,
        type: type,
        entity: entity,
        householdId: 'h1',
        entityId: entityId,
        payload: const {'title': 'x'},
        timestamp: DateTime.utc(2026, 1, 1),
        idempotencyKey: 'key-$id',
      );

  test('rewrites every queued operation pointing at the local id', () async {
    await CacheService().addPendingOperation(op('a', entityId: 'local-1'));
    await CacheService().addPendingOperation(op('b', entityId: 'local-1'));
    await CacheService().addPendingOperation(op('c', entityId: 'other'));

    final n = await CacheService().remapPendingOperationEntityId(
      fromEntityId: 'local-1',
      toEntityId: 'srv-9',
      entity: PendingOperationEntity.task,
    );

    expect(n, 2);
    final byId = {
      for (final o in CacheService().getPendingOperations()) o.id: o.entityId
    };
    expect(byId['a'], 'srv-9');
    expect(byId['b'], 'srv-9');
    expect(byId['c'], 'other', reason: 'untouched operations stay untouched');
  });

  test('is idempotent: a second run finds nothing to do', () async {
    await CacheService().addPendingOperation(op('a', entityId: 'local-1'));

    await CacheService().remapPendingOperationEntityId(
      fromEntityId: 'local-1',
      toEntityId: 'srv-9',
      entity: PendingOperationEntity.task,
    );
    final second = await CacheService().remapPendingOperationEntityId(
      fromEntityId: 'local-1',
      toEntityId: 'srv-9',
      entity: PendingOperationEntity.task,
    );

    expect(second, 0,
        reason: 'this is what makes the sync retry path safe to re-run');
  });

  test('never touches another entity queue', () async {
    await CacheService().addPendingOperation(
        op('s', entityId: 'local-1', entity: PendingOperationEntity.shopping));

    final n = await CacheService().remapPendingOperationEntityId(
      fromEntityId: 'local-1',
      toEntityId: 'srv-9',
      entity: PendingOperationEntity.task,
    );

    expect(n, 0);
    expect(CacheService().getPendingOperations().single.entityId, 'local-1');
  });

  test('surfaces a write failure instead of reporting success', () async {
    await CacheService().addPendingOperation(op('a', entityId: 'local-1'));
    pending.failWrites = true;

    await expectLater(
      CacheService().remapPendingOperationEntityId(
        fromEntityId: 'local-1',
        toEntityId: 'srv-9',
        entity: PendingOperationEntity.task,
      ),
      throwsA(anything),
      reason: 'the caller must not retire the create if the rewrite failed',
    );
  });

  test('preserves FIFO order: timestamp is not rewritten', () async {
    await CacheService().addPendingOperation(op('a', entityId: 'local-1'));

    await CacheService().remapPendingOperationEntityId(
      fromEntityId: 'local-1',
      toEntityId: 'srv-9',
      entity: PendingOperationEntity.task,
    );

    expect(CacheService().getPendingOperations().single.timestamp,
        DateTime.utc(2026, 1, 1));
  });
}

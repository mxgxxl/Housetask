import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/models/pending_operation.dart';
import 'package:homesync/data/repositories/task_repository.dart';
import 'package:homesync/services/cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// TD-057: the offline queue used to lose an update/delete whose create had
/// already synced.
///
/// `syncPendingOperations` kept the local→server mapping in a local variable,
/// so any early exit from the loop — a network break, a cache-write break, or
/// the process being killed — discarded it while the create was already gone
/// from the queue. The still-queued update then resolved to its original
/// `local-<uuid>`, 404'd, burned its 3 retries and was dropped: a write the
/// user had been told would sync, silently lost.
///
/// Exercises the real repository against a scripted HTTP adapter and a real
/// Hive-backed queue, because the bug lived exactly in that integration.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.handler);

  /// Receives (method, path) and returns the response to give, or throws to
  /// simulate a transport-level failure (what the repository reads as
  /// network-shaped).
  final ResponseBody Function(String method, String path) handler;

  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<List<int>>? s, Future<void>? c) async {
    requests.add('${o.method} ${o.path}');
    return handler(o.method, o.path);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

Map<String, dynamic> _taskEnvelope(String id, {String title = 'Tarea'}) => {
      'success': true,
      'data': {
        'id': id,
        'householdId': 'h1',
        'title': title,
        'status': 'pending',
        'priority': 'medium',
        'category': 'other',
        'assignedTo': <dynamic>[],
        'isRecurring': false,
        'isDeleted': false,
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('homesync_td057');
    await CacheService().init(testDirectory: tempDir.path);
  });

  tearDown(() async => CacheService().clearAll());

  tearDownAll(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  TaskRepository repoWith(_ScriptedAdapter adapter) {
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
      ..httpClientAdapter = adapter;
    return TaskRepository(ApiService(AuthLocalDataSource(), dio: dio));
  }

  PendingOperation createOp(String localId) => PendingOperation(
        id: 'op-create',
        type: PendingOperationType.create,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        entityId: localId,
        payload: const {'title': 'Nueva'},
        timestamp: DateTime.utc(2026, 1, 1, 10),
        idempotencyKey: 'key-create',
      );

  PendingOperation updateOp(String localId) => PendingOperation(
        id: 'op-update',
        type: PendingOperationType.update,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        entityId: localId,
        payload: const {'title': 'Editada'},
        timestamp: DateTime.utc(2026, 1, 1, 11),
        idempotencyKey: 'key-update',
      );

  /// The queue as TD-057 describes it: a create followed by an update of the
  /// same not-yet-synced task.
  Future<void> seedQueue(String localId) async {
    await CacheService().addPendingOperation(createOp(localId));
    await CacheService().addPendingOperation(updateOp(localId));
  }

  test('an update survives the network break that follows its create',
      () async {
    await seedQueue('local-A');

    // Pass 1: the create succeeds, the update hits a network-shaped failure
    // so the loop breaks — the exact shape that used to lose the write.
    final pass1 = _ScriptedAdapter((method, path) {
      if (method == 'POST') return _json(_taskEnvelope('srv-9'));
      throw DioException.connectionError(
          requestOptions: RequestOptions(path: path), reason: 'offline');
    });
    await repoWith(pass1).syncPendingOperations();

    final queued = CacheService().getPendingOperations();
    expect(queued.single.id, 'op-update',
        reason: 'the create synced; the update is still queued');
    expect(queued.single.entityId, 'srv-9',
        reason: 'TD-057: the queue itself must carry the translation now');

    // Pass 2: the update must go out against the SERVER id.
    final pass2 = _ScriptedAdapter((method, path) => _json(_taskEnvelope('srv-9', title: 'Editada')));
    await repoWith(pass2).syncPendingOperations();

    expect(pass2.requests.single, contains('srv-9'));
    expect(pass2.requests.single, isNot(contains('local-A')),
        reason: 'a PATCH against the local id is the 404 that lost the write');
    expect(CacheService().getPendingOperations(), isEmpty);
  });

  test('the translation survives a restart, not just a break', () async {
    await seedQueue('local-B');

    final pass1 = _ScriptedAdapter((method, path) {
      if (method == 'POST') return _json(_taskEnvelope('srv-7'));
      throw DioException.connectionError(
          requestOptions: RequestOptions(path: path), reason: 'offline');
    });
    await repoWith(pass1).syncPendingOperations();

    // Nothing in memory carries over: a brand-new repository, as after the
    // process was killed and the app relaunched. Only what is on disk counts.
    final afterRestart = _ScriptedAdapter((method, path) => _json(_taskEnvelope('srv-7')));
    await repoWith(afterRestart).syncPendingOperations();

    expect(afterRestart.requests.single, contains('srv-7'));
  });

  test('the create is NOT retired if the queue rewrite fails', () async {
    // The POST succeeds but the rewrite cannot be persisted. The create must
    // stay queued: retiring it would destroy the only thing able to
    // reproduce the mapping. Uses the TD-059 seam, since real Hive offers no
    // way to force a write failure.
    final pendingBox = FakeBox<PendingOperation>();
    CacheService().debugInjectBoxes(pendingOperations: pendingBox);
    await CacheService().addPendingOperation(createOp('local-C'));
    await CacheService().addPendingOperation(updateOp('local-C'));
    pendingBox.failWrites = true;

    final adapter = _ScriptedAdapter((method, path) => _json(_taskEnvelope('srv-5')));
    await repoWith(adapter).syncPendingOperations();

    pendingBox.failWrites = false;
    final ids = CacheService().getPendingOperations().map((o) => o.id).toSet();
    expect(ids, contains('op-create'),
        reason: 'the create is the only thing that can reproduce the mapping');

    CacheService().debugResetBoxes();
    await CacheService().init(testDirectory: tempDir.path);
  });

  test('a delete queued after its create also reaches the server id',
      () async {
    await CacheService().addPendingOperation(createOp('local-D'));
    await CacheService().addPendingOperation(PendingOperation(
      id: 'op-delete',
      type: PendingOperationType.delete,
      entity: PendingOperationEntity.task,
      householdId: 'h1',
      entityId: 'local-D',
      payload: const {},
      timestamp: DateTime.utc(2026, 1, 1, 12),
      idempotencyKey: 'key-delete',
    ));

    final pass1 = _ScriptedAdapter((method, path) {
      if (method == 'POST') return _json(_taskEnvelope('srv-3'));
      throw DioException.connectionError(
          requestOptions: RequestOptions(path: path), reason: 'offline');
    });
    await repoWith(pass1).syncPendingOperations();

    expect(CacheService().getPendingOperations().single.entityId, 'srv-3');
  });

  test('FIFO order is preserved across the rewrite', () async {
    await CacheService().addPendingOperation(createOp('local-E'));
    await CacheService().addPendingOperation(updateOp('local-E'));

    final pass1 = _ScriptedAdapter((method, path) {
      if (method == 'POST') return _json(_taskEnvelope('srv-1'));
      throw DioException.connectionError(
          requestOptions: RequestOptions(path: path), reason: 'offline');
    });
    await repoWith(pass1).syncPendingOperations();

    expect(CacheService().getPendingOperations().single.timestamp,
        DateTime.utc(2026, 1, 1, 11),
        reason: 'rewriting entityId must not disturb the ordering key');
  });
}

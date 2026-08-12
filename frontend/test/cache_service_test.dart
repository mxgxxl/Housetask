import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:homesync/data/models/household.dart';
import 'package:homesync/data/models/member.dart';
import 'package:homesync/data/models/pending_operation.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/models/task_adapter.dart';
import 'package:homesync/data/models/user.dart';
import 'package:homesync/services/cache_service.dart';

import 'fakes.dart';

/// Exercises the REAL Hive adapters (hand-written, not codegen — see
/// task_adapter.dart) against a temp-directory Hive instance, not a fake:
/// they are new, untested code with more room for a subtle bug than
/// generated code would have.
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('homesync_cache_test');
    await CacheService().init(testDirectory: tempDir.path);
  });

  tearDown(() async {
    await CacheService().clearAll();
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('tasks', () {
    test('round-trips a task through the real Hive adapter, populated refs included', () {
      final task = buildTask('t1', title: 'Comprar pan');
      // buildTask has no assignee by default; verify a populated one too,
      // since that is exactly what toJson() (payload-shaped) would lose.
      final withAssignee = Task.fromJson({
        ...taskToCacheMap(task),
        'assignedTo': [
          const User(id: 'u1', email: 'a@b.com', name: 'Ana').toJson(),
        ],
      });

      CacheService().saveTasks('h1', [withAssignee]);
      final cached = CacheService().getTasks('h1');

      expect(cached, hasLength(1));
      expect(cached.single.title, 'Comprar pan');
      expect(cached.single.assignedTo.single.name, 'Ana');
    });

    test('getTasks only returns the requested household', () {
      // buildTask() always stamps householdId 'h1' (the fixture's default
      // convention), so task 'b' needs its own householdId set explicitly to
      // actually belong to 'h2' — getTasks filters by the task's own field,
      // not by which saveTasks() call it arrived through.
      final taskForH2 = Task.fromJson({...taskToCacheMap(buildTask('b')), 'householdId': 'h2'});
      CacheService().saveTasks('h1', [buildTask('a')]);
      CacheService().saveTasks('h2', [taskForH2]);

      expect(CacheService().getTasks('h1').map((t) => t.id), ['a']);
      expect(CacheService().getTasks('h2').map((t) => t.id), ['b']);
    });

    test('saveTasks replaces the household\'s previous cache, not appends', () {
      CacheService().saveTasks('h1', [buildTask('a'), buildTask('b')]);
      CacheService().saveTasks('h1', [buildTask('c')]);

      expect(CacheService().getTasks('h1').map((t) => t.id), ['c']);
    });
  });

  group('shopping', () {
    test('round-trips a shopping item through the real Hive adapter', () {
      final item = buildItem('s1', name: 'Leche');
      CacheService().saveShopping('h1', [item]);

      expect(CacheService().getShopping('h1').single.name, 'Leche');
    });
  });

  group('households', () {
    test('round-trips a household with members through the real Hive adapter', () {
      const household = Household(
        id: 'h1',
        name: 'Casa',
        inviteCode: 'ABCD1234',
        createdBy: 'u1',
        members: [Member(user: User(id: 'u1', email: 'a@b.com', name: 'Ana'), role: 'admin')],
      );

      CacheService().saveHousehold(household);
      final cached = CacheService().getHouseholds();

      expect(cached, hasLength(1));
      expect(cached.single.members.single.user.name, 'Ana');
    });
  });

  group('pending operations', () {
    test('round-trips through the real Hive adapter, including the enums', () {
      final op = PendingOperation(
        id: 'op1',
        type: PendingOperationType.create,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        payload: {'title': 'Offline task'},
        timestamp: DateTime.utc(2026, 1, 1),
        idempotencyKey: 'key-1',
      );

      CacheService().addPendingOperation(op);
      final all = CacheService().getPendingOperations();

      expect(all, hasLength(1));
      expect(all.single.type, PendingOperationType.create);
      expect(all.single.entity, PendingOperationEntity.task);
      expect(all.single.payload['title'], 'Offline task');
    });

    test('returns operations in timestamp order regardless of insertion order', () {
      final later = PendingOperation(
        id: 'later',
        type: PendingOperationType.update,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        entityId: 't1',
        payload: const {},
        timestamp: DateTime.utc(2026, 1, 2),
        idempotencyKey: 'k2',
      );
      final earlier = PendingOperation(
        id: 'earlier',
        type: PendingOperationType.create,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        payload: const {},
        timestamp: DateTime.utc(2026, 1, 1),
        idempotencyKey: 'k1',
      );

      // Inserted out of order on purpose.
      CacheService().addPendingOperation(later);
      CacheService().addPendingOperation(earlier);

      expect(CacheService().getPendingOperations().map((o) => o.id), ['earlier', 'later']);
    });

    test('removePendingOperation drops exactly that operation', () {
      CacheService().addPendingOperation(PendingOperation(
        id: 'a',
        type: PendingOperationType.create,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        payload: const {},
        timestamp: DateTime.utc(2026),
        idempotencyKey: 'k',
      ));
      CacheService().addPendingOperation(PendingOperation(
        id: 'b',
        type: PendingOperationType.create,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        payload: const {},
        timestamp: DateTime.utc(2026),
        idempotencyKey: 'k2',
      ));

      CacheService().removePendingOperation('a');

      expect(CacheService().getPendingOperations().map((o) => o.id), ['b']);
      expect(CacheService().pendingOperationsCountSync, 1);
    });
  });

  group('clearAll', () {
    test('empties every box — the logout guarantee', () async {
      CacheService().saveTasks('h1', [buildTask('a')]);
      CacheService().saveShopping('h1', [buildItem('a')]);
      CacheService().saveHousehold(
        const Household(id: 'h1', name: 'Casa', inviteCode: 'ABCD1234', createdBy: 'u1'),
      );
      CacheService().addPendingOperation(PendingOperation(
        id: 'op',
        type: PendingOperationType.create,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        payload: const {},
        timestamp: DateTime.utc(2026),
        idempotencyKey: 'k',
      ));

      await CacheService().clearAll();

      expect(CacheService().getTasks('h1'), isEmpty);
      expect(CacheService().getShopping('h1'), isEmpty);
      expect(CacheService().getHouseholds(), isEmpty);
      expect(CacheService().getPendingOperations(), isEmpty);
    });
  });
}

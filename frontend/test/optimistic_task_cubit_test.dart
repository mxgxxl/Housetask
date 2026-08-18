import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';

import 'fakes.dart';

/// Optimistic mutations in TaskCubit (TD-007).
///
/// The pattern throughout: hold the repository open with a gate, assert what
/// the UI already shows, then release it and assert the reconciliation.
void main() {
  FakeTaskRepository repoWith(Task seed) => FakeTaskRepository(pages: [
        PaginatedResponse<Task>(
          items: [seed],
          nextCursor: null,
          hasMore: false,
          total: 1,
        ),
      ]);

  Task? findIn(TaskCubit cubit, String id) {
    for (final f in TaskFilter.values) {
      for (final t in cubit.state.bucket(f).items) {
        if (t.id == id) return t;
      }
    }
    return null;
  }

  group('completeTask', () {
    test('applies the completion before the server answers', () async {
      final gate = Completer<void>();
      final repo = repoWith(buildTask('t1'))..completeGate = gate.future;
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      final inFlight = cubit.completeTask('t1');

      // Still in flight: the UI must already show it completed.
      expect(findIn(cubit, 't1')!.status, 'completed');
      expect(cubit.state.pendingIds, contains('t1'),
          reason: 'the row must be marked in flight while it is');

      gate.complete();
      await inFlight;
    });

    test('reconciles with the server entity once confirmed', () async {
      final repo = repoWith(buildTask('t1'))
        ..completeReturns = buildTask('t1',
            completed: true, completedBy: {'id': 'u9', 'name': 'Ana'});
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.completeTask('t1');

      expect(findIn(cubit, 't1')!.completedBy?.name, 'Ana',
          reason: 'the server knows who completed it; the optimistic value did not');
      expect(cubit.state.pendingIds, isEmpty);
    });

    test('rolls back to the previous value when the server rejects', () async {
      final repo = repoWith(buildTask('t1'))
        ..failCompleteWith = const ServerFailure('No autorizado', statusCode: 403);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.completeTask('t1');

      expect(findIn(cubit, 't1')!.status, 'pending',
          reason: 'a rejected completion must not stay applied');
      expect(cubit.state.pendingIds, isEmpty);
      expect(cubit.state.error, 'No autorizado');
    });

    test('does NOT roll back when the task changed meanwhile', () async {
      final gate = Completer<void>();
      final repo = repoWith(buildTask('t1', title: 'Original'))
        ..completeGate = gate.future
        ..failCompleteWith = const ServerFailure('No autorizado', statusCode: 403);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      final inFlight = cubit.completeTask('t1');

      // The user renames the task while the completion is still in flight —
      // a separate, perfectly valid edit arriving via realtime.
      cubit.applyRealtime('task:updated', {
        'id': 't1',
        'householdId': 'h1',
        'title': 'Renombrada',
        'status': 'pending',
        'priority': 'medium',
        'category': 'other',
        'assignedTo': <dynamic>[],
        'isRecurring': false,
        'isDeleted': false,
      });

      gate.complete();
      await inFlight;

      expect(findIn(cubit, 't1')!.title, 'Renombrada',
          reason: 'rolling back over a newer value would destroy the rename');
      expect(cubit.state.error, 'No autorizado',
          reason: 'the failure is still reported even when not rolled back');
      expect(cubit.state.pendingIds, isEmpty);
    });

    test('a network failure does NOT roll back: it fell back to offline',
        () async {
      // The repository absorbs a network-shaped failure itself and returns
      // the optimistic entity with isSynced:false — a success, not a
      // rejection. Rolling that back would discard a change that is safely
      // queued.
      final repo = repoWith(buildTask('t1'))
        ..completeReturns =
            buildTask('t1', completed: true).copyWith(isSynced: false);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.completeTask('t1');

      expect(findIn(cubit, 't1')!.status, 'completed');
      expect(findIn(cubit, 't1')!.isSynced, isFalse);
      expect(cubit.state.offlineNotice, kOfflineNoticeMessage);
      expect(cubit.state.pendingIds, isEmpty);
      expect(cubit.state.error, isNull, reason: 'queued is not failed');
    });

    test('a local persistence failure rolls back and reports it', () async {
      final repo = repoWith(buildTask('t1'))
        ..failCompleteWith = const FileSystemException('no space left');
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.completeTask('t1');

      expect(findIn(cubit, 't1')!.status, 'pending');
      expect(cubit.state.error, kLocalWriteErrorMessage);
    });

    test('bucket totals survive an optimistic apply and its rollback',
        () async {
      final repo = repoWith(buildTask('t1'))
        ..failCompleteWith = const ServerFailure('No autorizado', statusCode: 403);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      final before = cubit.state.bucket(TaskFilter.all).total;

      await cubit.completeTask('t1');

      expect(cubit.state.bucket(TaskFilter.all).total, before,
          reason: 'apply + rollback must leave the counter where it started');
    });
  });

  group('deleteTask', () {
    test('removes the row immediately and keeps it gone once confirmed',
        () async {
      final repo = repoWith(buildTask('t1'));
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.deleteTask('t1');

      expect(findIn(cubit, 't1'), isNull);
      expect(cubit.state.pendingIds, isEmpty);
    });

    test('reinserts the row when the server rejects, naming the task',
        () async {
      final repo = repoWith(buildTask('t1', title: 'Fregar'))
        ..failDeleteWith = const ServerFailure('No autorizado', statusCode: 403);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.deleteTask('t1');

      expect(findIn(cubit, 't1'), isNotNull,
          reason: 'a rejected delete must put the row back');
      expect(cubit.state.error, contains('Fregar'),
          reason: 'the reappearance must read as a refusal, not a glitch');
      expect(cubit.state.pendingIds, isEmpty);
    });

    test('offline keeps the row struck through instead of removed', () async {
      // The repository absorbs the network failure and returns the task
      // marked isDeleted — the pre-TD-007 asymmetry that must survive.
      final repo = FakeTaskRepository(
        pages: [
          PaginatedResponse<Task>(
            items: [buildTask('t1')],
            nextCursor: null,
            hasMore: false,
            total: 1,
          ),
        ],
        offlineDeleteReturns: buildTask('t1', isDeleted: true),
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.deleteTask('t1');

      expect(findIn(cubit, 't1')?.isDeleted, isTrue,
          reason: 'a queued delete stays visible, struck through');
      expect(cubit.state.offlineNotice, kOfflineNoticeMessage);
    });
  });

  group('in-flight blocking (TD-007 decision D)', () {
    test('the id stays in pendingIds for the whole window and no longer',
        () async {
      final gate = Completer<void>();
      final repo = repoWith(buildTask('t1'))..completeGate = gate.future;
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      expect(cubit.state.pendingIds, isEmpty, reason: 'nothing in flight yet');

      final inFlight = cubit.completeTask('t1');
      expect(cubit.state.pendingIds, {'t1'},
          reason: 'the UI disables this row off exactly this set');

      gate.complete();
      await inFlight;
      expect(cubit.state.pendingIds, isEmpty,
          reason: 'a row left disabled forever would be a dead row');
    });

    test('pendingIds is cleared even when the mutation fails', () async {
      final repo = repoWith(buildTask('t1'))
        ..failCompleteWith = const ServerFailure('No autorizado', statusCode: 403);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.completeTask('t1');

      expect(cubit.state.pendingIds, isEmpty);
    });
  });

  group('createTask (TD-060)', () {
    test('shows the row with a pending- id before the server answers',
        () async {
      final gate = Completer<void>();
      final repo = FakeTaskRepository()..createGate = gate.future;
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      final inFlight = cubit.createTask({'title': 'Nueva'});

      final rows = cubit.state.bucket(TaskFilter.all).items;
      expect(rows, hasLength(1));
      expect(rows.single.id, startsWith('pending-'),
          reason: 'never local-, which means queued offline to the sync loop');
      expect(cubit.state.pendingIds, {rows.single.id});

      gate.complete();
      await inFlight;
    });

    test('swaps the temporary id for the server one in a SINGLE emission',
        () async {
      final gate = Completer<void>();
      final repo = FakeTaskRepository()..createGate = gate.future;
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      final inFlight = cubit.createTask({'title': 'Nueva'});
      final tempId = cubit.state.bucket(TaskFilter.all).items.single.id;

      // Count what the UI would rebuild from, from here to confirmation.
      final seen = <List<String>>[];
      final sub = cubit.stream.listen((s) =>
          seen.add(s.bucket(TaskFilter.all).items.map((t) => t.id).toList()));

      gate.complete();
      await inFlight;
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, hasLength(1),
          reason: 'two emissions would flicker: the row vanishing then '
              'reappearing with another id');
      expect(seen.single, ['created']);
      expect(seen.single, isNot(contains(tempId)));
      expect(cubit.state.pendingIds, isEmpty);
    });

    test('never leaves the list empty or doubled while swapping', () async {
      final gate = Completer<void>();
      final repo = FakeTaskRepository()..createGate = gate.future;
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      final inFlight = cubit.createTask({'title': 'Nueva'});
      final counts = <int>[];
      final sub = cubit.stream
          .listen((s) => counts.add(s.bucket(TaskFilter.all).items.length));

      gate.complete();
      await inFlight;
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(counts, everyElement(1),
          reason: 'exactly one row at every observable moment');
    });

    test('removes the optimistic row when the server rejects', () async {
      final repo = FakeTaskRepository(
          failCreateWith: const ServerFailure('No autorizado', statusCode: 403));
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      final task = await cubit.createTask({'title': 'Nueva'});

      expect(task, isNull);
      expect(cubit.state.bucket(TaskFilter.all).items, isEmpty,
          reason: 'nothing was created, so nothing may stay on screen');
      expect(cubit.state.error, 'No autorizado');
      expect(cubit.state.pendingIds, isEmpty);
    });

    test('a create that falls back to the queue swaps pending- for the '
        'offline entity', () async {
      final repo = FakeTaskRepository(returnsUnsynced: true);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.createTask({'title': 'Nueva'});

      final row = cubit.state.bucket(TaskFilter.all).items.single;
      expect(row.id, isNot(startsWith('pending-')));
      expect(row.isSynced, isFalse);
      expect(cubit.state.offlineNotice, kOfflineNoticeMessage);
      expect(cubit.state.pendingIds, isEmpty);
    });
  });
}

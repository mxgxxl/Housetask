import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';

import 'fakes.dart';

PaginatedResponse<Task> page(
  List<Task> items, {
  String? nextCursor,
  bool hasMore = false,
  int? total,
}) {
  return PaginatedResponse<Task>(
    items: items,
    nextCursor: nextCursor,
    hasMore: hasMore,
    total: total,
  );
}

void main() {
  group('TaskCubit.load', () {
    blocTest<TaskCubit, TaskState>(
      'emits [loading, loaded] with the first page',
      build: () => TaskCubit(
        FakeTaskRepository(
          pages: [
            page([buildTask('1'), buildTask('2')], nextCursor: 'c1', hasMore: true, total: 7),
          ],
        ),
        FakeNotificationService(),
      ),
      act: (cubit) => cubit.load('h1'),
      expect: () => [
        isA<TaskState>().having((s) => s.status, 'status', TaskStatusUi.loading),
        isA<TaskState>()
            .having((s) => s.status, 'status', TaskStatusUi.loaded)
            .having((s) => s.tasks.length, 'tasks', 2)
            .having((s) => s.nextCursor, 'nextCursor', 'c1')
            .having((s) => s.hasMore, 'hasMore', true)
            .having((s) => s.total, 'total', 7),
      ],
    );

    blocTest<TaskCubit, TaskState>(
      'emits error when the first page fails',
      build: () => TaskCubit(
        FakeTaskRepository(failListWith: const ServerFailure('boom')),
        FakeNotificationService(),
      ),
      act: (cubit) => cubit.load('h1'),
      expect: () => [
        isA<TaskState>().having((s) => s.status, 'status', TaskStatusUi.loading),
        isA<TaskState>()
            .having((s) => s.status, 'status', TaskStatusUi.error)
            .having((s) => s.error, 'error', 'boom'),
      ],
    );
  });

  group('TaskCubit.loadMore', () {
    test('appends the next page and advances the cursor', () async {
      final repo = FakeTaskRepository(
        pages: [
          page([buildTask('1')], nextCursor: 'c1', hasMore: true, total: 2),
          page([buildTask('2')], nextCursor: null, hasMore: false),
        ],
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.load('h1');
      await cubit.loadMore();

      expect(cubit.state.tasks.map((t) => t.id), ['1', '2']);
      expect(cubit.state.hasMore, isFalse);
      expect(cubit.state.nextCursor, isNull);
      // First page without cursor, second page with the cursor it returned.
      expect(repo.receivedCursors, [null, 'c1']);
      // total comes from the first page and must survive later pages.
      expect(cubit.state.total, 2);
    });

    test('does nothing when the list is already exhausted', () async {
      final repo = FakeTaskRepository(
        pages: [page([buildTask('1')], nextCursor: null, hasMore: false)],
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      final before = cubit.state;
      await cubit.loadMore();

      expect(cubit.state, before);
      expect(repo.listCalls, 1);
    });

    test('runs a single fetch when called twice in a row', () async {
      final gate = Completer<void>();
      final repo = FakeTaskRepository(
        pages: [
          page([buildTask('1')], nextCursor: 'c1', hasMore: true),
          page([buildTask('2')], nextCursor: 'c2', hasMore: true),
          page([buildTask('3')], nextCursor: 'c3', hasMore: true),
        ],
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      // Both calls happen before the first completes — exactly what the scroll
      // listener does while the user drags through the trigger zone.
      final first = cubit.loadMore();
      final second = cubit.loadMore();
      gate.complete();
      await Future.wait([first, second]);

      // One list() for load + one for the single accepted loadMore.
      expect(repo.listCalls, 2);
      expect(cubit.state.tasks.map((t) => t.id), ['1', '2']);
    });

    test('keeps loaded pages and surfaces the error when a page fails', () async {
      final repo = _FailingSecondPageRepository();
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.load('h1');
      await cubit.loadMore();

      expect(cubit.state.tasks.map((t) => t.id), ['1']);
      expect(cubit.state.error, 'network down');
      expect(cubit.state.isLoadingMore, isFalse);
      // The cursor is retained so a retry can resume from the same position.
      expect(cubit.state.nextCursor, 'c1');
    });
  });

  group('TaskCubit.applyRealtime', () {
    test('task:created inserts without duplicating', () async {
      final repo = FakeTaskRepository(pages: [page([buildTask('1')])]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      cubit.applyRealtime('task:created', {
        'id': '2',
        'householdId': 'h1',
        'title': 'Nueva',
        'status': 'pending',
        'isRecurring': false,
      });
      // The same event arriving twice (socket reconnect) must not duplicate.
      cubit.applyRealtime('task:created', {
        'id': '2',
        'householdId': 'h1',
        'title': 'Nueva',
        'status': 'pending',
        'isRecurring': false,
      });

      expect(cubit.state.tasks.map((t) => t.id), ['1', '2']);
    });

    test('task:updated replaces the existing task in place', () async {
      final repo = FakeTaskRepository(pages: [page([buildTask('1', title: 'Vieja')])]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      cubit.applyRealtime('task:updated', {
        'id': '1',
        'householdId': 'h1',
        'title': 'Renombrada',
        'status': 'pending',
        'isRecurring': false,
      });

      expect(cubit.state.tasks, hasLength(1));
      expect(cubit.state.tasks.single.title, 'Renombrada');
    });

    test('task:deleted removes the task', () async {
      final repo = FakeTaskRepository(
        pages: [page([buildTask('1'), buildTask('2')])],
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      cubit.applyRealtime('task:deleted', {'id': '1', 'householdId': 'h1'});

      expect(cubit.state.tasks.map((t) => t.id), ['2']);
    });

    test('ignores events for a different household', () async {
      final repo = FakeTaskRepository(pages: [page([buildTask('1')])]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      cubit.applyRealtime('task:created', {
        'id': '99',
        'householdId': 'otra-casa',
        'title': 'Ajena',
        'status': 'pending',
        'isRecurring': false,
      });

      expect(cubit.state.tasks.map((t) => t.id), ['1']);
    });
  });

  group('TaskCubit.createTask', () {
    test('upserts the created task into the list', () async {
      final repo = FakeTaskRepository(pages: [page([buildTask('1')])]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      final created = await cubit.createTask({'title': 'Recién creada'});

      expect(created, isNotNull);
      expect(cubit.state.tasks.map((t) => t.id), contains('created'));
    });

    test('exposes the failure message and creates nothing when the repo throws', () async {
      final repo = FakeTaskRepository(
        pages: [page([buildTask('1')])],
        failCreateWith: const ConflictFailure('Operation already in progress'),
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      final created = await cubit.createTask({'title': 'Fallida'});

      expect(created, isNull);
      expect(cubit.state.error, 'Operation already in progress');
      expect(cubit.state.tasks.map((t) => t.id), ['1']);
    });
  });

  group('TaskCubit per-tab filtering', () {
    test('sends the right status param for each filter and none for all', () async {
      final repo = FakeTaskRepository(
        pagesByStatus: {
          null: [page([buildTask('a')], total: 3)],
          'pending': [page([buildTask('p')], total: 2)],
          'completed': [page([buildTask('c', completed: true)], total: 1)],
        },
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.load('h1');
      await cubit.setFilter(TaskFilter.pending);
      await cubit.setFilter(TaskFilter.completed);
      await cubit.setFilter(null);

      // The server does the filtering; a local `where` is what made
      // "Completadas" look empty behind a page of pending tasks.
      expect(repo.receivedStatuses, [null, 'pending', 'completed', null]);
      expect(cubit.state.activeFilter, TaskFilter.all);
    });

    test('keeps one bucket per filter, each with its own items and total', () async {
      final repo = FakeTaskRepository(
        pagesByStatus: {
          null: [page([buildTask('a'), buildTask('b', completed: true)], total: 2)],
          'pending': [page([buildTask('a')], total: 1)],
          'completed': [page([buildTask('b', completed: true)], total: 1)],
        },
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.load('h1');
      await cubit.setFilter(TaskFilter.pending);
      await cubit.setFilter(TaskFilter.completed);

      expect(cubit.state.bucket(TaskFilter.all).items.map((t) => t.id), ['a', 'b']);
      expect(cubit.state.bucket(TaskFilter.all).total, 2);
      expect(cubit.state.bucket(TaskFilter.pending).items.map((t) => t.id), ['a']);
      expect(cubit.state.bucket(TaskFilter.pending).total, 1);
      expect(cubit.state.bucket(TaskFilter.completed).items.map((t) => t.id), ['b']);
      // The active getters follow the visible tab.
      expect(cubit.state.tasks.map((t) => t.id), ['b']);
      expect(cubit.state.total, 1);
    });

    test('loadMore advances only the active filter cursor', () async {
      final repo = FakeTaskRepository(
        pagesByStatus: {
          'pending': [
            page([buildTask('p1')], nextCursor: 'p-c1', hasMore: true, total: 2),
            page([buildTask('p2')], nextCursor: null, hasMore: false),
          ],
          'completed': [
            page([buildTask('c1', completed: true)],
                nextCursor: 'c-c1', hasMore: true, total: 5),
          ],
        },
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      // main_scaffold always loads before the user can reach the tabs, so the
      // cubit knows its household by the time setFilter runs.
      await cubit.load('h1');
      await cubit.setFilter(TaskFilter.completed);
      await cubit.setFilter(TaskFilter.pending);
      await cubit.loadMore();

      // Pending advanced and exhausted...
      expect(cubit.state.bucket(TaskFilter.pending).items.map((t) => t.id), ['p1', 'p2']);
      expect(cubit.state.bucket(TaskFilter.pending).nextCursor, isNull);
      expect(cubit.state.bucket(TaskFilter.pending).hasMore, isFalse);
      // ...while completed kept its own untouched cursor.
      expect(cubit.state.bucket(TaskFilter.completed).nextCursor, 'c-c1');
      expect(cubit.state.bucket(TaskFilter.completed).hasMore, isTrue);
      expect(cubit.state.bucket(TaskFilter.completed).items.map((t) => t.id), ['c1']);
      // The pending cursor, never the completed one, was sent.
      expect(repo.receivedCursors, [null, null, null, 'p-c1']);
    });

    test('setFilter does not refetch a tab that is already loaded', () async {
      final repo = FakeTaskRepository(
        pagesByStatus: {
          'pending': [page([buildTask('p1')], total: 1)],
        },
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      final callsAfterLoad = repo.listCalls;

      await cubit.setFilter(TaskFilter.pending);
      await cubit.setFilter(TaskFilter.pending);

      // Only the first switch fetches; re-tapping the current tab must not.
      expect(repo.listCalls, callsAfterLoad + 1);
    });

    test('completing a task moves it between buckets without a refetch', () async {
      final repo = FakeTaskRepository(
        pagesByStatus: {
          null: [page([buildTask('t1')], total: 1)],
          'pending': [page([buildTask('t1')], total: 1)],
          'completed': [page(const [], total: 0)],
        },
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.load('h1');
      await cubit.setFilter(TaskFilter.completed);
      await cubit.setFilter(TaskFilter.pending);

      cubit.applyRealtime('task:completed', {
        'id': 't1',
        'householdId': 'h1',
        'title': 'Tarea',
        'status': 'completed',
        'isRecurring': false,
      });

      // Leaves "Pendientes", appears in "Completadas", stays in "Todas".
      expect(cubit.state.bucket(TaskFilter.pending).items, isEmpty);
      expect(cubit.state.bucket(TaskFilter.completed).items.map((t) => t.id), ['t1']);
      expect(cubit.state.bucket(TaskFilter.all).items.map((t) => t.id), ['t1']);
    });

    test('deleting removes the task from every bucket', () async {
      final repo = FakeTaskRepository(
        pagesByStatus: {
          null: [page([buildTask('t1')], total: 1)],
          'pending': [page([buildTask('t1')], total: 1)],
        },
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.load('h1');
      await cubit.setFilter(TaskFilter.pending);

      cubit.applyRealtime('task:deleted', {'id': 't1', 'householdId': 'h1'});

      expect(cubit.state.bucket(TaskFilter.all).items, isEmpty);
      expect(cubit.state.bucket(TaskFilter.pending).items, isEmpty);
    });
  });
}

/// First page succeeds, second fails — models a mid-scroll network drop.
class _FailingSecondPageRepository extends FakeTaskRepository {
  _FailingSecondPageRepository();

  @override
  Future<PaginatedResponse<Task>> list(
    String householdId, {
    String? status,
    int limit = 50,
    String? cursor,
  }) async {
    receivedCursors.add(cursor);
    listCalls++;
    if (cursor == null) {
      return page([buildTask('1')], nextCursor: 'c1', hasMore: true, total: 5);
    }
    throw const ServerFailure('network down');
  }
}

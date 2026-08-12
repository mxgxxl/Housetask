import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';

import 'fakes.dart';

/// Flushes pending microtasks/timers — enough turns for a stream event to be
/// delivered and for the async work its listener kicks off (syncPending's
/// own awaits) to complete, without depending on real time passing.
Future<void> flushAsync() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

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

  group('TaskCubit offline support (TD-003)', () {
    test('load sets isOffline when the repository served the cache fallback', () async {
      final repo = FakeTaskRepository(pages: [page([buildTask('1')])]);
      // The real TaskRepository sets this itself inside list(); the fake
      // leaves it alone, so setting it up front models "list() just fell
      // back to cache" for the cubit to observe right after awaiting it.
      repo.lastListWasFromCache = true;
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.load('h1');

      expect(cubit.state.isOffline, isTrue);
      expect(cubit.state.tasks.map((t) => t.id), ['1']);
    });

    test('load clears isOffline once a real page comes back', () async {
      final repo = FakeTaskRepository(pages: [page([buildTask('1')])]);
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.load('h1');

      expect(cubit.state.isOffline, isFalse);
    });

    test('createTask offline surfaces the unsynced task and an offline notice', () async {
      final repo = FakeTaskRepository(
        pages: [page([buildTask('1')])],
        returnsUnsynced: true,
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      final created = await cubit.createTask({'title': 'Sin red'});

      expect(created?.isSynced, isFalse);
      expect(cubit.state.offlineNotice, kOfflineNoticeMessage);
      expect(cubit.state.tasks.map((t) => t.id), contains('created'));
    });

    test('clearOfflineNotice consumes the notice without touching error', () async {
      final repo = FakeTaskRepository(
        pages: [page([buildTask('1')])],
        returnsUnsynced: true,
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      await cubit.createTask({'title': 'Sin red'});
      expect(cubit.state.offlineNotice, isNotNull);

      cubit.clearOfflineNotice();

      expect(cubit.state.offlineNotice, isNull);
    });

    test('deleteTask offline keeps the task visible, marked deleted and unsynced', () async {
      final marked =
          buildTask('1').copyWith(isDeleted: true, isSynced: false);
      final repo = FakeTaskRepository(
        pages: [page([buildTask('1')])],
        offlineDeleteReturns: marked,
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.deleteTask('1');

      final stored = cubit.state.tasks.singleWhere((t) => t.id == '1');
      expect(stored.isDeleted, isTrue);
      expect(stored.isSynced, isFalse);
      expect(cubit.state.offlineNotice, kOfflineNoticeMessage);
    });

    test('deleteTask online removes the task outright', () async {
      final repo = FakeTaskRepository(pages: [page([buildTask('1')])]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.deleteTask('1');

      expect(cubit.state.tasks, isEmpty);
    });

    test('syncPending reloads only when operations were actually processed', () async {
      final repo = FakeTaskRepository(pages: [page([buildTask('1')])]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      final callsAfterLoad = repo.listCalls;

      repo.syncPendingOperationsResult = 0;
      await cubit.syncPending();
      expect(repo.listCalls, callsAfterLoad, reason: 'nothing processed, no reason to reload');

      repo.syncPendingOperationsResult = 2;
      await cubit.syncPending();
      expect(repo.listCalls, callsAfterLoad + 1);
    });

    test('reconnection (false→true) auto-triggers a sync', () async {
      final fakeConnectivity = FakeConnectivityService();
      final repo = FakeTaskRepository(pages: [page([buildTask('1')])]);
      final cubit =
          TaskCubit(repo, FakeNotificationService(), connectivity: fakeConnectivity);
      await cubit.load('h1');
      repo.syncPendingOperationsResult = 1;

      fakeConnectivity.controller.add(false);
      await flushAsync();
      fakeConnectivity.controller.add(true);
      await flushAsync();

      expect(repo.syncCalls, 1);
    });

    test('staying online never triggers a sync (no false→true edge)', () async {
      final fakeConnectivity = FakeConnectivityService();
      final repo = FakeTaskRepository(pages: [page([buildTask('1')])]);
      final cubit =
          TaskCubit(repo, FakeNotificationService(), connectivity: fakeConnectivity);
      await cubit.load('h1');

      fakeConnectivity.controller.add(true);
      await flushAsync();

      expect(repo.syncCalls, 0);
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
      // "Completadas" look empty behind a page of pending tasks. The final
      // switch back to "all" issues no request: load('h1') already fetched
      // that bucket, and revisiting a loaded bucket must not refetch it.
      expect(repo.receivedStatuses, [null, 'pending', 'completed']);
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

    test('createTask bumps the header total for every bucket it now belongs to, without a refetch', () async {
      final repo = FakeTaskRepository(
        pagesByStatus: {
          null: [page([buildTask('a')], total: 5)],
          'pending': [page([buildTask('a')], total: 3)],
        },
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      await cubit.setFilter(TaskFilter.pending);
      final callsBeforeCreate = repo.listCalls;

      await cubit.createTask({'title': 'Nueva'});

      // A new task is always pending, so both buckets it belongs to gain +1;
      // "completed" was never visited and stays unknown (null), not 0+1.
      expect(cubit.state.bucket(TaskFilter.all).total, 6);
      expect(cubit.state.bucket(TaskFilter.pending).total, 4);
      expect(cubit.state.bucket(TaskFilter.completed).total, isNull);
      // The header updated from create()'s own response, not a second round
      // trip: createTask never calls list().
      expect(repo.listCalls, callsBeforeCreate);
    });

    test('deleteTask decrements the total only in buckets the task belonged to', () async {
      final repo = FakeTaskRepository(
        pagesByStatus: {
          null: [page([buildTask('t1')], total: 4)],
          'pending': [page([buildTask('t1')], total: 2)],
          'completed': [page(const [], total: 0)],
        },
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      await cubit.setFilter(TaskFilter.pending);
      await cubit.setFilter(TaskFilter.completed);

      await cubit.deleteTask('t1');

      expect(cubit.state.bucket(TaskFilter.all).total, 3);
      expect(cubit.state.bucket(TaskFilter.pending).total, 1);
      // t1 was never in "completed", so its total (0) is untouched, not -1.
      expect(cubit.state.bucket(TaskFilter.completed).total, 0);
    });

    test('completeTask moves the total from pending to completed and leaves "all" unchanged', () async {
      final repo = FakeTaskRepository(
        pagesByStatus: {
          null: [page([buildTask('t1')], total: 1)],
          'pending': [page([buildTask('t1')], total: 1)],
          'completed': [page(const [], total: 0)],
        },
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      await cubit.setFilter(TaskFilter.pending);
      await cubit.setFilter(TaskFilter.completed);

      await cubit.completeTask('t1');

      expect(cubit.state.bucket(TaskFilter.all).total, 1);
      expect(cubit.state.bucket(TaskFilter.pending).total, 0);
      expect(cubit.state.bucket(TaskFilter.completed).total, 1);
    });

    test('setFilter does not refetch a bucket that is loaded and legitimately empty', () async {
      final repo = FakeTaskRepository(
        pagesByStatus: {
          null: [page([buildTask('a')], total: 1)],
          // A real, empty first page — not "never visited".
          'completed': [page(const [], total: 0)],
        },
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');

      await cubit.setFilter(TaskFilter.completed);
      final callsAfterFirstVisit = repo.listCalls;
      expect(cubit.state.bucket(TaskFilter.completed).loaded, isTrue);
      expect(cubit.state.bucket(TaskFilter.completed).items, isEmpty);

      await cubit.setFilter(TaskFilter.pending);
      await cubit.setFilter(TaskFilter.completed);

      // Only the detour through "pending" (never loaded) issued a request;
      // returning to the already-empty "completed" bucket issued none.
      expect(repo.listCalls, callsAfterFirstVisit + 1);
    });

    test('setFilter fetches a bucket that has never been loaded', () async {
      final repo = FakeTaskRepository(
        pagesByStatus: {
          null: [page([buildTask('a')], total: 1)],
          'pending': [page([buildTask('a')], total: 1)],
        },
      );
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      final callsAfterLoad = repo.listCalls;

      expect(cubit.state.bucket(TaskFilter.pending).loaded, isFalse);
      await cubit.setFilter(TaskFilter.pending);

      expect(repo.listCalls, callsAfterLoad + 1);
      expect(cubit.state.bucket(TaskFilter.pending).loaded, isTrue);
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

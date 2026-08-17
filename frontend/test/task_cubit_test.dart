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

  group('TaskCubit timeline (PDR-003)', () {
    test('loadTimeline groups dated tasks by local day and separates undated ones', () async {
      final today = DateTime.now();
      final tomorrow = today.add(const Duration(days: 1));
      final repo = FakeTaskRepository(timelinePages: [
        page([
          buildTask('a', dueDate: today),
          buildTask('b', dueDate: tomorrow),
          buildTask('c'), // undated
        ]),
      ]);
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.loadTimeline('h1');

      final todayKey = DateTime(today.year, today.month, today.day);
      final tomorrowKey = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
      expect(cubit.state.timelineDays[todayKey]?.map((t) => t.id), ['a']);
      expect(cubit.state.timelineDays[tomorrowKey]?.map((t) => t.id), ['b']);
      expect(cubit.state.timelineUndated.map((t) => t.id), ['c']);
    });

    test('loadTimeline sends a window from yesterday through today+6', () async {
      final repo = FakeTaskRepository(timelinePages: [page([])]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      final before = DateTime.now();

      await cubit.loadTimeline('h1');

      final from = repo.receivedFrom.single!;
      final to = repo.receivedTo.single!;
      final expectedFrom = DateTime(before.year, before.month, before.day - 1);
      final expectedTo = DateTime(before.year, before.month, before.day + 6, 23, 59, 59, 999);
      expect(from, expectedFrom);
      expect(to, expectedTo);
    });

    test('"show more" is purely local: revealing a day\'s extra items issues no request',
        () async {
      // The cubit itself never fetches for "show more" — TasksPage's
      // _DaySection reveals already-loaded items locally. This test pins
      // that loadTimeline() alone already carries every item for the day
      // (nothing paginated per-day), which is what makes that possible.
      final today = DateTime.now();
      final repo = FakeTaskRepository(timelinePages: [
        page(List.generate(5, (i) => buildTask('t$i', dueDate: today))),
      ]);
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.loadTimeline('h1');

      final todayKey = DateTime(today.year, today.month, today.day);
      expect(cubit.state.timelineDays[todayKey], hasLength(5));
      expect(repo.timelineListCalls, 1);
    });

    test('loadMoreTimeline pages within the current window via the cursor first', () async {
      final today = DateTime.now();
      final repo = FakeTaskRepository(timelinePages: [
        page([buildTask('a', dueDate: today)], nextCursor: 'c1', hasMore: true),
        page([buildTask('b', dueDate: today)]),
      ]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.loadTimeline('h1');
      final windowToAfterLoad = cubit.state.timelineWindowTo;
      expect(cubit.state.timelineCursor, 'c1');

      // F11: the original version of this test called loadMoreTimeline()
      // immediately after loadTimeline(), with no emit in between — which
      // hid TD-056 (copyWith wiping timelineCursor on any unrelated emit),
      // since nothing else ever got a chance to clear it. An unrelated
      // cubit action (any copyWith call that doesn't mention
      // timelineCursor) interleaved here reproduces a real app's actual
      // emit pattern — MainScaffold fires several loads back to back, and
      // realtime events can land at any time — and must NOT lose the
      // cursor, or loadMoreTimeline below would incorrectly widen the
      // window instead of draining this page via the cursor.
      cubit.clearOfflineNotice();
      expect(cubit.state.timelineCursor, 'c1');

      await cubit.loadMoreTimeline();

      // Same window: the second scripted page was reached via the cursor,
      // not by widening `to`.
      expect(repo.receivedTo[1], windowToAfterLoad);
      expect(repo.receivedFrom[1], repo.receivedFrom[0]);
      final todayKey = DateTime(today.year, today.month, today.day);
      expect(
        cubit.state.timelineDays[todayKey]?.map((t) => t.id).toSet(),
        {'a', 'b'},
      );
      expect(cubit.state.timelineHasMore, isFalse);
    });

    test('loadMoreTimeline extends the window forward once the current one is exhausted',
        () async {
      final today = DateTime.now();
      final future = today.add(const Duration(days: 10));
      final repo = FakeTaskRepository(timelinePages: [
        page([buildTask('a', dueDate: today)]), // hasMore: false
        page([buildTask('a', dueDate: today), buildTask('b', dueDate: future)]),
      ]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.loadTimeline('h1');
      final initialTo = cubit.state.timelineWindowTo!;

      await cubit.loadMoreTimeline();

      // No cursor left in the current window, so it widened `to` instead and
      // re-fetched from scratch (cursor: null).
      expect(repo.receivedCursors[1], isNull);
      expect(repo.receivedTo[1], isNot(initialTo));
      expect(repo.receivedTo[1]!.isAfter(initialTo), isTrue);
      expect(cubit.state.timelineWindowTo, repo.receivedTo[1]);

      // The re-fetched 'a' (already bucketed) overwrote in place rather than
      // duplicating, and the newly-included 'b' was added.
      final todayKey = DateTime(today.year, today.month, today.day);
      final futureKey = DateTime(future.year, future.month, future.day);
      expect(cubit.state.timelineDays[todayKey]?.map((t) => t.id), ['a']);
      expect(cubit.state.timelineDays[futureKey]?.map((t) => t.id), ['b']);
    });

    test('loadTimeline/loadMoreTimeline never touch the TaskFilter.all bucket Home/Calendar read',
        () async {
      final today = DateTime.now();
      final repo = FakeTaskRepository(
        pagesByStatus: {
          null: [page([buildTask('home-1')], total: 1)],
        },
        timelinePages: [
          page([buildTask('t1', dueDate: today)], nextCursor: 'c1', hasMore: true),
          page([buildTask('t2', dueDate: today)]),
        ],
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      // Mirrors MainScaffold._loadForHousehold: both load() (for
      // Home/Calendar's `all` bucket) and loadTimeline() fire for the same
      // household.
      await cubit.load('h1');
      await cubit.loadTimeline('h1');
      await cubit.loadMoreTimeline();

      expect(cubit.state.allTasks.map((t) => t.id), ['home-1']);
    });
  });

  group('TaskCubit timeline stays in sync with mutations and realtime (bugfix)', () {
    // "Todas" (tasks_page.dart's _TimelineList) renders timelineDays/
    // timelineUndated directly, not bucket(TaskFilter.all) — so before this
    // fix, _upsert/_remove (the shared engine behind createTask, updateTask,
    // completeTask, deleteTask, restoreTask and applyRealtime) only touched
    // buckets and left the timeline stale: a created task never appeared on
    // the main tab, a deleted one stayed visible, and a realtime event from
    // another device updated nothing there at all.

    test('createTask inserts the new (undated) task into timelineUndated', () async {
      final repo = FakeTaskRepository(timelinePages: [page([])]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.loadTimeline('h1');
      expect(cubit.state.timelineUndated, isEmpty);

      // FakeTaskRepository.create() always returns an undated task, which
      // lands in "Sin fecha" — the backend includes undated tasks in every
      // window response regardless of from/to.
      await cubit.createTask({'title': 'Nueva'});

      expect(cubit.state.timelineUndated.map((t) => t.id), contains('created'));
    });

    test('deleteTask (online) removes the task from its timeline day', () async {
      final today = DateTime.now();
      final repo = FakeTaskRepository(timelinePages: [
        page([buildTask('t1', dueDate: today)]),
      ]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.loadTimeline('h1');
      final todayKey = DateTime(today.year, today.month, today.day);
      expect(cubit.state.timelineDays[todayKey]?.map((t) => t.id), ['t1']);

      await cubit.deleteTask('t1');

      expect(cubit.state.timelineDays[todayKey] ?? const [], isEmpty);
    });

    test('applyRealtime task:created inserts into the matching timeline day', () async {
      final today = DateTime.now();
      final repo = FakeTaskRepository(timelinePages: [page([])]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.loadTimeline('h1');

      cubit.applyRealtime('task:created', {
        'id': 'remote-1',
        'householdId': 'h1',
        'title': 'De otro dispositivo',
        'status': 'pending',
        'isRecurring': false,
        'dueDate': today.toIso8601String(),
      });

      final todayKey = DateTime(today.year, today.month, today.day);
      expect(cubit.state.timelineDays[todayKey]?.map((t) => t.id), contains('remote-1'));
    });

    test('applyRealtime task:deleted removes the task from the timeline', () async {
      final today = DateTime.now();
      final repo = FakeTaskRepository(timelinePages: [
        page([buildTask('t1', dueDate: today)]),
      ]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.loadTimeline('h1');
      final todayKey = DateTime(today.year, today.month, today.day);
      expect(cubit.state.timelineDays[todayKey]?.map((t) => t.id), ['t1']);

      cubit.applyRealtime('task:deleted', {'id': 't1', 'householdId': 'h1'});

      expect(cubit.state.timelineDays[todayKey] ?? const [], isEmpty);
    });

    test('applyRealtime task:updated moves the task to its new day when dueDate changes',
        () async {
      final today = DateTime.now();
      final tomorrow = today.add(const Duration(days: 1));
      final repo = FakeTaskRepository(timelinePages: [
        page([buildTask('t1', dueDate: today)]),
      ]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.loadTimeline('h1');

      cubit.applyRealtime('task:updated', {
        'id': 't1',
        'householdId': 'h1',
        'title': 'Tarea',
        'status': 'pending',
        'isRecurring': false,
        'dueDate': tomorrow.toIso8601String(),
      });

      final todayKey = DateTime(today.year, today.month, today.day);
      final tomorrowKey = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
      expect(cubit.state.timelineDays[todayKey] ?? const [], isEmpty);
      expect(cubit.state.timelineDays[tomorrowKey]?.map((t) => t.id), ['t1']);
    });

    test('a task due outside the loaded window is not added to the timeline', () async {
      final today = DateTime.now();
      final farFuture = today.add(const Duration(days: 30));
      final repo = FakeTaskRepository(timelinePages: [page([])]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.loadTimeline('h1');

      cubit.applyRealtime('task:created', {
        'id': 'far-1',
        'householdId': 'h1',
        'title': 'Muy lejos',
        'status': 'pending',
        'isRecurring': false,
        'dueDate': farFuture.toIso8601String(),
      });

      expect(
        cubit.state.timelineDays.values.expand((l) => l).map((t) => t.id),
        isNot(contains('far-1')),
      );
    });

    test('a mutation before loadTimeline() has ever run does not populate the timeline',
        () async {
      final repo = FakeTaskRepository(pages: [page([buildTask('1')])]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1'); // loadTimeline() deliberately never called

      await cubit.createTask({'title': 'Nueva'});

      expect(cubit.state.timelineDays, isEmpty);
      expect(cubit.state.timelineUndated, isEmpty);
    });
  });

  group('TaskCubit start-reminder notifications (PDR-004)', () {
    test('createTask with startsAt schedules a start reminder', () async {
      final notifications = RecordingNotificationService();
      final cubit = TaskCubit(FakeTaskRepository(), notifications);
      await cubit.load('h1');
      final startsAt = DateTime.now().add(const Duration(hours: 2));

      await cubit.createTask({'title': 'Pintar el salón', 'startsAt': startsAt.toIso8601String()});

      expect(notifications.scheduledStartReminders, hasLength(1));
      expect(notifications.scheduledStartReminders.single.startsAt, startsAt);
    });

    test('createTask without startsAt still calls scheduleTaskStartReminder (a no-op there)',
        () async {
      final notifications = RecordingNotificationService();
      final cubit = TaskCubit(FakeTaskRepository(), notifications);
      await cubit.load('h1');

      await cubit.createTask({'title': 'Instantánea'});

      // The call happens either way — NotificationService itself decides
      // there is nothing to schedule when startsAt is null.
      expect(notifications.scheduledStartReminders, hasLength(1));
      expect(notifications.scheduledStartReminders.single.startsAt, isNull);
    });

    test('deleteTask cancels the start reminder', () async {
      final notifications = RecordingNotificationService();
      final cubit = TaskCubit(FakeTaskRepository(), notifications);
      await cubit.load('h1');

      await cubit.deleteTask('t1');

      expect(notifications.canceledStartReminderIds, ['t1']);
    });

    test('completeTask cancels the start reminder', () async {
      final notifications = RecordingNotificationService();
      final cubit = TaskCubit(FakeTaskRepository(), notifications);
      await cubit.load('h1');

      await cubit.completeTask('t1');

      expect(notifications.canceledStartReminderIds, ['t1']);
    });

    test('updateTask with startsAt schedules a start reminder', () async {
      final notifications = RecordingNotificationService();
      final cubit = TaskCubit(FakeTaskRepository(), notifications);
      await cubit.load('h1');
      final startsAt = DateTime.now().add(const Duration(hours: 5));

      await cubit.updateTask('t1', {'startsAt': startsAt.toIso8601String()});

      expect(notifications.scheduledStartReminders, hasLength(1));
      expect(notifications.scheduledStartReminders.single.startsAt, startsAt);
    });
  });

  group('TaskCubit.loadRecurringTasks (TD-035)', () {
    blocTest<TaskCubit, TaskState>(
      'lists only isRecurring tasks, one row per series, sorted by next due date',
      build: () => TaskCubit(
        FakeTaskRepository(
          pages: [
            page([
              buildTask('not-recurring', title: 'Fregar'),
              buildTask('daily-1',
                  title: 'Regar plantas',
                  isRecurring: true,
                  recurrenceRule: {'type': 'daily', 'interval': 1},
                  dueDate: DateTime.utc(2026, 8, 20)),
              buildTask('weekly-1',
                  title: 'Sacar basura',
                  isRecurring: true,
                  recurrenceRule: {'type': 'weekly', 'interval': 1},
                  dueDate: DateTime.utc(2026, 8, 17)),
            ], nextCursor: null, hasMore: false, total: 3),
          ],
        ),
        FakeNotificationService(),
      ),
      act: (cubit) => cubit.loadRecurringTasks('h1'),
      expect: () => [
        isA<TaskState>().having((s) => s.recurringLoading, 'recurringLoading', true),
        isA<TaskState>()
            .having((s) => s.recurringLoading, 'recurringLoading', false)
            .having((s) => s.recurringLoaded, 'recurringLoaded', true)
            .having((s) => s.recurringTasks.map((t) => t.id).toList(), 'ids',
                ['weekly-1', 'daily-1']) // earliest dueDate first
            .having((s) => s.recurringTasks.every((t) => t.isRecurring), 'all recurring', true),
      ],
    );

    blocTest<TaskCubit, TaskState>(
      'drains every page before filtering, not just the first (avoids the original TD-035 bug)',
      build: () => TaskCubit(
        FakeTaskRepository(
          pages: [
            page([buildTask('p1-not-recurring', title: 'Página 1')],
                nextCursor: 'c1', hasMore: true, total: 2),
            page([
              buildTask('p2-recurring',
                  title: 'En página 2',
                  isRecurring: true,
                  recurrenceRule: {'type': 'monthly', 'interval': 1}),
            ], nextCursor: null, hasMore: false),
          ],
        ),
        FakeNotificationService(),
      ),
      act: (cubit) => cubit.loadRecurringTasks('h1'),
      expect: () => [
        isA<TaskState>().having((s) => s.recurringLoading, 'recurringLoading', true),
        isA<TaskState>().having(
            (s) => s.recurringTasks.map((t) => t.id).toList(), 'ids', ['p2-recurring']),
      ],
    );

    test('requests the second page with the cursor the first page returned', () async {
      final repo = FakeTaskRepository(
        pages: [
          page([buildTask('p1', title: 'Página 1')], nextCursor: 'c1', hasMore: true, total: 2),
          page([buildTask('p2', title: 'Página 2', isRecurring: true)],
              nextCursor: null, hasMore: false),
        ],
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.loadRecurringTasks('h1');

      expect(repo.receivedCursors, [null, 'c1']);
    });

    test('a series with only completed occurrences shows the most recently due one', () async {
      final repo = FakeTaskRepository(
        pages: [
          page([
            buildTask('series-a-old',
                title: 'Serie A (antigua)',
                completed: true,
                isRecurring: true,
                recurrenceRule: {'type': 'weekly'},
                dueDate: DateTime.utc(2026, 8, 1),
                parentTaskId: 'series-a-root'),
            buildTask('series-a-recent',
                title: 'Serie A (reciente)',
                completed: true,
                isRecurring: true,
                recurrenceRule: {'type': 'weekly'},
                dueDate: DateTime.utc(2026, 8, 10),
                parentTaskId: 'series-a-root'),
          ], nextCursor: null, hasMore: false),
        ],
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.loadRecurringTasks('h1');

      expect(cubit.state.recurringTasks.map((t) => t.id).toList(), ['series-a-recent']);
    });

    test('prefers the pending occurrence of a series over its completed ones', () async {
      final repo = FakeTaskRepository(
        pages: [
          page([
            buildTask('series-b-completed',
                title: 'Serie B (completada)',
                completed: true,
                isRecurring: true,
                recurrenceRule: {'type': 'weekly'},
                dueDate: DateTime.utc(2026, 8, 1),
                parentTaskId: 'series-b-root'),
            buildTask('series-b-pending',
                title: 'Serie B (pendiente)',
                isRecurring: true,
                recurrenceRule: {'type': 'weekly'},
                dueDate: DateTime.utc(2026, 8, 8),
                parentTaskId: 'series-b-root'),
          ], nextCursor: null, hasMore: false),
        ],
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.loadRecurringTasks('h1');

      expect(cubit.state.recurringTasks.map((t) => t.id).toList(), ['series-b-pending']);
    });

    blocTest<TaskCubit, TaskState>(
      'emits recurringError and an empty list when the fetch fails',
      build: () => TaskCubit(
        FakeTaskRepository(failListWith: const ServerFailure('boom')),
        FakeNotificationService(),
      ),
      act: (cubit) => cubit.loadRecurringTasks('h1'),
      expect: () => [
        isA<TaskState>().having((s) => s.recurringLoading, 'recurringLoading', true),
        isA<TaskState>()
            .having((s) => s.recurringLoading, 'recurringLoading', false)
            .having((s) => s.recurringError, 'recurringError', 'boom')
            .having((s) => s.recurringTasks, 'recurringTasks', isEmpty),
      ],
    );
  });

  group('TaskCubit.loadTrashTasks / restoreTask (TD-009)', () {
    blocTest<TaskCubit, TaskState>(
      'walks the includeDeleted list and keeps only deleted tasks, most recently deleted first',
      build: () => TaskCubit(
        FakeTaskRepository(
          pages: [
            page([
              buildTask('active', title: 'Sigue viva'),
              buildTask('deleted-old',
                  title: 'Borrada hace tiempo',
                  isDeleted: true,
                  deletedAt: DateTime.utc(2026, 8, 1)),
              buildTask('deleted-recent',
                  title: 'Borrada hace poco',
                  isDeleted: true,
                  deletedAt: DateTime.utc(2026, 8, 10)),
            ], nextCursor: null, hasMore: false, total: 3),
          ],
        ),
        FakeNotificationService(),
      ),
      act: (cubit) => cubit.loadTrashTasks('h1'),
      expect: () => [
        isA<TaskState>().having((s) => s.trashLoading, 'trashLoading', true),
        isA<TaskState>()
            .having((s) => s.trashLoading, 'trashLoading', false)
            .having((s) => s.trashLoaded, 'trashLoaded', true)
            .having((s) => s.trashTasks.map((t) => t.id).toList(), 'ids',
                ['deleted-recent', 'deleted-old'])
            .having((s) => s.trashTasks.every((t) => t.isDeleted), 'all deleted', true),
      ],
    );

    test('requests the list with includeDeleted:true', () async {
      final repo = FakeTaskRepository(
        pages: [page([buildTask('d1', isDeleted: true)], nextCursor: null, hasMore: false)],
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.loadTrashTasks('h1');

      expect(repo.receivedIncludeDeleted, [true]);
    });

    test('drains every page before filtering, not just the first', () async {
      final repo = FakeTaskRepository(
        pages: [
          page([buildTask('p1-active', title: 'Página 1')],
              nextCursor: 'c1', hasMore: true, total: 2),
          page([buildTask('p2-deleted', title: 'En página 2', isDeleted: true)],
              nextCursor: null, hasMore: false),
        ],
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      await cubit.loadTrashTasks('h1');

      expect(cubit.state.trashTasks.map((t) => t.id).toList(), ['p2-deleted']);
    });

    blocTest<TaskCubit, TaskState>(
      'emits trashError and an empty list when the fetch fails',
      build: () => TaskCubit(
        FakeTaskRepository(failListWith: const ServerFailure('boom')),
        FakeNotificationService(),
      ),
      act: (cubit) => cubit.loadTrashTasks('h1'),
      expect: () => [
        isA<TaskState>().having((s) => s.trashLoading, 'trashLoading', true),
        isA<TaskState>()
            .having((s) => s.trashLoading, 'trashLoading', false)
            .having((s) => s.trashError, 'trashError', 'boom')
            .having((s) => s.trashTasks, 'trashTasks', isEmpty),
      ],
    );

    test('restoreTask calls the repository and drops the task from trashTasks', () async {
      final repo = FakeTaskRepository();
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      cubit.emit(cubit.state.copyWith(
        trashTasks: [buildTask('d1', title: 'Borrada', isDeleted: true)],
      ));

      await cubit.restoreTask('d1');

      expect(repo.restoreCalls, ['d1']);
      expect(cubit.state.trashTasks, isEmpty);
    });

    test('restoreTask upserts the restored task back into the matching buckets', () async {
      final repo = FakeTaskRepository();
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      cubit.emit(cubit.state.copyWith(
        trashTasks: [buildTask('d1', title: 'Borrada', isDeleted: true)],
      ));

      await cubit.restoreTask('d1');

      expect(cubit.state.allTasks.map((t) => t.id), contains('d1'));
    });

    test('restoreTask surfaces a failure via trashError without touching trashTasks', () async {
      final repo = FakeTaskRepository(failRestoreWith: const ServerFailure('boom'));
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      final seeded = [buildTask('d1', title: 'Borrada', isDeleted: true)];
      cubit.emit(cubit.state.copyWith(trashTasks: seeded));

      await cubit.restoreTask('d1');

      expect(cubit.state.trashError, 'boom');
      expect(cubit.state.trashTasks, seeded);
    });
  });

  group('TaskCubit.reset (TD-058)', () {
    test('drops every bucket/timeline/recurring/trash entry back to the initial state', () async {
      final cubit = TaskCubit(
        FakeTaskRepository(
          pages: [page([buildTask('1')])],
          timelinePages: [page([buildTask('1', dueDate: DateTime.now())])],
        ),
        FakeNotificationService(),
      );
      await cubit.load('h1');
      await cubit.loadTimeline('h1');
      cubit.emit(cubit.state.copyWith(
        recurringTasks: [buildTask('r1', isRecurring: true)],
        trashTasks: [buildTask('d1', isDeleted: true)],
      ));
      expect(cubit.state.allTasks, isNotEmpty);
      expect(cubit.state.timelineDays, isNotEmpty);
      expect(cubit.householdId, 'h1');

      cubit.reset();

      expect(cubit.state, const TaskState());
      expect(cubit.householdId, isNull);
    });

    test('a load() after reset() starts a fresh fetch rather than being treated as a no-op',
        () async {
      final repo = FakeTaskRepository(pages: [
        page([buildTask('1')]),
        page([buildTask('1')]),
      ]);
      final cubit = TaskCubit(repo, FakeNotificationService());
      await cubit.load('h1');
      cubit.reset();

      await cubit.load('h1');

      // Two real fetches: reset() must not leave stale "already loaded"
      // bucket state that would make the second load() a silent no-op.
      expect(repo.listCalls, 2);
      expect(cubit.state.allTasks, isNotEmpty);
    });
  });

  group('TaskState.copyWith (TD-056)', () {
    /// Every field populated with a distinguishable non-default value, so a
    /// field silently reverting to its default (rather than being genuinely
    /// preserved) would still be caught.
    TaskState fullyPopulated() => TaskState(
          status: TaskStatusUi.loaded,
          error: 'some error',
          activeFilter: TaskFilter.pending,
          buckets: {
            TaskFilter.all: TaskBucket(
              items: [buildTask('1')],
              nextCursor: 'bc1',
              hasMore: true,
              total: 3,
              loaded: true,
            ),
          },
          isOffline: true,
          offlineNotice: 'saved offline',
          isSyncing: true,
          timelineDays: {
            DateTime(2026, 1, 1): [buildTask('2')],
          },
          timelineUndated: [buildTask('3')],
          timelineCursor: 'tc1',
          timelineHasMore: true,
          timelineWindowFrom: DateTime(2026, 1, 1),
          timelineWindowTo: DateTime(2026, 1, 10),
          timelineLoading: true,
          timelineLoadingMore: true,
          timelineError: 'timeline error',
          recurringTasks: [buildTask('4', isRecurring: true)],
          recurringLoading: true,
          recurringLoaded: true,
          recurringError: 'recurring error',
          trashTasks: [buildTask('5', isDeleted: true)],
          trashLoading: true,
          trashLoaded: true,
          trashError: 'trash error',
        );

    test('copyWith() with no arguments preserves every field except the '
        'deliberately one-shot offlineNotice', () {
      final original = fullyPopulated();

      final copied = original.copyWith();

      // Reconstructed by hand (not original.copyWith(offlineNotice: null))
      // so this test does not lean on the very method it is verifying.
      final expected = TaskState(
        status: original.status,
        error: original.error,
        activeFilter: original.activeFilter,
        buckets: original.buckets,
        isOffline: original.isOffline,
        offlineNotice: null,
        isSyncing: original.isSyncing,
        timelineDays: original.timelineDays,
        timelineUndated: original.timelineUndated,
        timelineCursor: original.timelineCursor,
        timelineHasMore: original.timelineHasMore,
        timelineWindowFrom: original.timelineWindowFrom,
        timelineWindowTo: original.timelineWindowTo,
        timelineLoading: original.timelineLoading,
        timelineLoadingMore: original.timelineLoadingMore,
        timelineError: original.timelineError,
        recurringTasks: original.recurringTasks,
        recurringLoading: original.recurringLoading,
        recurringLoaded: original.recurringLoaded,
        recurringError: original.recurringError,
        trashTasks: original.trashTasks,
        trashLoading: original.trashLoading,
        trashLoaded: original.trashLoaded,
        trashError: original.trashError,
      );

      expect(copied, expected);
      expect(copied.offlineNotice, isNull,
          reason: 'offlineNotice is the one deliberate exception (see its doc comment)');
      expect(copied.timelineCursor, 'tc1', reason: 'TD-056: must survive an untargeted copyWith');
    });

    test('each clearX flag nulls exactly its own field and leaves the other sticky ones alone', () {
      final original = fullyPopulated();

      expect(original.copyWith(clearError: true).error, isNull);
      expect(original.copyWith(clearError: true).timelineCursor, 'tc1');

      expect(original.copyWith(clearTimelineCursor: true).timelineCursor, isNull);
      expect(original.copyWith(clearTimelineCursor: true).error, 'some error');

      expect(original.copyWith(clearTimelineError: true).timelineError, isNull);
      expect(original.copyWith(clearTimelineError: true).recurringError, 'recurring error');

      expect(original.copyWith(clearRecurringError: true).recurringError, isNull);
      expect(original.copyWith(clearRecurringError: true).trashError, 'trash error');

      expect(original.copyWith(clearTrashError: true).trashError, isNull);
      expect(original.copyWith(clearTrashError: true).timelineError, 'timeline error');
    });

    test('passing a new value overwrites regardless of the clearX flag', () {
      final original = fullyPopulated();

      final copied = original.copyWith(error: 'new error', timelineCursor: 'tc2');

      expect(copied.error, 'new error');
      expect(copied.timelineCursor, 'tc2');
    });
  });

  group('TaskCubit.clearOfflineNotice (F7)', () {
    test('clears only offlineNotice — error/timelineCursor/timelineError/recurringError/'
        'trashError all survive', () async {
      final repo = FakeTaskRepository(
        pages: [page([buildTask('1')])],
        timelinePages: [
          page([buildTask('1', dueDate: DateTime.now())], nextCursor: 'tc1', hasMore: true),
        ],
      );
      final cubit = TaskCubit(repo, FakeNotificationService());

      // Reach a state with every field clearOfflineNotice must NOT touch,
      // via the cubit's own real operations where possible (load/
      // loadTimeline), so this reflects a state the app can actually land
      // in — F7 was specifically that these got wiped as a side effect of
      // an unrelated, purely-cosmetic "dismiss the offline banner" action.
      await cubit.load('h1');
      await cubit.loadTimeline('h1');
      expect(cubit.state.timelineCursor, 'tc1');
      cubit.emit(cubit.state.copyWith(
        error: 'boom',
        timelineError: 'timeline boom',
        recurringError: 'recurring boom',
        trashError: 'trash boom',
        offlineNotice: kOfflineNoticeMessage,
      ));
      expect(cubit.state.offlineNotice, kOfflineNoticeMessage);

      cubit.clearOfflineNotice();

      expect(cubit.state.offlineNotice, isNull);
      expect(cubit.state.error, 'boom');
      expect(cubit.state.timelineCursor, 'tc1');
      expect(cubit.state.timelineError, 'timeline boom');
      expect(cubit.state.recurringError, 'recurring boom');
      expect(cubit.state.trashError, 'trash boom');
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
    DateTime? from,
    DateTime? to,
    bool includeDeleted = false,
  }) async {
    receivedCursors.add(cursor);
    listCalls++;
    if (cursor == null) {
      return page([buildTask('1')], nextCursor: 'c1', hasMore: true, total: 5);
    }
    throw const ServerFailure('network down');
  }
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/timeline_cubit.dart';

import 'fakes.dart';

/// TD-064 commit 3: the timeline as its own cubit, with state normalized by id.
///
/// The properties worth pinning are the ones the previous design could not
/// offer: a walk that never revisits ground, a refresh that cannot be undone by
/// a slow earlier request, a prefetch that a fast scroll cannot multiply, and a
/// data structure in which the duplicate row of the last bug is not
/// representable.
void main() {
  PaginatedResponse<Task> page(
    List<Task> items, {
    String? nextCursor,
    bool hasMore = false,
  }) =>
      PaginatedResponse<Task>(
        items: items,
        nextCursor: nextCursor,
        hasMore: hasMore,
        total: items.length,
      );

  /// A dated task inside the walk (the window starts yesterday).
  Task dated(String id, {int inDays = 1, bool completed = false}) => buildTask(
        id,
        dueDate: DateTime.now().add(Duration(days: inDays)),
        completed: completed,
      );

  List<String> datedIds(TimelineCubit c) =>
      c.state.groups.days.values.expand((l) => l).map((t) => t.id).toList();

  group('initial load', () {
    test('keeps dated and undated separate, each with its own cursor',
        () async {
      final repo = FakeTaskRepository(
        keysetTimelinePages: [page([dated('d1')], nextCursor: 'c1', hasMore: true)],
        undatedPages: [page([buildTask('u1')], nextCursor: 'u-c1', hasMore: true)],
      );
      final cubit = TimelineCubit(repo);

      await cubit.load('h1');

      expect(datedIds(cubit), ['d1']);
      expect(cubit.state.undatedList.map((t) => t.id), ['u1']);
      expect(cubit.state.cursor, 'c1');
      expect(cubit.state.undatedCursor, 'u-c1');
      expect(cubit.state.isLoadingInitial, isFalse);
    });

    test('sends `from` at the start of yesterday, not now', () async {
      // The walk has to include today's earlier hours and yesterday's tail; a
      // `from` of "now" would hide tasks the user can still act on.
      final repo = FakeTaskRepository(keysetTimelinePages: [page([])]);
      await TimelineCubit(repo).load('h1');

      final sent = repo.receivedTimelineFrom.single;
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      expect(sent.year, yesterday.year);
      expect(sent.month, yesterday.month);
      expect(sent.day, yesterday.day);
      expect(sent.hour, 0);
      expect(sent.minute, 0);
    });

    test('an exhausted walk clears the cursor instead of keeping the old one',
        () async {
      final repo = FakeTaskRepository(
        keysetTimelinePages: [
          page([dated('d1')], nextCursor: 'c1', hasMore: true),
          page([dated('d2')]),
        ],
      );
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');
      await cubit.loadMore();

      expect(cubit.state.cursor, isNull);
      expect(cubit.state.hasMore, isFalse);
    });
  });

  group('normalized state', () {
    test('the same task arriving twice occupies one row, by construction',
        () async {
      // The shape of the bug this class exists to make impossible: the same id
      // from a page and then from a socket event.
      final repo = FakeTaskRepository(keysetTimelinePages: [page([dated('d1')])]);
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      cubit.applyRealtime('task:updated', {
        'id': 'd1',
        'householdId': 'h1',
        'title': 'Editada',
        'dueDate': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
      });

      expect(datedIds(cubit), ['d1']);
      expect(cubit.state.dated, hasLength(1));
    });

    test('replace() swaps an optimistic row for its confirmed entity',
        () async {
      final repo = FakeTaskRepository(keysetTimelinePages: [page([])]);
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      cubit.upsert(buildTask('pending-abc'));
      expect(cubit.state.undatedList.map((t) => t.id), ['pending-abc']);

      cubit.replace('pending-abc', buildTask('real'));

      expect(cubit.state.undatedList.map((t) => t.id), ['real']);
      expect(cubit.state.undated.containsKey('pending-abc'), isFalse);
    });

    test('a task that gains a due date leaves the undated half', () async {
      final repo = FakeTaskRepository(keysetTimelinePages: [page([])]);
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      cubit.upsert(buildTask('t1'));
      expect(cubit.state.undated.containsKey('t1'), isTrue);

      cubit.upsert(dated('t1'));

      expect(cubit.state.undated.containsKey('t1'), isFalse);
      expect(cubit.state.dated.containsKey('t1'), isTrue);
      expect(datedIds(cubit), ['t1']);
    });

    test('a task dated before the walk starts is not invented into it',
        () async {
      final repo = FakeTaskRepository(keysetTimelinePages: [page([])]);
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      cubit.upsert(buildTask('viejo', dueDate: DateTime.now().subtract(const Duration(days: 30))));

      expect(cubit.state.isEmpty, isTrue);
    });

    test('a delete event removes the row', () async {
      final repo = FakeTaskRepository(keysetTimelinePages: [page([dated('d1')])]);
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      cubit.applyRealtime('task:deleted', {'id': 'd1', 'householdId': 'h1'});

      expect(cubit.state.isEmpty, isTrue);
    });

    test('an event for another household is ignored', () async {
      final repo = FakeTaskRepository(keysetTimelinePages: [page([])]);
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      cubit.applyRealtime('task:created', {
        'id': 'ajena',
        'householdId': 'OTRA',
        'title': 'De otro hogar',
      });

      expect(cubit.state.isEmpty, isTrue);
    });
  });

  group('prefetch coalescing', () {
    test('three rapid calls produce ONE request', () async {
      // A flick fires the threshold repeatedly. Without coalescing each call
      // would re-send the same cursor and burn the request budget.
      final gate = Completer<void>();
      final repo = FakeTaskRepository(
        keysetTimelinePages: [
          page([dated('d1')], nextCursor: 'c1', hasMore: true),
          page([dated('d2')]),
        ],
      );
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      repo.timelineGate = gate.future;
      final first = cubit.loadMore();
      final second = cubit.loadMore();
      final third = cubit.loadMore();
      gate.complete();
      await Future.wait([first, second, third]);

      // One from load(), one from the coalesced loadMore().
      expect(repo.timelineCalls, 2);
      expect(datedIds(cubit)..sort(), ['d1', 'd2']);
    });

    test('does nothing once the walk is exhausted', () async {
      final repo = FakeTaskRepository(keysetTimelinePages: [page([dated('d1')])]);
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      await cubit.loadMore();

      expect(repo.timelineCalls, 1);
    });

    test('undated pages are NOT fetched by loadMore — only by loadMoreUndated',
        () async {
      // The product decision, as a test: dated tasks are a stretch the user is
      // walking; undated tasks are a drawer that costs nothing until opened.
      final repo = FakeTaskRepository(
        keysetTimelinePages: [
          page([dated('d1')], nextCursor: 'c1', hasMore: true),
          page([dated('d2')]),
        ],
        undatedPages: [
          page([buildTask('u1')], nextCursor: 'u-c1', hasMore: true),
          page([buildTask('u2')]),
        ],
      );
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      await cubit.loadMore();
      expect(repo.undatedCalls, 1, reason: 'scrolling must not pull the drawer');

      await cubit.loadMoreUndated();
      expect(repo.undatedCalls, 2);
      expect(cubit.state.undatedList.map((t) => t.id).toList()..sort(), ['u1', 'u2']);
    });
  });

  group('generation', () {
    test('a refresh discards the pages of the walk it replaced', () async {
      // The race the counter exists for: a first load still in flight when the
      // user pulls to refresh. Without it, the slow response merges back in and
      // resurrects what the refresh just replaced.
      final gate = Completer<void>();
      final repo = FakeTaskRepository(
        keysetTimelinePages: [
          page([dated('viejo')]),
          page([dated('nuevo')]),
        ],
        undatedPages: [page([]), page([])],
      );
      final cubit = TimelineCubit(repo);

      repo.timelineGate = gate.future;
      final slow = cubit.load('h1');
      final generationDuringLoad = cubit.state.generation;

      repo.timelineGate = null;
      await cubit.refresh();
      expect(cubit.state.generation, greaterThan(generationDuringLoad));

      gate.complete();
      await slow;

      expect(datedIds(cubit), ['nuevo']);
    });

    test('increases monotonically across load, refresh and reset', () async {
      final repo = FakeTaskRepository(keysetTimelinePages: [page([]), page([])]);
      final cubit = TimelineCubit(repo);

      final seen = <int>[cubit.state.generation];
      await cubit.load('h1');
      seen.add(cubit.state.generation);
      await cubit.refresh();
      seen.add(cubit.state.generation);
      cubit.reset();
      seen.add(cubit.state.generation);

      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThan(seen[i - 1]));
      }
    });

    test('reset clears the household so a late page cannot repopulate it',
        () async {
      final repo = FakeTaskRepository(keysetTimelinePages: [page([dated('d1')])]);
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      cubit.reset();

      expect(cubit.state.isEmpty, isTrue);
      expect(cubit.householdId, isNull);
      // An event arriving after the reset finds no walk to join.
      cubit.upsert(dated('tardio'));
      expect(cubit.state.isEmpty, isTrue);
    });
  });

  group('refresh and failure', () {
    test('does not empty the list while refreshing', () async {
      // Clearing first would flash a blank list on every pull, and would have
      // destroyed readable content if the request then failed.
      final gate = Completer<void>();
      final repo = FakeTaskRepository(
        keysetTimelinePages: [page([dated('d1')]), page([dated('d2')])],
        undatedPages: [page([]), page([])],
      );
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      repo.timelineGate = gate.future;
      final refreshing = cubit.refresh();

      expect(datedIds(cubit), ['d1'], reason: 'content stays visible');
      expect(cubit.state.isRefreshing, isTrue);

      gate.complete();
      await refreshing;
      expect(datedIds(cubit), ['d2']);
    });

    test('a failed loadMore keeps the cursor and the content', () async {
      // Losing the cursor on a failed page would end the walk silently: the
      // list would simply stop growing, with nothing to retry from.
      final repo = FakeTaskRepository(
        keysetTimelinePages: [page([dated('d1')], nextCursor: 'c1', hasMore: true)],
      );
      final cubit = TimelineCubit(repo);
      await cubit.load('h1');

      repo.failTimelineFrom = const NetworkFailure('sin red');
      repo.failTimelineFromCall = 1;
      await cubit.loadMore();

      expect(cubit.state.error, 'sin red');
      expect(cubit.state.cursor, 'c1', reason: 'the page can still be retried');
      expect(datedIds(cubit), ['d1'], reason: 'loaded content stays on screen');
      expect(cubit.state.isLoadingMore, isFalse);

      // And the retry works once the failure is lifted.
      repo.failTimelineFrom = null;
      await cubit.loadMore();
      expect(cubit.state.error, 'sin red', reason: 'stale error is not our concern here');
      expect(repo.timelineCalls, 3);
    });

    test('a failed initial load reports the error and leaves nothing behind',
        () async {
      final repo = FakeTaskRepository(
        keysetTimelinePages: [page([])],
        failListWith: const NetworkFailure('sin red'),
      );
      final cubit = TimelineCubit(repo);

      await cubit.load('h1');

      expect(cubit.state.error, 'sin red');
      expect(cubit.state.isLoadingInitial, isFalse);
      expect(cubit.state.isEmpty, isTrue);
    });
  });
}

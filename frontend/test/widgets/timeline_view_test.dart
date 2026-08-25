import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/household_cubit.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';
import 'package:homesync/presentation/cubit/timeline_cubit.dart';
import 'package:homesync/presentation/pages/tasks_page.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../fakes.dart';

/// The "Todas" tab as the user meets it (TD-064 commit 4).
///
/// Three behaviours that only exist at this layer: the scroll threshold that
/// decides when to fetch, the pull that must not blank the list, and the
/// banner that says the content is from cache. Plus the product rule that
/// undated tasks paginate by an explicit tap and never by scrolling.
void main() {
  // Day headers go through formatDueDate, which needs the 'es' locale data
  // main() loads at startup.
  setUpAll(() => initializeDateFormatting('es', null));

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

  Task dated(String id, {int inDays = 1}) => buildTask(
        id,
        title: 'Tarea $id',
        dueDate: DateTime.now().add(Duration(days: inDays)),
      );

  Future<TimelineCubit> pump(
    WidgetTester tester,
    FakeTaskRepository repo, {
    bool loadFirst = true,
  }) async {
    final timeline = TimelineCubit(repo);
    final tasks = TaskCubit(repo, FakeNotificationService(), timeline: timeline);
    await tasks.load('h1');
    if (loadFirst) await timeline.load('h1');

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<TaskCubit>.value(value: tasks),
          BlocProvider<TimelineCubit>.value(value: timeline),
          BlocProvider<HouseholdCubit>(
            create: (_) => HouseholdCubit(FakeHouseholdRepository()),
          ),
        ],
        child: const MaterialApp(home: TasksPage()),
      ),
    );
    await tester.pumpAndSettle();
    return timeline;
  }

  /// TasksPage opens on "Pendientes"; the timeline lives on the "Todas" tab.
  Future<void> openTodas(WidgetTester tester) async {
    await tester.tap(find.text('Todas'));
    await tester.pumpAndSettle();
  }

  testWidgets('scrolling near the bottom fetches the next DATED page',
      (tester) async {
    final repo = FakeTaskRepository(
      keysetTimelinePages: [
        page(List.generate(12, (i) => dated('d$i', inDays: i)),
            nextCursor: 'c1', hasMore: true),
        page([dated('extra', inDays: 20)]),
      ],
    );
    final timeline = await pump(tester, repo);
    await openTodas(tester);
    expect(repo.timelineCalls, 1);

    await tester.drag(find.byType(ListView).last, const Offset(0, -4000));
    await tester.pumpAndSettle();

    expect(repo.timelineCalls, 2, reason: 'the threshold pulled the next page');
    expect(timeline.state.dated.containsKey('extra'), isTrue);
  });

  testWidgets('a fast scroll does not multiply the request', (tester) async {
    // The coalescing lives in the cubit; this pins that the view does not work
    // around it by, say, calling load() instead of loadMore().
    final repo = FakeTaskRepository(
      keysetTimelinePages: [
        page(List.generate(12, (i) => dated('d$i', inDays: i)),
            nextCursor: 'c1', hasMore: true),
        page([dated('extra', inDays: 20)]),
      ],
    );
    await pump(tester, repo);
    await openTodas(tester);

    await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
    await tester.pump();
    await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
    await tester.pumpAndSettle();

    expect(repo.timelineCalls, lessThanOrEqualTo(2));
  });

  testWidgets('pull-to-refresh keeps the current rows visible while loading',
      (tester) async {
    final gate = Completer<void>();
    final repo = FakeTaskRepository(
      keysetTimelinePages: [page([dated('viejo')]), page([dated('nuevo')])],
      undatedPages: [page([]), page([])],
    );
    await pump(tester, repo);
    await openTodas(tester);
    expect(find.text('Tarea viejo'), findsOneWidget);

    repo.timelineGate = gate.future;
    await tester.fling(find.byType(ListView).last, const Offset(0, 500), 2000);
    await tester.pump();                                  // start the drag
    await tester.pump(const Duration(milliseconds: 300));  // let it settle into refreshing

    expect(repo.timelineCalls, 2, reason: 'the pull actually triggered a refresh');
    // Mid-refresh: the old content is still on screen, not a blank list.
    expect(find.text('Tarea viejo'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Tarea nuevo'), findsOneWidget);
  });

  testWidgets('the offline banner appears only when the content is stale',
      (tester) async {
    final repo = FakeTaskRepository(keysetTimelinePages: [page([dated('d1')])]);
    final timeline = await pump(tester, repo);
    await openTodas(tester);

    expect(find.byKey(const Key('timeline-stale-banner')), findsNothing);

    timeline.emit(timeline.state.copyWith(isStale: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timeline-stale-banner')), findsOneWidget);
    expect(find.text('Tarea d1'), findsOneWidget,
        reason: 'stale content is shown, not hidden');

    timeline.emit(timeline.state.copyWith(isStale: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timeline-stale-banner')), findsNothing);
  });

  group('undated tasks paginate by tap, never by scroll', () {
    testWidgets('"Ver más" appears only when the server says there is more',
        (tester) async {
      final repo = FakeTaskRepository(
        keysetTimelinePages: [page([])],
        undatedPages: [page([buildTask('u1', title: 'Sin fecha 1')])],
      );
      await pump(tester, repo);
      await openTodas(tester);

      expect(find.text('Sin fecha 1'), findsOneWidget);
      expect(find.byKey(const Key('undated-load-more')), findsNothing);
    });

    testWidgets('tapping "Ver más" loads the next undated page',
        (tester) async {
      final repo = FakeTaskRepository(
        keysetTimelinePages: [page([])],
        undatedPages: [
          page([buildTask('u1', title: 'Sin fecha 1')],
              nextCursor: 'u-c1', hasMore: true),
          page([buildTask('u2', title: 'Sin fecha 2')]),
        ],
      );
      await pump(tester, repo);
      await openTodas(tester);
      expect(repo.undatedCalls, 1);

      await tester.tap(find.byKey(const Key('undated-load-more')));
      await tester.pumpAndSettle();

      expect(repo.undatedCalls, 2);
      expect(find.text('Sin fecha 2'), findsOneWidget);
      expect(find.byKey(const Key('undated-load-more')), findsNothing,
          reason: 'the walk is exhausted, so the affordance goes away');
    });

    testWidgets('scrolling never pulls an undated page', (tester) async {
      // The product decision, at the layer that could break it: the drawer
      // costs nothing to someone who never opens it.
      final repo = FakeTaskRepository(
        keysetTimelinePages: [
          page(List.generate(12, (i) => dated('d$i', inDays: i)),
              nextCursor: 'c1', hasMore: true),
          page([dated('extra', inDays: 20)]),
        ],
        undatedPages: [
          page([buildTask('u1', title: 'Sin fecha 1')],
              nextCursor: 'u-c1', hasMore: true),
          page([buildTask('u2', title: 'Sin fecha 2')]),
        ],
      );
      await pump(tester, repo);
      await openTodas(tester);
      expect(repo.undatedCalls, 1);

      await tester.drag(find.byType(ListView).last, const Offset(0, -4000));
      await tester.pumpAndSettle();

      expect(repo.timelineCalls, 2, reason: 'dated pages DO prefetch');
      expect(repo.undatedCalls, 1, reason: 'undated pages do NOT');
    });
  });
}

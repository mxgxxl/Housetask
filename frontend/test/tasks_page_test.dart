import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/household_cubit.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';
import 'package:homesync/presentation/pages/tasks_page.dart';

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

/// Mounts the real TasksPage over a scripted repository.
Future<TaskCubit> pumpTasksPage(
  WidgetTester tester,
  FakeTaskRepository repo,
) async {
  final cubit = TaskCubit(repo, FakeNotificationService());
  await cubit.load('h1');
  // MainScaffold warms both up front (see main_scaffold.dart
  // _loadForHousehold); mirrored here so "Todas" (PDR-003 timeline) has data
  // to render exactly like it would in the real app.
  await cubit.loadTimeline('h1');

  await tester.pumpWidget(
    MaterialApp(
      home: MultiBlocProvider(
        providers: [
          BlocProvider<TaskCubit>.value(value: cubit),
          // TaskTile reads HouseholdCubit to resolve "who completed this"
          // (PDR-002); an empty/initial state is enough for these tests.
          BlocProvider<HouseholdCubit>(
            create: (_) => HouseholdCubit(FakeHouseholdRepository()),
          ),
        ],
        child: const TasksPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return cubit;
}

void main() {
  testWidgets('renders the three server-backed tabs', (tester) async {
    final repo = FakeTaskRepository(
      pagesByStatus: {
        null: [page([buildTask('a', title: 'Todas 1')], total: 1)],
      },
    );
    await pumpTasksPage(tester, repo);

    expect(find.text('Todas'), findsOneWidget);
    expect(find.text('Pendientes'), findsOneWidget);
    expect(find.text('Completadas'), findsOneWidget);
  });

  testWidgets('shows "loaded de total" in the header on a status tab (Pendientes)',
      (tester) async {
    // "Todas" is the PDR-003 timeline now, which has no count header — the
    // header lives only on the status tabs, so the assertion moves there.
    final repo = FakeTaskRepository(
      pagesByStatus: {
        'pending': [
          page(
            [buildTask('a'), buildTask('b')],
            nextCursor: 'c1',
            hasMore: true,
            total: 61,
          ),
        ],
      },
    );
    await pumpTasksPage(tester, repo);

    await tester.tap(find.text('Pendientes'));
    await tester.pumpAndSettle();

    // Without this a paginated list gives no way to tell "that is everything"
    // from "there is more below".
    expect(find.text('2 de 61'), findsOneWidget);
  });

  testWidgets('tapping "Completadas" queries the server with status=completed',
      (tester) async {
    final repo = FakeTaskRepository(
      pagesByStatus: {
        null: [page([buildTask('a', title: 'Pendiente A')], total: 1)],
        'completed': [
          page([buildTask('z', title: 'Hecha Z', completed: true)], total: 1),
        ],
      },
    );
    await pumpTasksPage(tester, repo);

    // The completed task is NOT in the "all" page: if the tab filtered locally
    // it could never appear, which is the bug this fixes.
    expect(find.text('Hecha Z'), findsNothing);

    await tester.tap(find.text('Completadas'));
    await tester.pumpAndSettle();

    expect(repo.receivedStatuses, contains('completed'));
    expect(find.text('Hecha Z'), findsOneWidget);
  });

  testWidgets('each tab keeps its own count, so one does not overwrite another',
      (tester) async {
    final repo = FakeTaskRepository(
      pagesByStatus: {
        'pending': [page([buildTask('a'), buildTask('b')], total: 61)],
        'completed': [page([buildTask('z', completed: true)], total: 40)],
      },
    );
    await pumpTasksPage(tester, repo);

    await tester.tap(find.text('Pendientes'));
    await tester.pumpAndSettle();
    expect(find.text('2 de 61'), findsOneWidget);

    await tester.tap(find.text('Completadas'));
    await tester.pumpAndSettle();

    expect(find.text('1 de 40'), findsOneWidget);
    expect(find.text('2 de 61'), findsNothing);
  });

  testWidgets('shows the footer spinner only in the active tab', (tester) async {
    // "Todas" no longer has a bucket-driven footer spinner (it is the
    // PDR-003 timeline, gated by timelineLoadingMore instead) — this now
    // exercises the two tabs that still work the original way.
    final repo = FakeTaskRepository(
      pagesByStatus: {
        'pending': [page([buildTask('a')], nextCursor: 'c1', hasMore: true, total: 9)],
        'completed': [page([buildTask('z', completed: true)], total: 1)],
      },
    );
    final cubit = await pumpTasksPage(tester, repo);

    await tester.tap(find.text('Pendientes'));
    await tester.pumpAndSettle();

    // Drive the state directly: the point under test is that the spinner is
    // scoped to the active bucket, not how a scroll produces it.
    final pending = cubit.state.bucket(TaskFilter.pending);
    cubit.emit(
      cubit.state.copyWith(
        buckets: {
          ...cubit.state.buckets,
          TaskFilter.pending: pending.copyWith(
            nextCursor: pending.nextCursor,
            isLoadingMore: true,
          ),
        },
      ),
    );
    // Two frames: the bloc delivers the new state asynchronously, so the
    // rebuild lands on the following frame. pumpAndSettle is unusable here —
    // a CircularProgressIndicator animates forever and never settles.
    await tester.pump();
    await tester.pump();

    // One spinner: the "Pendientes" footer. A shared controller used to
    // render it in every tab at once.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.text('Completadas'));
    // Fixed-duration pumps rather than pumpAndSettle, for the same reason.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // "Completadas" is not fetching, so its footer has no spinner.
    final completedBucket = cubit.state.bucket(TaskFilter.completed);
    expect(completedBucket.isLoadingMore, isFalse);
    expect(cubit.state.activeFilter, TaskFilter.completed);
  });

  testWidgets('re-tapping the active tab does not refetch', (tester) async {
    final repo = FakeTaskRepository(
      pagesByStatus: {
        null: [page([buildTask('a')], total: 1)],
      },
    );
    await pumpTasksPage(tester, repo);
    final callsAfterLoad = repo.listCalls;

    await tester.tap(find.text('Todas'));
    await tester.pumpAndSettle();

    expect(repo.listCalls, callsAfterLoad);
  });

  group('"Todas" as a day-grouped timeline (PDR-003)', () {
    testWidgets('renders "Sin fecha" first, then day sections with a formatted header',
        (tester) async {
      final today = DateTime.now();
      final tomorrow = today.add(const Duration(days: 1));
      final repo = FakeTaskRepository(timelinePages: [
        page([
          buildTask('u1', title: 'Sin fecha alguna'),
          buildTask('t1', title: 'Tarea de hoy', dueDate: today),
          buildTask('m1', title: 'Tarea de mañana', dueDate: tomorrow),
        ]),
      ]);
      await pumpTasksPage(tester, repo);

      // Two matches by design, not a collision: each day section's header
      // and its one TaskTile's own date label both go through the same
      // formatDueDate() helper, so both read "Sin fecha"/"Hoy"/"Mañana".
      expect(find.text('Sin fecha'), findsNWidgets(2));
      expect(find.text('Sin fecha alguna'), findsOneWidget);
      expect(find.text('Hoy'), findsNWidgets(2));
      expect(find.text('Tarea de hoy'), findsOneWidget);
      expect(find.text('Mañana'), findsNWidgets(2));
      expect(find.text('Tarea de mañana'), findsOneWidget);
    });

    testWidgets('"Mostrar más" reveals a day\'s extra tasks without issuing a new request',
        (tester) async {
      final today = DateTime.now();
      final repo = FakeTaskRepository(timelinePages: [
        page(List.generate(5, (i) => buildTask('t$i', title: 'Tarea $i', dueDate: today))),
      ]);
      await pumpTasksPage(tester, repo);
      final callsAfterLoad = repo.timelineListCalls;

      // Capped at 3 rows until "Mostrar más" is tapped.
      expect(find.text('Tarea 0'), findsOneWidget);
      expect(find.text('Tarea 1'), findsOneWidget);
      expect(find.text('Tarea 2'), findsOneWidget);
      expect(find.text('Tarea 3'), findsNothing);
      expect(find.text('Tarea 4'), findsNothing);
      expect(find.text('Mostrar más (2)'), findsOneWidget);

      await tester.tap(find.text('Mostrar más (2)'));
      await tester.pumpAndSettle();

      expect(find.text('Tarea 3'), findsOneWidget);
      expect(find.text('Tarea 4'), findsOneWidget);
      // Revealing already-loaded items is local state, not a fetch.
      expect(repo.timelineListCalls, callsAfterLoad);
    });
  });
}

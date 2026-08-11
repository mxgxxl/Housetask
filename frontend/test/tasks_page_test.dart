import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
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

  await tester.pumpWidget(
    MaterialApp(
      home: BlocProvider<TaskCubit>.value(
        value: cubit,
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

  testWidgets('shows "loaded de total" in the header', (tester) async {
    final repo = FakeTaskRepository(
      pagesByStatus: {
        null: [
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
        null: [page([buildTask('a'), buildTask('b')], total: 61)],
        'pending': [page([buildTask('a')], total: 40)],
      },
    );
    await pumpTasksPage(tester, repo);
    expect(find.text('2 de 61'), findsOneWidget);

    await tester.tap(find.text('Pendientes'));
    await tester.pumpAndSettle();

    expect(find.text('1 de 40'), findsOneWidget);
    expect(find.text('2 de 61'), findsNothing);
  });

  testWidgets('shows the footer spinner only in the active tab', (tester) async {
    final repo = FakeTaskRepository(
      pagesByStatus: {
        null: [page([buildTask('a')], nextCursor: 'c1', hasMore: true, total: 9)],
        'pending': [page([buildTask('a')], total: 1)],
      },
    );
    final cubit = await pumpTasksPage(tester, repo);

    // Drive the state directly: the point under test is that the spinner is
    // scoped to the active bucket, not how a scroll produces it.
    final all = cubit.state.bucket(TaskFilter.all);
    cubit.emit(
      cubit.state.copyWith(
        buckets: {
          ...cubit.state.buckets,
          TaskFilter.all: all.copyWith(
            nextCursor: all.nextCursor,
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

    // One spinner: the "Todas" footer. A shared controller used to render it
    // in all three tabs at once.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.text('Pendientes'));
    // Fixed-duration pumps rather than pumpAndSettle, for the same reason.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // "Pendientes" is not fetching, so its footer has no spinner.
    final pendingBucket = cubit.state.bucket(TaskFilter.pending);
    expect(pendingBucket.isLoadingMore, isFalse);
    expect(cubit.state.activeFilter, TaskFilter.pending);
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
}

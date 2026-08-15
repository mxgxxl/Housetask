import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/household_cubit.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';
import 'package:homesync/presentation/pages/trash_page.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../fakes.dart';

PaginatedResponse<Task> _page(List<Task> items) {
  return PaginatedResponse<Task>(items: items, nextCursor: null, hasMore: false, total: items.length);
}

/// Same rationale as recurring_tasks_page_test.dart's `_host`: MultiBlocProvider
/// wraps the whole MaterialApp so it stays an ancestor of whatever route is
/// currently showing, not just the first one.
Widget _host(TaskCubit taskCubit, {HouseholdCubit? householdCubit}) {
  return MultiBlocProvider(
    providers: [
      BlocProvider<TaskCubit>.value(value: taskCubit),
      BlocProvider<HouseholdCubit>.value(
        value: householdCubit ?? HouseholdCubit(FakeHouseholdRepository()),
      ),
    ],
    child: const MaterialApp(home: TrashPage()),
  );
}

void main() {
  // TaskTile's due-date label goes through DateFormat(..., 'es').
  setUpAll(() async {
    await initializeDateFormatting('es', null);
  });

  group('TrashPage (TD-009)', () {
    testWidgets('lists soft-deleted tasks from the server', (tester) async {
      final repo = FakeTaskRepository(pages: [
        _page([
          buildTask('active', title: 'Tarea activa'),
          buildTask('d1', title: 'Sacar la basura', isDeleted: true),
        ]),
      ]);
      final taskCubit = TaskCubit(repo, FakeNotificationService());
      await taskCubit.loadTrashTasks('h1');

      await tester.pumpWidget(_host(taskCubit));
      await tester.pump();

      expect(find.text('Sacar la basura'), findsOneWidget);
      expect(find.text('Tarea activa'), findsNothing);
    });

    testWidgets('shows the empty state when there is nothing deleted', (tester) async {
      final repo = FakeTaskRepository(pages: [
        _page([buildTask('active', title: 'Tarea activa')]),
      ]);
      final taskCubit = TaskCubit(repo, FakeNotificationService());
      await taskCubit.loadTrashTasks('h1');

      await tester.pumpWidget(_host(taskCubit));
      await tester.pump();

      expect(find.text('La papelera está vacía'), findsOneWidget);
    });

    testWidgets('tapping "Restaurar" calls TaskCubit.restoreTask, which calls the repository',
        (tester) async {
      final repo = FakeTaskRepository(pages: [
        _page([buildTask('d1', title: 'Sacar la basura', isDeleted: true)]),
      ]);
      final taskCubit = TaskCubit(repo, FakeNotificationService());
      await taskCubit.loadTrashTasks('h1');

      await tester.pumpWidget(_host(taskCubit));
      await tester.pump();

      expect(find.text('Restaurar'), findsOneWidget);
      await tester.tap(find.text('Restaurar'));
      await tester.pumpAndSettle();

      expect(repo.restoreCalls, ['d1']);
      // The restored row drops out of the trash list immediately.
      expect(find.text('Sacar la basura'), findsNothing);
    });
  });
}

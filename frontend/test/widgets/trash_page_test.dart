import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
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

  group('TrashPage — Vaciar papelera (TD-048)', () {
    testWidgets('shows a confirmation dialog, and Cancelar does not purge', (tester) async {
      final repo = FakeTaskRepository(pages: [
        _page([buildTask('d1', title: 'Vieja', isDeleted: true)]),
      ]);
      final taskCubit = TaskCubit(repo, FakeNotificationService());
      await taskCubit.loadTrashTasks('h1');

      await tester.pumpWidget(_host(taskCubit));
      await tester.pump();

      await tester.tap(find.byTooltip('Vaciar papelera'));
      await tester.pumpAndSettle();
      expect(
        find.text('¿Borrar permanentemente las tareas con más de 30 días?'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(repo.purgeCalls, isEmpty);
      // Nothing was reloaded/removed — the row is still there.
      expect(find.text('Vieja'), findsOneWidget);
    });

    testWidgets('confirming calls TaskCubit.purgeTrash and refreshes the list', (tester) async {
      final repo = FakeTaskRepository(
        pages: [
          _page([buildTask('d1', title: 'Vieja', isDeleted: true)]),
          _page(const []), // reload after a successful purge
        ],
        purgeResult: 1,
      );
      final taskCubit = TaskCubit(repo, FakeNotificationService());
      await taskCubit.loadTrashTasks('h1');

      await tester.pumpWidget(_host(taskCubit));
      await tester.pump();

      await tester.tap(find.byTooltip('Vaciar papelera'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Borrar'));
      await tester.pumpAndSettle();

      expect(repo.purgeCalls, ['h1']);
      expect(find.text('Se eliminó 1 tarea.'), findsOneWidget);
      expect(find.text('La papelera está vacía'), findsOneWidget);
    });

    testWidgets('shows the old-tasks banner only for entries past the retention window',
        (tester) async {
      final repo = FakeTaskRepository(pages: [
        _page([
          buildTask('old', title: 'Muy vieja', isDeleted: true,
              deletedAt: DateTime.now().subtract(const Duration(days: 45))),
          buildTask('recent', title: 'Reciente', isDeleted: true,
              deletedAt: DateTime.now().subtract(const Duration(days: 2))),
        ]),
      ]);
      final taskCubit = TaskCubit(repo, FakeNotificationService());
      await taskCubit.loadTrashTasks('h1');

      await tester.pumpWidget(_host(taskCubit));
      await tester.pump();

      expect(find.text('1 tarea antigua (+30 días)'), findsOneWidget);
    });

    testWidgets('surfaces a non-admin 403 as an error snackbar instead of purging',
        (tester) async {
      final repo = FakeTaskRepository(
        pages: [
          _page([buildTask('d1', title: 'Vieja', isDeleted: true)]),
        ],
        failPurgeWith: const ServerFailure('Only admins can purge the trash', statusCode: 403),
      );
      final taskCubit = TaskCubit(repo, FakeNotificationService());
      await taskCubit.loadTrashTasks('h1');

      await tester.pumpWidget(_host(taskCubit));
      await tester.pump();

      await tester.tap(find.byTooltip('Vaciar papelera'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Borrar'));
      await tester.pumpAndSettle();

      expect(find.text('Only admins can purge the trash'), findsOneWidget);
      // Nothing was removed from the list on failure.
      expect(find.text('Vieja'), findsOneWidget);
    });
  });
}

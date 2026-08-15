import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/household_cubit.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';
import 'package:homesync/presentation/pages/recurring_tasks_page.dart';
import 'package:homesync/presentation/pages/task_form_page.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../fakes.dart';

PaginatedResponse<Task> _page(List<Task> items) {
  return PaginatedResponse<Task>(items: items, nextCursor: null, hasMore: false, total: items.length);
}

/// MultiBlocProvider wraps the whole MaterialApp (not just `home`), so its
/// providers stay ancestors of every route MaterialApp's internal Navigator
/// pushes later — including TaskFormPage, pushed from a row's onTap. Wrapping
/// only `home` (as e.g. calendar_page_test.dart does, which never navigates
/// away) would leave a pushed route as a sibling of `home` in the Navigator's
/// stack, not a descendant of the providers.
Widget _host(TaskCubit taskCubit, {HouseholdCubit? householdCubit}) {
  return MultiBlocProvider(
    providers: [
      BlocProvider<TaskCubit>.value(value: taskCubit),
      BlocProvider<HouseholdCubit>.value(
        value: householdCubit ?? HouseholdCubit(FakeHouseholdRepository()),
      ),
    ],
    child: const MaterialApp(home: RecurringTasksPage()),
  );
}

void main() {
  // TaskTile's due-date label goes through DateFormat(..., 'es') — needs
  // locale data initialized, same as calendar_page_test.dart.
  setUpAll(() async {
    await initializeDateFormatting('es', null);
  });

  group('RecurringTasksPage (TD-035)', () {
    testWidgets('lists only recurring tasks, not the rest of the household\'s tasks',
        (tester) async {
      final repo = FakeTaskRepository(pages: [
        _page([
          buildTask('regular', title: 'Tarea normal'),
          buildTask(
            'rec1',
            title: 'Regar plantas',
            isRecurring: true,
            recurrenceRule: const {'type': 'weekly', 'interval': 1},
            dueDate: DateTime.utc(2026, 8, 20),
          ),
        ]),
      ]);
      final taskCubit = TaskCubit(repo, FakeNotificationService());
      await taskCubit.loadRecurringTasks('h1');

      await tester.pumpWidget(_host(taskCubit));
      await tester.pump();

      expect(find.text('Regar plantas'), findsOneWidget);
      expect(find.text('Tarea normal'), findsNothing);
      expect(find.text('Cada semana'), findsOneWidget);
    });

    testWidgets('shows one row per series even if several occurrences are loaded',
        (tester) async {
      final repo = FakeTaskRepository(pages: [
        _page([
          buildTask(
            'series-old',
            title: 'Sacar basura (antigua)',
            completed: true,
            isRecurring: true,
            recurrenceRule: const {'type': 'weekly'},
            dueDate: DateTime.utc(2026, 8, 1),
            parentTaskId: 'series-root',
          ),
          buildTask(
            'series-current',
            title: 'Sacar basura',
            isRecurring: true,
            recurrenceRule: const {'type': 'weekly'},
            dueDate: DateTime.utc(2026, 8, 8),
            parentTaskId: 'series-root',
          ),
        ]),
      ]);
      final taskCubit = TaskCubit(repo, FakeNotificationService());
      await taskCubit.loadRecurringTasks('h1');

      await tester.pumpWidget(_host(taskCubit));
      await tester.pump();

      expect(find.text('Sacar basura'), findsOneWidget);
      expect(find.text('Sacar basura (antigua)'), findsNothing);
    });

    testWidgets('shows the empty state with a creation hint when there are none',
        (tester) async {
      final repo = FakeTaskRepository(pages: [
        _page([buildTask('regular', title: 'Tarea normal')]),
      ]);
      final taskCubit = TaskCubit(repo, FakeNotificationService());
      await taskCubit.loadRecurringTasks('h1');

      await tester.pumpWidget(_host(taskCubit));
      await tester.pump();

      expect(find.text('Sin tareas recurrentes todavía'), findsOneWidget);
      expect(
        find.text('Crea una tarea y activa "Tarea recurrente" para que aparezca aquí.'),
        findsOneWidget,
      );
    });

    testWidgets('tapping a row navigates to the existing task detail/edit page',
        (tester) async {
      final repo = FakeTaskRepository(pages: [
        _page([
          buildTask(
            'rec1',
            title: 'Regar plantas',
            isRecurring: true,
            recurrenceRule: const {'type': 'daily', 'interval': 1},
          ),
        ]),
      ]);
      final taskCubit = TaskCubit(repo, FakeNotificationService());
      await taskCubit.loadRecurringTasks('h1');

      await tester.pumpWidget(_host(taskCubit));
      await tester.pump();

      expect(find.byType(TaskFormPage), findsNothing);

      await tester.tap(find.text('Regar plantas'));
      await tester.pumpAndSettle();

      expect(find.byType(TaskFormPage), findsOneWidget);
    });
  });
}

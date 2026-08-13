import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/household_cubit.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';
import 'package:homesync/presentation/pages/task_form_page.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'fakes.dart';

Future<TaskCubit> pumpTaskFormPage(
  WidgetTester tester, {
  Task? task,
  FakeTaskRepository? repo,
}) async {
  // The form has enough fields to exceed the default 800x600 test surface.
  // ListView(children:) is exactly as lazy about mounting off-screen
  // elements as ListView.builder (that laziness comes from the sliver
  // protocol, not the delegate type) — a field beyond the viewport + cache
  // extent simply is not in the element tree, so find() cannot see it
  // without scrolling to it first. A tall surface avoids that entirely.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final cubit = TaskCubit(repo ?? FakeTaskRepository(), FakeNotificationService());
  // TaskCubit.updateTask/createTask no-op until householdId is set, which
  // normally happens via TaskCubit.load() from MainScaffold long before
  // TaskFormPage is ever reachable.
  await cubit.load('h1');
  await tester.pumpWidget(
    MaterialApp(
      home: MultiBlocProvider(
        providers: [
          BlocProvider<TaskCubit>.value(value: cubit),
          // AssigneeSelector reads HouseholdCubit for the member list; an
          // empty/initial state is enough for these tests.
          BlocProvider<HouseholdCubit>(
            create: (_) => HouseholdCubit(FakeHouseholdRepository()),
          ),
        ],
        child: TaskFormPage(task: task),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return cubit;
}

void main() {
  // main.dart does this once at app startup; a plain pumpWidget() in a
  // widget test bypasses main() entirely, so any field whose display goes
  // through DateFormat(..., 'es') beyond the hardcoded Hoy/Mañana/Ayer
  // shortcuts (see ui_helpers.dart formatDueDate) throws LocaleDataException
  // unless this runs first.
  setUpAll(() async {
    await initializeDateFormatting('es', null);
  });

  group('TaskFormPage duration pickers (PDR-004)', () {
    testWidgets('a new task form shows the optional start/end pickers', (tester) async {
      await pumpTaskFormPage(tester);

      expect(find.text('Duración (opcional)'), findsOneWidget);
      expect(find.text('Inicio'), findsOneWidget);
      expect(find.text('Fin'), findsOneWidget);
    });

    testWidgets('turning recurrence on hides the duration pickers', (tester) async {
      await pumpTaskFormPage(tester);
      expect(find.text('Duración (opcional)'), findsOneWidget);

      await tester.tap(find.text('Tarea recurrente'));
      await tester.pumpAndSettle();

      expect(find.text('Duración (opcional)'), findsNothing);
      expect(find.text('Inicio'), findsNothing);
      expect(find.text('Fin'), findsNothing);
    });

    testWidgets('turning recurrence back off after picking a duration starts clean',
        (tester) async {
      final start = DateTime.now().add(const Duration(days: 1, hours: 1));
      final end = DateTime.now().add(const Duration(days: 1, hours: 3));
      final task = buildTask('1', startsAt: start, endsAt: end);
      await pumpTaskFormPage(tester, task: task);
      // Sanity: the loaded task's duration is showing before we touch anything.
      expect(find.text('Sin definir'), findsNothing);

      await tester.tap(find.text('Tarea recurrente'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tarea recurrente'));
      await tester.pumpAndSettle();

      // Cleared, not restored: PDR-004 says recurrence clears duration, and
      // that clearing does not get undone by toggling recurrence back off.
      expect(find.text('Sin definir'), findsNWidgets(2));
    });

    testWidgets('an endsAt not after startsAt shows an inline error', (tester) async {
      final start = DateTime.now().add(const Duration(days: 1, hours: 3));
      final end = DateTime.now().add(const Duration(days: 1, hours: 1)); // before start
      final task = buildTask('1', startsAt: start, endsAt: end);

      await pumpTaskFormPage(tester, task: task);

      expect(find.text('El fin debe ser posterior al inicio'), findsOneWidget);
    });

    testWidgets('no error is shown for a valid range or a start-only task', (tester) async {
      final start = DateTime.now().add(const Duration(days: 1, hours: 1));
      final end = DateTime.now().add(const Duration(days: 1, hours: 3));
      await pumpTaskFormPage(tester, task: buildTask('1', startsAt: start, endsAt: end));
      expect(find.text('El fin debe ser posterior al inicio'), findsNothing);

      await pumpTaskFormPage(tester, task: buildTask('2', startsAt: start));
      expect(find.text('El fin debe ser posterior al inicio'), findsNothing);
    });

    testWidgets('submitting a valid range sends startsAt/endsAt to the repository',
        (tester) async {
      final start = DateTime.now().add(const Duration(days: 1, hours: 1));
      final end = DateTime.now().add(const Duration(days: 1, hours: 3));
      final repo = FakeTaskRepository();
      final task = buildTask('1', title: 'Pintar el salón', startsAt: start, endsAt: end);

      await pumpTaskFormPage(tester, task: task, repo: repo);
      await tester.tap(find.text('Guardar cambios'));
      await tester.pumpAndSettle();

      expect(repo.receivedUpdatePayloads, hasLength(1));
      final payload = repo.receivedUpdatePayloads.single;
      expect(
        DateTime.parse(payload['startsAt'] as String).toIso8601String(),
        start.toIso8601String(),
      );
      expect(
        DateTime.parse(payload['endsAt'] as String).toIso8601String(),
        end.toIso8601String(),
      );
    });

    testWidgets(
        'submitting a recurring task never sends startsAt/endsAt, even if it had one before',
        (tester) async {
      final start = DateTime.now().add(const Duration(days: 1, hours: 1));
      final repo = FakeTaskRepository();
      final task = buildTask('1', startsAt: start);

      await pumpTaskFormPage(tester, task: task, repo: repo);
      await tester.tap(find.text('Tarea recurrente'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar cambios'));
      await tester.pumpAndSettle();

      expect(repo.receivedUpdatePayloads, hasLength(1));
      final payload = repo.receivedUpdatePayloads.single;
      expect(payload.containsKey('startsAt'), isFalse);
      expect(payload.containsKey('endsAt'), isFalse);
      expect(payload['isRecurring'], isTrue);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/cubit/household_cubit.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';
import 'package:homesync/presentation/pages/calendar_page.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'fakes.dart';

PaginatedResponse<Task> page(List<Task> items) => PaginatedResponse<Task>(
      items: items,
      nextCursor: null,
      hasMore: false,
      total: items.length,
    );

/// Mirrors calendar_page.dart's private `_isoDate` so tests can build the
/// same `monthDay-yyyy-MM-dd` keys without importing a private symbol.
String _isoTestDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Finds a month-grid spanning bar by task id regardless of which week row
/// it landed in (`monthBar-<id>-row<N>`) — the row index is an
/// implementation detail tests should not have to predict.
Finder _monthBarFinder(String taskId) => find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> && key.value.startsWith('monthBar-$taskId-row');
    });

/// The first Monday on/after the 8th of the current real month — safely
/// mid-month (never the grid's leading row from the previous month, never
/// near month-end) and a deterministic week-row start, so date arithmetic in
/// these tests never depends on which day "now" happens to be.
DateTime _safeMonday() {
  final now = DateTime.now();
  var day = DateTime(now.year, now.month, 8);
  return day.add(Duration(days: (DateTime.monday - day.weekday) % 7));
}

/// Mounts the real CalendarPage with [tasks] as the household's unfiltered
/// (TaskFilter.all) bucket — the same bucket Home/Calendar always read,
/// regardless of what the Tareas tabs or the PDR-003 timeline are doing.
Future<void> pumpCalendarPage(WidgetTester tester, List<Task> tasks) async {
  // The day detail can be tall (24-hour axis); avoid any risk of content
  // being scrolled out of the mounted element tree (see
  // task_form_page_test.dart for why ListView children beyond the viewport
  // + cache extent are not found by find()).
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final repo = FakeTaskRepository(pagesByStatus: {
    null: [page(tasks)],
  });
  final cubit = TaskCubit(repo, FakeNotificationService());
  await cubit.load('h1');

  await tester.pumpWidget(
    MaterialApp(
      home: MultiBlocProvider(
        providers: [
          BlocProvider<TaskCubit>.value(value: cubit),
          // TaskTile (rendered for all-day items) reads HouseholdCubit to
          // resolve "who completed this" (PDR-002).
          BlocProvider<HouseholdCubit>(
            create: (_) => HouseholdCubit(FakeHouseholdRepository()),
          ),
        ],
        child: const CalendarPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // TableCalendar (locale: 'es') and any duration display go through
  // DateFormat(..., 'es'), which needs locale data initialized — normally
  // done once in main.dart, bypassed entirely by a plain pumpWidget().
  setUpAll(() async {
    await initializeDateFormatting('es', null);
  });

  group('CalendarPage hour blocks (PDR-004)', () {
    testWidgets('a task with startsAt+endsAt renders inside the hour-axis section',
        (tester) async {
      final today = DateTime.now();
      final ranged = buildTask(
        'r1',
        title: 'Pintar el salón',
        dueDate: today,
        startsAt: DateTime(today.year, today.month, today.day, 13),
        endsAt: DateTime(today.year, today.month, today.day, 15),
      );

      await pumpCalendarPage(tester, [ranged]);

      final hourAxis = find.byKey(const Key('dayDetailHourAxis'));
      expect(hourAxis, findsOneWidget);
      expect(
        find.descendant(of: hourAxis, matching: find.text('Pintar el salón')),
        findsOneWidget,
      );
      // No all-day tasks in this fixture, so that section is absent entirely.
      expect(find.byKey(const Key('dayDetailAllDay')), findsNothing);
    });

    testWidgets('a start-only task (startsAt, no endsAt) renders in the all-day section',
        (tester) async {
      final today = DateTime.now();
      final startOnly = buildTask(
        's1',
        title: 'Solo inicio',
        dueDate: today,
        startsAt: DateTime(today.year, today.month, today.day, 9),
      );

      await pumpCalendarPage(tester, [startOnly]);

      final allDay = find.byKey(const Key('dayDetailAllDay'));
      expect(allDay, findsOneWidget);
      expect(find.descendant(of: allDay, matching: find.text('Solo inicio')), findsOneWidget);
      expect(find.byKey(const Key('dayDetailHourAxis')), findsNothing);
    });

    testWidgets('an instantaneous task (no startsAt at all) also renders in the all-day section',
        (tester) async {
      final today = DateTime.now();
      final instant = buildTask('i1', title: 'Tarea instantánea', dueDate: today);

      await pumpCalendarPage(tester, [instant]);

      final allDay = find.byKey(const Key('dayDetailAllDay'));
      expect(find.descendant(of: allDay, matching: find.text('Tarea instantánea')),
          findsOneWidget);
      expect(find.byKey(const Key('dayDetailHourAxis')), findsNothing);
    });

    testWidgets('mixes both in the same day: ranged in the hour axis, the rest in all-day',
        (tester) async {
      final today = DateTime.now();
      final ranged = buildTask(
        'r1',
        title: 'Con rango',
        dueDate: today,
        startsAt: DateTime(today.year, today.month, today.day, 8),
        endsAt: DateTime(today.year, today.month, today.day, 9, 30),
      );
      final instant = buildTask('i1', title: 'Sin rango', dueDate: today);

      await pumpCalendarPage(tester, [ranged, instant]);

      final allDay = find.byKey(const Key('dayDetailAllDay'));
      final hourAxis = find.byKey(const Key('dayDetailHourAxis'));
      expect(find.descendant(of: hourAxis, matching: find.text('Con rango')), findsOneWidget);
      expect(find.descendant(of: allDay, matching: find.text('Sin rango')), findsOneWidget);
      expect(find.descendant(of: allDay, matching: find.text('Con rango')), findsNothing);
      expect(find.descendant(of: hourAxis, matching: find.text('Sin rango')), findsNothing);
    });
  });

  group('CalendarPage month grid (PDR-004, Google Calendar-style)', () {
    testWidgets(
        'a multi-day ranged task renders as a single spanning bar covering every day it comprises',
        (tester) async {
      final monday = _safeMonday();
      final day1 = monday;
      final day2 = monday.add(const Duration(days: 1));
      final day3 = monday.add(const Duration(days: 2));
      final spanning = buildTask(
        'span1',
        title: 'Mudanza',
        startsAt: DateTime(day1.year, day1.month, day1.day, 9),
        endsAt: DateTime(day3.year, day3.month, day3.day, 18),
      );

      await pumpCalendarPage(tester, [spanning]);

      final bar = _monthBarFinder('span1');
      // All three days fall in the same Monday-start week row, so this is a
      // SINGLE bar widget, not one per day.
      expect(bar, findsOneWidget);

      final barRect = tester.getRect(bar);
      for (final day in [day1, day2, day3]) {
        final dayRect = tester.getRect(find.byKey(Key('monthDay-${_isoTestDate(day)}')));
        expect(barRect.left, lessThanOrEqualTo(dayRect.center.dx),
            reason: '${_isoTestDate(day)} should be under the bar');
        expect(barRect.right, greaterThanOrEqualTo(dayRect.center.dx),
            reason: '${_isoTestDate(day)} should be under the bar');
      }
    });

    testWidgets('a single-day ranged task renders as a time-range chip, not a bar',
        (tester) async {
      final day = _safeMonday();
      final task = buildTask(
        'chip1',
        title: 'Pintar el salón',
        startsAt: DateTime(day.year, day.month, day.day, 13),
        endsAt: DateTime(day.year, day.month, day.day, 20),
      );

      await pumpCalendarPage(tester, [task]);

      expect(find.byKey(const Key('monthChip-chip1')), findsOneWidget);
      expect(find.text('13:00–20:00 Pintar el salón'), findsOneWidget);
      expect(_monthBarFinder('chip1'), findsNothing);
    });

    testWidgets('an instant task still renders as the pre-existing marker dot, unchanged',
        (tester) async {
      final day = _safeMonday();
      final task = buildTask('dot1', title: 'Tarea instantánea', dueDate: day);

      await pumpCalendarPage(tester, [task]);

      expect(find.byKey(const Key('monthDot-dot1')), findsOneWidget);
      expect(find.byKey(const Key('monthChip-dot1')), findsNothing);
      expect(_monthBarFinder('dot1'), findsNothing);
    });
  });
}

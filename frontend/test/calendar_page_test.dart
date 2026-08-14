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

  group('CalendarPage day view — segmented blocks for multi-day tasks (PDR-004)', () {
    // Deliberately different start/end hours so the start-day and end-day
    // blocks land at distinct, individually-checkable heights.
    DateTime day1(DateTime monday) => monday;
    DateTime day2(DateTime monday) => monday.add(const Duration(days: 1));
    DateTime day3(DateTime monday) => monday.add(const Duration(days: 2));

    Task multiDayTask(DateTime monday, {String id = 'multi1'}) => buildTask(
          id,
          title: 'Mudanza',
          startsAt: DateTime(day1(monday).year, day1(monday).month, day1(monday).day, 14),
          endsAt: DateTime(day3(monday).year, day3(monday).month, day3(monday).day, 9),
        );

    testWidgets('the start day shows a block from startsAt to end-of-axis, continuing after',
        (tester) async {
      final monday = _safeMonday();
      final task = multiDayTask(monday);

      await pumpCalendarPage(tester, [task]);
      await tester.tap(find.byKey(Key('monthDay-${_isoTestDate(day1(monday))}')));
      await tester.pumpAndSettle();

      final block = find.byKey(const Key('dayBlock-multi1'));
      expect(block, findsOneWidget);
      // 14:00 -> 24:00 = 10 hours = 10 * 56px.
      expect(tester.getSize(block).height, closeTo(560, 1));
      expect(find.descendant(of: block, matching: find.byIcon(Icons.expand_more)), findsOneWidget);
      expect(find.descendant(of: block, matching: find.byIcon(Icons.expand_less)), findsNothing);
      expect(find.byKey(const Key('dayDetailContinuing')), findsNothing);
    });

    testWidgets('an intermediate day shows an all-day continuing bar, not a timed block',
        (tester) async {
      final monday = _safeMonday();
      final task = multiDayTask(monday);

      await pumpCalendarPage(tester, [task]);
      await tester.tap(find.byKey(Key('monthDay-${_isoTestDate(day2(monday))}')));
      await tester.pumpAndSettle();

      final continuing = find.byKey(const Key('dayDetailContinuing'));
      expect(continuing, findsOneWidget);
      expect(find.byKey(const Key('dayContinuing-multi1')), findsOneWidget);
      // "Mudanza" also legitimately appears in the month grid's spanning bar
      // above (this intermediate day is still under that bar) — scope the
      // text check to the day-detail's continuing section specifically.
      expect(find.descendant(of: continuing, matching: find.text('Mudanza')), findsOneWidget);
      expect(find.descendant(of: continuing, matching: find.text('continúa')), findsOneWidget);
      expect(find.byKey(const Key('dayDetailHourAxis')), findsNothing);
    });

    testWidgets('the end day shows a block from start-of-axis to endsAt, continuing before',
        (tester) async {
      final monday = _safeMonday();
      final task = multiDayTask(monday);

      await pumpCalendarPage(tester, [task]);
      await tester.tap(find.byKey(Key('monthDay-${_isoTestDate(day3(monday))}')));
      await tester.pumpAndSettle();

      final block = find.byKey(const Key('dayBlock-multi1'));
      expect(block, findsOneWidget);
      // 00:00 -> 09:00 = 9 hours = 9 * 56px.
      expect(tester.getSize(block).height, closeTo(504, 1));
      expect(find.descendant(of: block, matching: find.byIcon(Icons.expand_less)), findsOneWidget);
      expect(find.descendant(of: block, matching: find.byIcon(Icons.expand_more)), findsNothing);
      expect(find.byKey(const Key('dayDetailContinuing')), findsNothing);
    });
  });

  group('CalendarPage Mes/Semana selector and week view (PDR-004)', () {
    testWidgets('the selector shows both Mes and Semana segments, starting on Mes',
        (tester) async {
      await pumpCalendarPage(tester, []);

      expect(find.byKey(const Key('calendarViewSelector')), findsOneWidget);
      expect(find.text('Mes'), findsOneWidget);
      expect(find.text('Semana'), findsOneWidget);
      // Month grid visible by default: today's cell is present, no week header.
      expect(find.byKey(Key('monthDay-${_isoTestDate(DateTime.now())}')), findsOneWidget);
      expect(find.byKey(const Key('weekHeaderTitle')), findsNothing);
    });

    testWidgets('tapping Semana shows a 7-day grid for the week containing the selected day',
        (tester) async {
      final monday = _safeMonday();
      await pumpCalendarPage(tester, []);

      // Anchor on a known day first so the resulting week is deterministic,
      // then switch views — mirrors "was on Aug 15 in Mes, see its week".
      await tester.tap(find.byKey(Key('monthDay-${_isoTestDate(monday)}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Semana'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('weekHeaderTitle')), findsOneWidget);
      for (var i = 0; i < 7; i++) {
        final day = monday.add(Duration(days: i));
        expect(find.byKey(Key('monthDay-${_isoTestDate(day)}')), findsOneWidget,
            reason: '${_isoTestDate(day)} should be in the week grid');
      }
      // The month grid's own header/leading-days are gone.
      final prevWeekDay = monday.subtract(const Duration(days: 1));
      expect(find.byKey(Key('monthDay-${_isoTestDate(prevWeekDay)}')), findsNothing);
    });

    testWidgets('a multi-day task spanning the selected week renders as a spanning bar reusing month-grid logic',
        (tester) async {
      final monday = _safeMonday();
      final day1 = monday;
      final day3 = monday.add(const Duration(days: 2));
      final spanning = buildTask(
        'wspan1',
        title: 'Mudanza semanal',
        startsAt: DateTime(day1.year, day1.month, day1.day, 9),
        endsAt: DateTime(day3.year, day3.month, day3.day, 18),
      );

      await pumpCalendarPage(tester, [spanning]);
      await tester.tap(find.byKey(Key('monthDay-${_isoTestDate(monday)}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Semana'));
      await tester.pumpAndSettle();

      final bar = _monthBarFinder('wspan1');
      expect(bar, findsOneWidget);

      final barRect = tester.getRect(bar);
      for (final day in [day1, monday.add(const Duration(days: 1)), day3]) {
        final dayRect = tester.getRect(find.byKey(Key('monthDay-${_isoTestDate(day)}')));
        expect(barRect.left, lessThanOrEqualTo(dayRect.center.dx),
            reason: '${_isoTestDate(day)} should be under the bar');
        expect(barRect.right, greaterThanOrEqualTo(dayRect.center.dx),
            reason: '${_isoTestDate(day)} should be under the bar');
      }
    });

    testWidgets('the < > buttons in week view advance/retreat by full weeks, not months',
        (tester) async {
      final monday = _safeMonday();
      await pumpCalendarPage(tester, []);

      await tester.tap(find.byKey(Key('monthDay-${_isoTestDate(monday)}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Semana'));
      await tester.pumpAndSettle();

      final nextWeekMonday = monday.add(const Duration(days: 7));
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      for (var i = 0; i < 7; i++) {
        final day = nextWeekMonday.add(Duration(days: i));
        expect(find.byKey(Key('monthDay-${_isoTestDate(day)}')), findsOneWidget,
            reason: '${_isoTestDate(day)} should be in the next week');
      }
      expect(find.byKey(Key('monthDay-${_isoTestDate(monday)}')), findsNothing);

      // Back twice: once to undo, once more into the previous week.
      final prevWeekMonday = monday.subtract(const Duration(days: 7));
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      for (var i = 0; i < 7; i++) {
        final day = prevWeekMonday.add(Duration(days: i));
        expect(find.byKey(Key('monthDay-${_isoTestDate(day)}')), findsOneWidget,
            reason: '${_isoTestDate(day)} should be in the previous week');
      }
    });
  });
}

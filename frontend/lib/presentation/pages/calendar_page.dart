import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../config/theme.dart';
import '../../core/utils/ui_helpers.dart';
import '../../data/models/task.dart';
import '../cubit/task_cubit.dart';
import '../widgets/common.dart';
import '../widgets/task_tile.dart';
import 'task_form_page.dart';

/// Local-day key (time-of-day stripped) used throughout this file for day
/// comparisons/grouping — startsAt/endsAt/dueDate are device-local already
/// (see task_form_page.dart), so no timezone conversion belongs here.
DateTime _localDayKey(DateTime d) => DateTime(d.year, d.month, d.day);

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Every day a task should appear on (PDR-004, Google Calendar-style):
/// instant/start-only tasks by dueDate (unchanged), ranged tasks (both
/// startsAt and endsAt) by range membership — every day from startsAt's day
/// through endsAt's day inclusive, not just the day dueDate happens to fall
/// on.
List<Task> _tasksForDay(List<Task> tasks, DateTime day) {
  final dayKey = _localDayKey(day);
  return tasks.where((t) {
    if (t.startsAt != null && t.endsAt != null) {
      final start = _localDayKey(t.startsAt!);
      final end = _localDayKey(t.endsAt!);
      return !dayKey.isBefore(start) && !dayKey.isAfter(end);
    }
    final due = t.dueDate;
    return due != null && _localDayKey(due) == dayKey;
  }).toList();
}

/// Monthly calendar with a Google Calendar-style month grid (multi-day tasks
/// as spanning bars, single-day ranged tasks as time chips, instant/
/// start-only tasks as the pre-existing marker) plus a day detail below.
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime _focusedMonth = _localDayKey(DateTime.now());
  DateTime _selectedDay = _localDayKey(DateTime.now());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendario',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: BlocBuilder<TaskCubit, TaskState>(
        builder: (context, state) {
          // Unfiltered bucket: the calendar shows the whole month regardless
          // of which tab the tasks page is on.
          final allTasks = state.allTasks;
          final dayTasks = _tasksForDay(allTasks, _selectedDay);

          return Column(
            children: [
              Card(
                margin: const EdgeInsets.all(12),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: _MonthGrid(
                    focusedMonth: _focusedMonth,
                    selectedDay: _selectedDay,
                    tasks: allTasks,
                    onPrevMonth: () => setState(() {
                      _focusedMonth =
                          DateTime(_focusedMonth.year, _focusedMonth.month - 1, 1);
                    }),
                    onNextMonth: () => setState(() {
                      _focusedMonth =
                          DateTime(_focusedMonth.year, _focusedMonth.month + 1, 1);
                    }),
                    onDaySelected: (day) => setState(() => _selectedDay = day),
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: dayTasks.isEmpty
                    ? const EmptyState(
                        icon: Icons.event_available,
                        title: 'Sin tareas este día',
                      )
                    : _DayDetail(day: _selectedDay, tasks: dayTasks),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Month grid (PARTE B1)
// ---------------------------------------------------------------------------

/// A ranged task (startsAt+endsAt) whose start and end fall on different
/// days — the only kind the month grid draws as a spanning bar.
class _SpanningTask {
  final Task task;
  final DateTime startDay;
  final DateTime endDay;

  const _SpanningTask(this.task, this.startDay, this.endDay);
}

class _MonthClassification {
  final List<Task> instant;
  final List<Task> singleDayRanged;
  final List<_SpanningTask> spanning;

  const _MonthClassification(this.instant, this.singleDayRanged, this.spanning);
}

/// Splits the household's tasks into the three month-grid treatments
/// (PDR-004): instant/start-only tasks keep their pre-existing marker (no
/// distinct treatment is specified for start-only, so it is grouped with
/// instant); a ranged task starting and ending on the same day is a time
/// chip; a ranged task crossing a day boundary is a spanning bar.
_MonthClassification _classifyForMonth(List<Task> tasks) {
  final instant = <Task>[];
  final singleDayRanged = <Task>[];
  final spanning = <_SpanningTask>[];
  for (final t in tasks) {
    if (t.startsAt != null && t.endsAt != null) {
      final startDay = _localDayKey(t.startsAt!);
      final endDay = _localDayKey(t.endsAt!);
      if (startDay == endDay) {
        singleDayRanged.add(t);
      } else {
        spanning.add(_SpanningTask(t, startDay, endDay));
      }
    } else if (t.dueDate != null) {
      instant.add(t);
    }
  }
  return _MonthClassification(instant, singleDayRanged, spanning);
}

class _DayChip {
  final Task task;
  final bool isRanged;

  const _DayChip(this.task, {required this.isRanged});
}

/// Buckets instant + single-day-ranged tasks by the one day each renders on.
Map<DateTime, List<_DayChip>> _cellChipsFor(List<Task> instant, List<Task> singleDayRanged) {
  final map = <DateTime, List<_DayChip>>{};
  for (final t in instant) {
    final key = _localDayKey(t.dueDate!);
    map.putIfAbsent(key, () => []).add(_DayChip(t, isRanged: false));
  }
  for (final t in singleDayRanged) {
    final key = _localDayKey(t.startsAt!);
    map.putIfAbsent(key, () => []).add(_DayChip(t, isRanged: true));
  }
  return map;
}

/// The Monday-start weeks (each 7 consecutive days) needed to fully display
/// [monthAnchor]'s month, padded with the leading/trailing days of the
/// adjacent months.
List<List<DateTime>> _weeksFor(DateTime monthAnchor) {
  final firstOfMonth = DateTime(monthAnchor.year, monthAnchor.month, 1);
  final lastOfMonth = DateTime(monthAnchor.year, monthAnchor.month + 1, 0);
  final leadingOffset = firstOfMonth.weekday - DateTime.monday;
  final firstGridDay = firstOfMonth.subtract(Duration(days: leadingOffset));
  final trailingOffset = DateTime.sunday - lastOfMonth.weekday;
  final lastGridDay = lastOfMonth.add(Duration(days: trailingOffset));

  final weeks = <List<DateTime>>[];
  var cursor = firstGridDay;
  while (!cursor.isAfter(lastGridDay)) {
    weeks.add(List.generate(7, (i) => cursor.add(Duration(days: i))));
    cursor = cursor.add(const Duration(days: 7));
  }
  return weeks;
}

class _MonthGrid extends StatelessWidget {
  final DateTime focusedMonth;
  final DateTime selectedDay;
  final List<Task> tasks;
  final VoidCallback onPrevMonth;
  final VoidCallback onNextMonth;
  final ValueChanged<DateTime> onDaySelected;

  const _MonthGrid({
    required this.focusedMonth,
    required this.selectedDay,
    required this.tasks,
    required this.onPrevMonth,
    required this.onNextMonth,
    required this.onDaySelected,
  });

  @override
  Widget build(BuildContext context) {
    final weeks = _weeksFor(focusedMonth);
    final classification = _classifyForMonth(tasks);
    final cellChips = _cellChipsFor(classification.instant, classification.singleDayRanged);

    return Column(
      children: [
        _MonthHeader(focusedMonth: focusedMonth, onPrev: onPrevMonth, onNext: onNextMonth),
        const _WeekdayHeader(),
        for (var i = 0; i < weeks.length; i++)
          _WeekRow(
            week: weeks[i],
            rowIndex: i,
            focusedMonth: focusedMonth,
            selectedDay: selectedDay,
            cellChips: cellChips,
            spanningTasks: classification.spanning,
            onDaySelected: onDaySelected,
          ),
      ],
    );
  }
}

class _MonthHeader extends StatelessWidget {
  final DateTime focusedMonth;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  const _MonthHeader({required this.focusedMonth, required this.onPrev, required this.onNext});

  @override
  Widget build(BuildContext context) {
    final raw = DateFormat('MMMM y', 'es').format(focusedMonth);
    final title = raw.isEmpty ? raw : raw[0].toUpperCase() + raw.substring(1);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: onPrev),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        IconButton(icon: const Icon(Icons.chevron_right), onPressed: onNext),
      ],
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  static const _labels = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final label in _labels)
          Expanded(
            child: Center(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One spanning bar's position within a single week row — column indices are
/// relative to that row (0=Monday..6=Sunday), never absolute dates, since a
/// task crossing a week boundary needs one independently-clipped [_RowBar]
/// per row it touches.
class _RowBar {
  final Task task;
  final int startCol;
  final int endCol;

  /// True only when this row segment contains the task's ACTUAL start/end —
  /// false at a row-boundary clip, which is what tells [_SpanBar] whether to
  /// round that edge or draw it flat with a continuation chevron instead.
  final bool roundLeft;
  final bool roundRight;
  final bool continuesBefore;
  final bool continuesAfter;
  final int lane;

  const _RowBar({
    required this.task,
    required this.startCol,
    required this.endCol,
    required this.roundLeft,
    required this.roundRight,
    required this.continuesBefore,
    required this.continuesAfter,
    this.lane = 0,
  });

  _RowBar withLane(int newLane) => _RowBar(
        task: task,
        startCol: startCol,
        endCol: endCol,
        roundLeft: roundLeft,
        roundRight: roundRight,
        continuesBefore: continuesBefore,
        continuesAfter: continuesAfter,
        lane: newLane,
      );
}

/// Greedily assigns each bar the lowest lane whose last-occupied column ends
/// before this bar starts, so concurrent spanning tasks stack in separate
/// horizontal lanes instead of overlapping.
List<_RowBar> _assignLanes(List<_RowBar> bars) {
  final sorted = [...bars]..sort((a, b) => a.startCol.compareTo(b.startCol));
  final laneEndCols = <int>[];
  final result = <_RowBar>[];
  for (final bar in sorted) {
    final lane = laneEndCols.indexWhere((endCol) => endCol < bar.startCol);
    if (lane == -1) {
      laneEndCols.add(bar.endCol);
      result.add(bar.withLane(laneEndCols.length - 1));
    } else {
      laneEndCols[lane] = bar.endCol;
      result.add(bar.withLane(lane));
    }
  }
  return result;
}

class _WeekRow extends StatelessWidget {
  static const double _dayNumberHeight = 28;
  static const double _barHeight = 16;
  static const double _barSpacing = 2;

  final List<DateTime> week;
  final int rowIndex;
  final DateTime focusedMonth;
  final DateTime selectedDay;
  final Map<DateTime, List<_DayChip>> cellChips;
  final List<_SpanningTask> spanningTasks;
  final ValueChanged<DateTime> onDaySelected;

  const _WeekRow({
    required this.week,
    required this.rowIndex,
    required this.focusedMonth,
    required this.selectedDay,
    required this.cellChips,
    required this.spanningTasks,
    required this.onDaySelected,
  });

  List<_RowBar> _barsForRow() {
    final rowStart = week.first;
    final rowEnd = week.last;
    final bars = <_RowBar>[];
    for (final s in spanningTasks) {
      if (s.endDay.isBefore(rowStart) || s.startDay.isAfter(rowEnd)) continue;
      final barStartDay = s.startDay.isAfter(rowStart) ? s.startDay : rowStart;
      final barEndDay = s.endDay.isBefore(rowEnd) ? s.endDay : rowEnd;
      bars.add(_RowBar(
        task: s.task,
        startCol: barStartDay.difference(rowStart).inDays,
        endCol: barEndDay.difference(rowStart).inDays,
        roundLeft: barStartDay == s.startDay,
        roundRight: barEndDay == s.endDay,
        continuesBefore: barStartDay != s.startDay,
        continuesAfter: barEndDay != s.endDay,
      ));
    }
    return _assignLanes(bars);
  }

  @override
  Widget build(BuildContext context) {
    final laned = _barsForRow();
    final laneCount = laned.isEmpty ? 0 : laned.map((b) => b.lane).reduce((a, b) => a > b ? a : b) + 1;
    final barsAreaHeight = laneCount == 0 ? 0.0 : laneCount * (_barHeight + _barSpacing);

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: _dayNumberHeight,
            child: Row(
              children: [
                for (final day in week)
                  Expanded(
                    child: _DayNumberCell(
                      day: day,
                      isCurrentMonth: day.month == focusedMonth.month,
                      isSelected: _localDayKey(day) == _localDayKey(selectedDay),
                      onTap: () => onDaySelected(day),
                    ),
                  ),
              ],
            ),
          ),
          if (barsAreaHeight > 0)
            SizedBox(
              height: barsAreaHeight,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final colWidth = constraints.maxWidth / 7;
                  return Stack(
                    children: [
                      for (final bar in laned)
                        Positioned(
                          key: Key('monthBar-${bar.task.id}-row$rowIndex'),
                          top: bar.lane * (_barHeight + _barSpacing),
                          left: bar.startCol * colWidth + 2,
                          width: (bar.endCol - bar.startCol + 1) * colWidth - 4,
                          height: _barHeight,
                          child: GestureDetector(
                            onTap: () => onDaySelected(week[bar.startCol]),
                            child: _SpanBar(bar: bar),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final day in week)
                Expanded(
                  child: _DayChipsCell(
                    chips: cellChips[_localDayKey(day)] ?? const [],
                    onTap: () => onDaySelected(day),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayNumberCell extends StatelessWidget {
  final DateTime day;
  final bool isCurrentMonth;
  final bool isSelected;
  final VoidCallback onTap;

  const _DayNumberCell({
    required this.day,
    required this.isCurrentMonth,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isToday = _localDayKey(day) == _localDayKey(DateTime.now());
    final Color textColor;
    final BoxDecoration? decoration;
    if (isSelected) {
      textColor = Colors.white;
      decoration = const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle);
    } else if (isToday) {
      textColor = AppColors.primary;
      decoration = BoxDecoration(color: AppColors.primary.withValues(alpha: 0.16), shape: BoxShape.circle);
    } else {
      textColor = isCurrentMonth
          ? AppColors.textPrimary
          : AppColors.textSecondary.withValues(alpha: 0.5);
      decoration = null;
    }

    return GestureDetector(
      key: Key('monthDay-${_isoDate(day)}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: decoration,
          child: Text(
            '${day.day}',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textColor),
          ),
        ),
      ),
    );
  }
}

class _DayChipsCell extends StatelessWidget {
  static const int _maxDots = 3;

  final List<_DayChip> chips;
  final VoidCallback onTap;

  const _DayChipsCell({required this.chips, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox(height: 4);

    final ranged = chips.where((c) => c.isRanged).toList();
    final instant = chips.where((c) => !c.isRanged).take(_maxDots).toList();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in ranged)
              Container(
                key: Key('monthChip-${c.task.id}'),
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 2),
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${formatTime(c.task.startsAt!)}–${formatTime(c.task.endsAt!)} ${c.task.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (instant.isNotEmpty)
              Wrap(
                spacing: 2,
                children: [
                  for (final c in instant)
                    Container(
                      key: Key('monthDot-${c.task.id}'),
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: AppColors.secondary,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Renders one [_RowBar] segment: rounded only on the edge(s) that are the
/// task's true start/end (flat, plus a chevron, where a row clipped it).
class _SpanBar extends StatelessWidget {
  final _RowBar bar;

  const _SpanBar({required this.bar});

  @override
  Widget build(BuildContext context) {
    final color = bar.task.isCompleted ? AppColors.textSecondary : AppColors.primary;

    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.horizontal(
          left: Radius.circular(bar.roundLeft ? 8 : 0),
          right: Radius.circular(bar.roundRight ? 8 : 0),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (bar.continuesBefore)
            const Icon(Icons.chevron_left, size: 12, color: Colors.white),
          Flexible(
            child: Text(
              bar.task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                decoration: bar.task.isCompleted ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          if (bar.continuesAfter)
            const Icon(Icons.chevron_right, size: 12, color: Colors.white),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Day detail (PARTE B2)
// ---------------------------------------------------------------------------

enum _DaySegmentKind { block, continuing }

/// A ranged task's slice of one specific day (PDR-004): [overlapStart,
/// overlapEnd) = [max(startsAt, startOfDay), min(endsAt, endOfDay)) covers
/// same-day, start-day, end-day and intermediate-day uniformly. An
/// intermediate day (neither the task's start nor end day) renders as
/// [kind]=continuing instead of a full-height block.
class _DaySegment {
  final Task task;
  final _DaySegmentKind kind;
  final DateTime? start;
  final DateTime? end;
  final bool continuesBefore;
  final bool continuesAfter;

  const _DaySegment.block(
    this.task,
    this.start,
    this.end, {
    required this.continuesBefore,
    required this.continuesAfter,
  }) : kind = _DaySegmentKind.block;

  const _DaySegment.continuing(this.task)
      : kind = _DaySegmentKind.continuing,
        start = null,
        end = null,
        continuesBefore = true,
        continuesAfter = true;
}

/// Segments every ranged task in [rangedTasks] against [day] using a single
/// overlap rule (PDR-004): overlapStart = max(startsAt, startOfDay(day)),
/// overlapEnd = min(endsAt, endOfDay(day)). Tasks for which [day] is neither
/// their start day nor their end day are "continuing" (all-day) instead of a
/// timed block, since their overlap would otherwise span the whole axis.
List<_DaySegment> _segmentsForDay(List<Task> rangedTasks, DateTime day) {
  final dayKey = _localDayKey(day);
  final dayStart = dayKey;
  final dayEnd = dayStart.add(const Duration(days: 1));

  final segments = <_DaySegment>[];
  for (final t in rangedTasks) {
    final startsAt = t.startsAt!;
    final endsAt = t.endsAt!;
    final startDayKey = _localDayKey(startsAt);
    final endDayKey = _localDayKey(endsAt);

    if (startDayKey != dayKey && endDayKey != dayKey) {
      segments.add(_DaySegment.continuing(t));
      continue;
    }

    final overlapStart = startsAt.isAfter(dayStart) ? startsAt : dayStart;
    final overlapEnd = endsAt.isBefore(dayEnd) ? endsAt : dayEnd;
    if (!overlapStart.isBefore(overlapEnd)) continue;

    segments.add(_DaySegment.block(
      t,
      overlapStart,
      overlapEnd,
      continuesBefore: startDayKey != dayKey,
      continuesAfter: endDayKey != dayKey,
    ));
  }
  return segments;
}

/// PDR-004: a ranged task renders as a "continuing" all-day bar on an
/// intermediate day, or a timed block (whole or edge-clipped) otherwise.
/// Everything else (no duration, or start-only) lists as all-day above it —
/// exactly how every day's detail rendered before this feature.
class _DayDetail extends StatelessWidget {
  final DateTime day;
  final List<Task> tasks;

  const _DayDetail({required this.day, required this.tasks});

  @override
  Widget build(BuildContext context) {
    final ranged = tasks.where((t) => t.startsAt != null && t.endsAt != null).toList();
    final allDay = tasks.where((t) => t.startsAt == null || t.endsAt == null).toList();
    final segments = _segmentsForDay(ranged, day);
    final continuing = segments.where((s) => s.kind == _DaySegmentKind.continuing).toList();
    final blocks = segments.where((s) => s.kind == _DaySegmentKind.block).toList()
      ..sort((a, b) => a.start!.compareTo(b.start!));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (allDay.isNotEmpty)
          Column(
            key: const Key('dayDetailAllDay'),
            children: [
              for (final task in allDay)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _taskRow(context, task),
                ),
            ],
          ),
        if (continuing.isNotEmpty) ...[
          if (allDay.isNotEmpty) const SizedBox(height: 8),
          Column(
            key: const Key('dayDetailContinuing'),
            children: [for (final s in continuing) _ContinuingBar(segment: s)],
          ),
        ],
        if (blocks.isNotEmpty) ...[
          if (allDay.isNotEmpty || continuing.isNotEmpty) const SizedBox(height: 8),
          _HourAxis(key: const Key('dayDetailHourAxis'), segments: blocks),
        ],
      ],
    );
  }

  Widget _taskRow(BuildContext context, Task task) {
    return TaskTile(
      task: task,
      onToggle: () {
        if (task.isCompleted) {
          context.read<TaskCubit>().updateTask(task.id, {'status': 'pending'});
        } else {
          context.read<TaskCubit>().completeTask(task.id);
        }
      },
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TaskFormPage(task: task)),
      ),
    );
  }
}

/// All-day bar for a ranged task that merely passes through this day
/// (neither its start nor end) — Google Calendar-style "continues" strip,
/// not a timed block on the hour axis.
class _ContinuingBar extends StatelessWidget {
  final _DaySegment segment;

  const _ContinuingBar({required this.segment});

  @override
  Widget build(BuildContext context) {
    final task = segment.task;
    final color = task.isCompleted ? AppColors.textSecondary : AppColors.primary;

    return Padding(
      key: Key('dayContinuing-${task.id}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => TaskFormPage(task: task)),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.arrow_forward, size: 14, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                    color: task.isCompleted ? AppColors.textSecondary : AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text('continúa', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Vertical 24-hour axis with [segments] (each a ranged task's slice of THIS
/// day) drawn as positioned blocks — top offset and height derived from the
/// segment's own overlap start/end, never from list order. A segment clipped
/// by the day boundary (continuesBefore/continuesAfter) shows a chevron on
/// the clipped edge instead of implying the task starts/ends there.
/// Overlapping same-day blocks are not laid out side-by-side (out of scope
/// this round, unchanged from before): a household's task volume makes
/// same-hour conflicts rare, and simple stacking keeps this a first version
/// rather than a full calendar-collision layout engine.
class _HourAxis extends StatelessWidget {
  static const double _hourHeight = 56;
  static const double _labelWidth = 44;
  static const double _minBlockHeight = 28;

  final List<_DaySegment> segments;

  const _HourAxis({super.key, required this.segments});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _hourHeight * 24,
      child: Stack(
        children: [
          for (var hour = 0; hour < 24; hour++)
            Positioned(
              top: hour * _hourHeight,
              left: 0,
              right: 0,
              height: _hourHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _labelWidth,
                    child: Text(
                      '${hour.toString().padLeft(2, '0')}:00',
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ),
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Divider(height: 1),
                    ),
                  ),
                ],
              ),
            ),
          for (final segment in segments) _block(context, segment),
        ],
      ),
    );
  }

  Widget _block(BuildContext context, _DaySegment segment) {
    final start = segment.start!;
    final end = segment.end!;
    final top = (start.hour + start.minute / 60) * _hourHeight;
    final durationHours = end.difference(start).inMinutes / 60;
    final height = (durationHours * _hourHeight).clamp(_minBlockHeight, 24 * _hourHeight);
    final task = segment.task;

    return Positioned(
      key: Key('dayBlock-${task.id}'),
      top: top,
      left: _labelWidth + 8,
      right: 8,
      height: height,
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => TaskFormPage(task: task)),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: (task.isCompleted ? AppColors.textSecondary : AppColors.primary)
                .withValues(alpha: 0.16),
            border: Border.all(
              color: task.isCompleted ? AppColors.textSecondary : AppColors.primary,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (segment.continuesBefore)
                Icon(Icons.expand_less,
                    size: 12,
                    color: task.isCompleted ? AppColors.textSecondary : AppColors.primary),
              Text(
                task.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                  color: task.isCompleted ? AppColors.textSecondary : AppColors.textPrimary,
                ),
              ),
              if (segment.continuesAfter)
                Icon(Icons.expand_more,
                    size: 12,
                    color: task.isCompleted ? AppColors.textSecondary : AppColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

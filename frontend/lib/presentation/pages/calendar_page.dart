import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:table_calendar/table_calendar.dart';
import '../../config/theme.dart';
import '../../data/models/task.dart';
import '../cubit/task_cubit.dart';
import '../widgets/common.dart';
import '../widgets/task_tile.dart';
import 'task_form_page.dart';

/// Monthly calendar with markers on days that have tasks; tapping a day lists
/// its tasks below.
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  CalendarFormat _format = CalendarFormat.month;

  /// Group tasks that have a due date by day (midnight-normalized key).
  Map<DateTime, List<Task>> _eventsFrom(List<Task> tasks) {
    final map = <DateTime, List<Task>>{};
    for (final t in tasks) {
      final d = t.dueDate;
      if (d == null) continue;
      final key = DateTime.utc(d.year, d.month, d.day);
      map.putIfAbsent(key, () => []).add(t);
    }
    return map;
  }

  List<Task> _eventsForDay(Map<DateTime, List<Task>> events, DateTime day) {
    return events[DateTime.utc(day.year, day.month, day.day)] ?? [];
  }

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
          final events = _eventsFrom(state.allTasks);
          final dayTasks = _eventsForDay(events, _selectedDay);

          return Column(
            children: [
              Card(
                margin: const EdgeInsets.all(12),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: TableCalendar<Task>(
                    locale: 'es',
                    firstDay: DateTime.utc(2022, 1, 1),
                    lastDay: DateTime.utc(2030, 12, 31),
                    focusedDay: _focusedDay,
                    calendarFormat: _format,
                    startingDayOfWeek: StartingDayOfWeek.monday,
                    selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                    eventLoader: (day) => _eventsForDay(events, day),
                    onDaySelected: (selected, focused) {
                      setState(() {
                        _selectedDay = selected;
                        _focusedDay = focused;
                      });
                    },
                    onFormatChanged: (fmt) => setState(() => _format = fmt),
                    onPageChanged: (focused) => _focusedDay = focused,
                    availableCalendarFormats: const {
                      CalendarFormat.month: 'Mes',
                      CalendarFormat.twoWeeks: '2 semanas',
                      CalendarFormat.week: 'Semana',
                    },
                    calendarStyle: CalendarStyle(
                      todayDecoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.35),
                        shape: BoxShape.circle,
                      ),
                      selectedDecoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                      markerDecoration: const BoxDecoration(
                        color: AppColors.secondary,
                        shape: BoxShape.circle,
                      ),
                      markersMaxCount: 3,
                    ),
                    headerStyle: const HeaderStyle(
                      formatButtonShowsNext: false,
                      titleCentered: true,
                    ),
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
                    : _DayDetail(tasks: dayTasks),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// PDR-004: tasks with both startsAt and endsAt render as hour-positioned
/// blocks on a vertical axis, sorted by startsAt. Everything else (no
/// duration, or start-only) lists as all-day above it — exactly how every
/// day's detail rendered before this feature.
class _DayDetail extends StatelessWidget {
  final List<Task> tasks;

  const _DayDetail({required this.tasks});

  @override
  Widget build(BuildContext context) {
    final ranged = tasks.where((t) => t.startsAt != null && t.endsAt != null).toList()
      ..sort((a, b) => a.startsAt!.compareTo(b.startsAt!));
    final allDay = tasks.where((t) => t.startsAt == null || t.endsAt == null).toList();

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
        if (ranged.isNotEmpty) ...[
          if (allDay.isNotEmpty) const SizedBox(height: 8),
          _HourAxis(key: const Key('dayDetailHourAxis'), tasks: ranged),
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

/// Vertical 24-hour axis with [tasks] (all guaranteed startsAt+endsAt) drawn
/// as positioned blocks — top offset and height both derived from each
/// task's own start/end time, never from list order. Overlapping tasks are
/// not laid out side-by-side (out of scope): a household's task volume makes
/// same-hour conflicts rare, and simple stacking keeps this a first version
/// rather than a full calendar-collision layout engine.
class _HourAxis extends StatelessWidget {
  static const double _hourHeight = 56;
  static const double _labelWidth = 44;
  static const double _minBlockHeight = 28;

  final List<Task> tasks;

  const _HourAxis({super.key, required this.tasks});

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
          for (final task in tasks) _block(context, task),
        ],
      ),
    );
  }

  Widget _block(BuildContext context, Task task) {
    final start = task.startsAt!;
    final end = task.endsAt!;
    final top = (start.hour + start.minute / 60) * _hourHeight;
    final durationHours = end.difference(start).inMinutes / 60;
    final height = (durationHours * _hourHeight).clamp(_minBlockHeight, 24 * _hourHeight);

    return Positioned(
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
          child: Text(
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
        ),
      ),
    );
  }
}

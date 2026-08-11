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
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: dayTasks.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final task = dayTasks[i];
                          return TaskTile(
                            task: task,
                            onToggle: () {
                              if (task.isCompleted) {
                                context
                                    .read<TaskCubit>()
                                    .updateTask(task.id, {'status': 'pending'});
                              } else {
                                context.read<TaskCubit>().completeTask(task.id);
                              }
                            },
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => TaskFormPage(task: task)),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

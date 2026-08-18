import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
import '../../core/utils/ui_helpers.dart';
import '../../data/models/task.dart';
import '../cubit/auth_cubit.dart';
import '../cubit/household_cubit.dart';
import '../cubit/shopping_cubit.dart';
import '../cubit/task_cubit.dart';
import '../widgets/common.dart';
import '../widgets/task_tile.dart';
import 'shopping_form_page.dart';
import 'task_form_page.dart';

/// Dashboard: today's tasks, upcoming tasks, quick shopping list, and stats.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final userName = context.select((AuthCubit c) => c.state.user?.name ?? '');
    final householdName =
        context.select((HouseholdCubit c) => c.state.current?.name ?? 'Mi hogar');

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await context.read<TaskCubit>().refresh();
            await context.read<ShoppingCubit>().refresh();
          },
          child: BlocBuilder<TaskCubit, TaskState>(
            builder: (context, taskState) {
              // Reads the unfiltered bucket on purpose: the dashboard must not
              // change because the tasks tab is showing "Completadas".
              final all = taskState.allTasks;
              final pending = all.where((t) => !t.isCompleted).toList();
              final completed = all.where((t) => t.isCompleted).toList();
              final today = _todayTasks(pending);
              final upcoming = _upcomingTasks(pending);
              final completedThisWeek = _completedThisWeek(completed);
              final streak = _streak(completed);

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  _Greeting(name: userName, household: householdName),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          icon: Icons.task_alt,
                          value: '$completedThisWeek',
                          label: 'Completadas\nesta semana',
                          color: AppColors.priorityLow,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          icon: Icons.local_fire_department,
                          value: '$streak',
                          label: 'Días\nde racha',
                          color: AppColors.priorityMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const SectionHeader(title: 'Para hoy'),
                  if (today.isEmpty)
                    _emptyHint('¡Nada pendiente para hoy! 🎉')
                  else
                    ...today.map((t) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: TaskTile(
                            task: t,
                            isPending: context
                                .watch<TaskCubit>()
                                .state
                                .pendingIds
                                .contains(t.id),
                            onToggle: () =>
                                context.read<TaskCubit>().completeTask(t.id),
                            onTap: () => _openTask(context, t),
                          ),
                        )),
                  const SizedBox(height: 8),
                  const SectionHeader(title: 'Próximas tareas'),
                  if (upcoming.isEmpty)
                    _emptyHint('No hay próximas tareas')
                  else
                    ...upcoming.take(4).map((t) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: TaskTile(
                            task: t,
                            isPending: context
                                .watch<TaskCubit>()
                                .state
                                .pendingIds
                                .contains(t.id),
                            onToggle: () =>
                                context.read<TaskCubit>().completeTask(t.id),
                            onTap: () => _openTask(context, t),
                          ),
                        )),
                  const SizedBox(height: 8),
                  const SectionHeader(title: 'Lista de compra'),
                  const _QuickShopping(),
                ],
              );
            },
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _quickAdd(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _emptyHint(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: const TextStyle(color: AppColors.textSecondary)),
      );

  void _openTask(BuildContext context, Task task) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => TaskFormPage(task: task)));
  }

  List<Task> _todayTasks(List<Task> pending) {
    final now = DateTime.now();
    return pending.where((t) {
      final d = t.dueDate;
      return d != null &&
          d.year == now.year &&
          d.month == now.month &&
          d.day == now.day;
    }).toList();
  }

  List<Task> _upcomingTasks(List<Task> pending) {
    final now = DateTime.now();
    final endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59);
    return pending
        .where((t) => t.dueDate != null && t.dueDate!.isAfter(endOfToday))
        .toList();
  }

  int _completedThisWeek(List<Task> completed) {
    final weekAgo = DateTime.now().subtract(const Duration(days: 7));
    return completed
        .where((t) => t.completedAt != null && t.completedAt!.isAfter(weekAgo))
        .length;
  }

  /// Consecutive days (ending today or yesterday) with at least one completion.
  int _streak(List<Task> completed) {
    final days = completed
        .where((t) => t.completedAt != null)
        .map((t) => DateTime(
            t.completedAt!.year, t.completedAt!.month, t.completedAt!.day))
        .toSet();
    if (days.isEmpty) return 0;

    var streak = 0;
    var cursor = DateTime.now();
    cursor = DateTime(cursor.year, cursor.month, cursor.day);
    // Allow the streak to start today or yesterday.
    if (!days.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
      if (!days.contains(cursor)) return 0;
    }
    while (days.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  void _quickAdd(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.checklist, color: AppColors.primary),
              title: const Text('Nueva tarea'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const TaskFormPage()));
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.shopping_cart, color: AppColors.secondary),
              title: const Text('Nueva compra'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ShoppingFormPage()));
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  final String name;
  final String household;

  const _Greeting({required this.name, required this.household});

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Buenos días'
        : (hour < 20 ? 'Buenas tardes' : 'Buenas noches');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$greeting${name.isEmpty ? '' : ', ${name.split(' ').first}'} 👋',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(household, style: const TextStyle(color: AppColors.textSecondary)),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w800)),
                  Text(label,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondary, height: 1.1)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickShopping extends StatelessWidget {
  const _QuickShopping();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ShoppingCubit, ShoppingState>(
      builder: (context, state) {
        final items = state.pending.take(3).toList();
        if (items.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('La lista de compra está vacía',
                style: TextStyle(color: AppColors.textSecondary)),
          );
        }
        return Card(
          child: Column(
            children: [
              for (final item in items)
                ListTile(
                  leading: Icon(shoppingCategoryIcon(item.category),
                      color: AppColors.secondary),
                  title: Text(item.name),
                  subtitle: Text('${item.quantity} ${item.unit}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.check_circle_outline),
                    onPressed: () =>
                        context.read<ShoppingCubit>().togglePurchased(item),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

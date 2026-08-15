import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
import '../../core/utils/ui_helpers.dart';
import '../../data/models/task.dart';
import '../cubit/task_cubit.dart';
import '../widgets/common.dart';
import '../widgets/task_tile.dart';
import 'task_form_page.dart';

/// Recurrentes tab (TD-035): one row per recurring series, showing the
/// current occurrence — reuses [TaskCubit.recurringTasks], which is already
/// deduplicated to one representative per series and sorted by next due date.
class RecurringTasksPage extends StatelessWidget {
  const RecurringTasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recurrentes',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: BlocBuilder<TaskCubit, TaskState>(
        builder: (context, state) {
          if (state.recurringLoading && !state.recurringLoaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.recurringError != null && state.recurringTasks.isEmpty) {
            return _ErrorRetry(
              message: state.recurringError!,
              onRetry: () => _reload(context),
            );
          }
          if (state.recurringTasks.isEmpty) {
            return RefreshIndicator(
              onRefresh: () => _reload(context),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: const EmptyState(
                      icon: Icons.repeat,
                      title: 'Sin tareas recurrentes todavía',
                      subtitle:
                          'Crea una tarea y activa "Tarea recurrente" para que aparezca aquí.',
                    ),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () => _reload(context),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: state.recurringTasks.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) =>
                  _RecurringTaskRow(task: state.recurringTasks[i]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _reload(BuildContext context) async {
    final householdId = context.read<TaskCubit>().householdId;
    if (householdId != null) {
      await context.read<TaskCubit>().loadRecurringTasks(householdId);
    }
  }
}

/// A rule-label header ("Cada semana") above the shared [TaskTile], tapping
/// through to the same detail/edit page every other tab uses.
class _RecurringTaskRow extends StatelessWidget {
  final Task task;

  const _RecurringTaskRow({required this.task});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            recurrenceRuleLabel(task.recurrenceRule),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.secondary,
            ),
          ),
        ),
        TaskTile(
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
        ),
      ],
    );
  }
}

/// Error state with a retry action — same shape as tasks_page.dart's private
/// `_ErrorRetry`, duplicated here since that one is not exported.
class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

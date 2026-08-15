import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
import '../../data/models/task.dart';
import '../cubit/task_cubit.dart';
import '../widgets/common.dart';
import '../widgets/task_tile.dart';

/// Papelera / trash view (TD-009): every soft-deleted task, most recently
/// deleted first, each with a "Restaurar" action — reached from the Tareas
/// page's AppBar rather than its own bottom-nav tab, since it is a rarely
/// visited maintenance view, not a primary destination like Recurrentes.
class TrashPage extends StatelessWidget {
  const TrashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Papelera',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: BlocBuilder<TaskCubit, TaskState>(
        builder: (context, state) {
          if (state.trashLoading && !state.trashLoaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.trashError != null && state.trashTasks.isEmpty) {
            return _ErrorRetry(
              message: state.trashError!,
              onRetry: () => _reload(context),
            );
          }
          if (state.trashTasks.isEmpty) {
            return RefreshIndicator(
              onRefresh: () => _reload(context),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: const EmptyState(
                      icon: Icons.delete_outline,
                      title: 'La papelera está vacía',
                      subtitle: 'Las tareas que elimines aparecerán aquí.',
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
              itemCount: state.trashTasks.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _TrashTaskRow(task: state.trashTasks[i]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _reload(BuildContext context) async {
    final householdId = context.read<TaskCubit>().householdId;
    if (householdId != null) {
      await context.read<TaskCubit>().loadTrashTasks(householdId);
    }
  }
}

/// A read-only [TaskTile] (no toggle/tap — editing a deleted task makes no
/// sense) plus an explicit "Restaurar" action below it.
class _TrashTaskRow extends StatelessWidget {
  final Task task;

  const _TrashTaskRow({required this.task});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        TaskTile(task: task),
        TextButton.icon(
          onPressed: () => context.read<TaskCubit>().restoreTask(task.id),
          icon: const Icon(Icons.restore),
          label: const Text('Restaurar'),
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

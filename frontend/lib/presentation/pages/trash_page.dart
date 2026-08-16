import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
import '../../data/models/task.dart';
import '../cubit/task_cubit.dart';
import '../widgets/common.dart';
import '../widgets/task_tile.dart';

/// Retention window used only for the client-side "X tareas antiguas" hint
/// (TD-048) — the source of truth for what actually gets purged is the
/// backend's default (taskService.DEFAULT_PURGE_DAYS), which this mirrors.
const _purgeRetentionDays = 30;

/// Papelera / trash view (TD-009): every soft-deleted task, most recently
/// deleted first, each with a "Restaurar" action — reached from the Tareas
/// page's AppBar rather than its own bottom-nav tab, since it is a rarely
/// visited maintenance view, not a primary destination like Recurrentes.
///
/// Also exposes "Vaciar papelera" (TD-048, follow-up to TD-046: soft delete
/// had no cleanup policy) as an AppBar action — hard-deletes trash older
/// than 30 days via [TaskCubit.purgeTrash]. The backend enforces admin-only;
/// a non-admin tap surfaces the resulting 403 as a snackbar.
class TrashPage extends StatelessWidget {
  const TrashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Papelera',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Vaciar papelera',
            onPressed: () => _confirmPurge(context),
          ),
        ],
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

          final oldCount = _oldTaskCount(state.trashTasks);

          return RefreshIndicator(
            onRefresh: () => _reload(context),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: state.trashTasks.length + (oldCount > 0 ? 1 : 0),
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                if (oldCount > 0 && i == 0) {
                  return _OldCountBanner(count: oldCount);
                }
                final task = state.trashTasks[oldCount > 0 ? i - 1 : i];
                return _TrashTaskRow(task: task);
              },
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

  int _oldTaskCount(List<Task> tasks) {
    final cutoff = DateTime.now().subtract(const Duration(days: _purgeRetentionDays));
    return tasks.where((t) => t.deletedAt != null && t.deletedAt!.isBefore(cutoff)).length;
  }

  Future<void> _confirmPurge(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vaciar papelera'),
        content: const Text('¿Borrar permanentemente las tareas con más de 30 días?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final cubit = context.read<TaskCubit>();
    final deleted = await cubit.purgeTrash();
    if (!context.mounted) return;

    if (deleted == null) {
      showSnack(
        context,
        cubit.state.trashError ?? 'No se pudo vaciar la papelera',
        isError: true,
      );
    } else if (deleted == 0) {
      showSnack(context, 'No había tareas con más de 30 días.');
    } else {
      showSnack(context, deleted == 1 ? 'Se eliminó 1 tarea.' : 'Se eliminaron $deleted tareas.');
    }
  }
}

/// "X tareas antiguas (+30 días)" hint shown above the list when the trash
/// holds rows past the purge retention window — a nudge toward the AppBar's
/// "Vaciar papelera" action, not a separate control.
class _OldCountBanner extends StatelessWidget {
  final int count;

  const _OldCountBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          const Icon(Icons.history_toggle_off, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              count == 1
                  ? '1 tarea antigua (+$_purgeRetentionDays días)'
                  : '$count tareas antiguas (+$_purgeRetentionDays días)',
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
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

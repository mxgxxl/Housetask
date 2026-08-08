import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../config/theme.dart';
import '../../data/models/task.dart';
import '../cubit/task_cubit.dart';
import '../widgets/common.dart';
import '../widgets/task_tile.dart';
import 'task_form_page.dart';

/// Tasks tab: Pending / Completed / Recurring, with swipe-to-edit/delete.
class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Tareas',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
          bottom: const TabBar(
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.primary,
            tabs: [
              Tab(text: 'Pendientes'),
              Tab(text: 'Completadas'),
              Tab(text: 'Recurrentes'),
            ],
          ),
        ),
        body: BlocBuilder<TaskCubit, TaskState>(
          builder: (context, state) {
            if (state.status == TaskStatusUi.loading && state.tasks.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            return TabBarView(
              children: [
                _TaskList(tasks: state.pending, emptyLabel: 'No hay tareas pendientes'),
                _TaskList(tasks: state.completed, emptyLabel: 'Aún no has completado tareas'),
                _TaskList(tasks: state.recurring, emptyLabel: 'No hay tareas recurrentes'),
              ],
            );
          },
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openForm(context),
          icon: const Icon(Icons.add),
          label: const Text('Tarea'),
        ),
      ),
    );
  }

  void _openForm(BuildContext context, {Task? task}) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TaskFormPage(task: task)),
    );
  }
}

class _TaskList extends StatelessWidget {
  final List<Task> tasks;
  final String emptyLabel;

  const _TaskList({required this.tasks, required this.emptyLabel});

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return EmptyState(icon: Icons.checklist_rtl, title: emptyLabel);
    }

    return RefreshIndicator(
      onRefresh: () => context.read<TaskCubit>().refresh(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: tasks.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final task = tasks[i];
          return Slidable(
            key: ValueKey(task.id),
            endActionPane: ActionPane(
              motion: const DrawerMotion(),
              extentRatio: 0.5,
              children: [
                SlidableAction(
                  onPressed: (_) => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => TaskFormPage(task: task)),
                  ),
                  backgroundColor: AppColors.secondary,
                  foregroundColor: Colors.white,
                  icon: Icons.edit_outlined,
                  label: 'Editar',
                  borderRadius: BorderRadius.circular(16),
                ),
                SlidableAction(
                  onPressed: (_) => _confirmDelete(context, task),
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white,
                  icon: Icons.delete_outline,
                  label: 'Eliminar',
                  borderRadius: BorderRadius.circular(16),
                ),
              ],
            ),
            child: TaskTile(
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
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Task task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar tarea'),
        content: Text('¿Seguro que quieres eliminar "${task.title}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      context.read<TaskCubit>().deleteTask(task.id);
    }
  }
}

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
            if (state.status == TaskStatusUi.error && state.tasks.isEmpty) {
              return _ErrorRetry(
                message: state.error ?? 'No se pudieron cargar las tareas',
                onRetry: () => context.read<TaskCubit>().refresh(),
              );
            }
            return TabBarView(
              children: [
                _TaskList(
                  tasks: state.pending,
                  emptyLabel: 'No hay tareas pendientes',
                  isLoadingMore: state.isLoadingMore,
                  hasMore: state.hasMore,
                ),
                _TaskList(
                  tasks: state.completed,
                  emptyLabel: 'Aún no has completado tareas',
                  isLoadingMore: state.isLoadingMore,
                  hasMore: state.hasMore,
                ),
                _TaskList(
                  tasks: state.recurring,
                  emptyLabel: 'No hay tareas recurrentes',
                  isLoadingMore: state.isLoadingMore,
                  hasMore: state.hasMore,
                ),
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

/// A tab's list.
///
/// Stateful because infinite scroll needs a ScrollController. The three tabs
/// filter one paginated list client-side, so scrolling any of them pulls the
/// next page of the shared list rather than of that tab's subset.
class _TaskList extends StatefulWidget {
  final List<Task> tasks;
  final String emptyLabel;
  final bool isLoadingMore;
  final bool hasMore;

  const _TaskList({
    required this.tasks,
    required this.emptyLabel,
    required this.isLoadingMore,
    required this.hasMore,
  });

  @override
  State<_TaskList> createState() => _TaskListState();
}

class _TaskListState extends State<_TaskList> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  /// Fetch the next page before the user reaches the bottom, so the list keeps
  /// moving. The cubit's isLoadingMore guard absorbs the repeated calls this
  /// fires while scrolling through the trigger zone.
  void _onScroll() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (position.pixels > position.maxScrollExtent * 0.8) {
      context.read<TaskCubit>().loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = widget.tasks;

    if (tasks.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => context.read<TaskCubit>().refresh(),
        // AlwaysScrollable keeps pull-to-refresh reachable on an empty list.
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: EmptyState(icon: Icons.checklist_rtl, title: widget.emptyLabel),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => context.read<TaskCubit>().refresh(),
      child: ListView.separated(
        controller: _controller,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: tasks.length + (widget.isLoadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          // Footer spinner while the next page is in flight; nothing at all
          // once the list is exhausted.
          if (i >= tasks.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
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


/// Error state with a retry action, shown when the first page fails.
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

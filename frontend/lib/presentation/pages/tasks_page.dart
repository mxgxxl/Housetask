import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../config/theme.dart';
import '../../core/utils/ui_helpers.dart';
import '../../data/models/task.dart';
import '../cubit/task_cubit.dart';
import '../widgets/common.dart';
import '../widgets/task_tile.dart';
import 'task_form_page.dart';

/// The tabs, in display order. Each one is a server-side filter, not a local
/// `where` over a shared list.
const _tabs = <({TaskFilter filter, String label, String emptyLabel})>[
  (filter: TaskFilter.all, label: 'Todas', emptyLabel: 'No hay tareas todavía'),
  (
    filter: TaskFilter.pending,
    label: 'Pendientes',
    emptyLabel: 'No hay tareas pendientes'
  ),
  (
    filter: TaskFilter.completed,
    label: 'Completadas',
    emptyLabel: 'Aún no has completado tareas'
  ),
];

/// Tasks tab: Todas / Pendientes / Completadas, with swipe-to-edit/delete.
///
/// Every tab paginates independently against `?status=`, so opening
/// "Completadas" fetches completed tasks instead of waiting for the user to
/// scroll past every pending one.
class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  /// One controller per tab: a shared one would scroll all three together and
  /// show a single tab's spinner in every tab.
  late final List<ScrollController> _scrollControllers;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(_onTabChanged);

    _scrollControllers = List.generate(_tabs.length, (index) {
      final controller = ScrollController();
      controller.addListener(() => _onScroll(index, controller));
      return controller;
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    for (final controller in _scrollControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onTabChanged() {
    // Fires twice per swipe (start and end of the animation); acting only on
    // the settled index avoids firing a request for a tab being passed over.
    if (_tabController.indexIsChanging) return;
    context.read<TaskCubit>().setFilter(_tabs[_tabController.index].filter);
  }

  /// Fetch the next page shortly before the bottom, but only for the tab the
  /// user is actually looking at — off-screen tabs must not paginate.
  ///
  /// "Todas" (PDR-003) is a day-grouped timeline with its own window-based
  /// pagination, not a status bucket, so it extends via [TaskCubit.
  /// loadMoreTimeline] instead of the regular [TaskCubit.loadMore].
  void _onScroll(int index, ScrollController controller) {
    if (index != _tabController.index) return;
    if (!controller.hasClients) return;

    final position = controller.position;
    if (position.pixels > position.maxScrollExtent * 0.8) {
      if (_tabs[index].filter == TaskFilter.all) {
        context.read<TaskCubit>().loadMoreTimeline();
      } else {
        context.read<TaskCubit>().loadMore();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tareas',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          tabs: [for (final tab in _tabs) Tab(text: tab.label)],
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
            controller: _tabController,
            children: [
              for (var i = 0; i < _tabs.length; i++)
                if (_tabs[i].filter == TaskFilter.all)
                  // "Todas" is the PDR-003 day-grouped timeline, not a status
                  // bucket — it reads TaskCubit's timeline* fields directly
                  // rather than `state.bucket(TaskFilter.all)`, which stays
                  // reserved for Home/Calendar (see TaskState.timelineDays doc).
                  _TimelineList(
                    days: state.timelineDays,
                    undated: state.timelineUndated,
                    loading: state.timelineLoading,
                    loadingMore: state.timelineLoadingMore,
                    emptyLabel: _tabs[i].emptyLabel,
                    controller: _scrollControllers[i],
                  )
                else
                  _TaskList(
                    bucket: state.bucket(_tabs[i].filter),
                    emptyLabel: _tabs[i].emptyLabel,
                    controller: _scrollControllers[i],
                    // Only the visible tab may show a footer spinner.
                    isActive: state.activeFilter == _tabs[i].filter,
                  ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TaskFormPage()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Tarea'),
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  final TaskBucket bucket;
  final String emptyLabel;
  final ScrollController controller;
  final bool isActive;

  const _TaskList({
    required this.bucket,
    required this.emptyLabel,
    required this.controller,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final tasks = bucket.items;

    if (tasks.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => context.read<TaskCubit>().refresh(),
        // AlwaysScrollable keeps pull-to-refresh reachable on an empty list.
        child: ListView(
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: EmptyState(icon: Icons.checklist_rtl, title: emptyLabel),
            ),
          ],
        ),
      );
    }

    final showSpinner = isActive && bucket.isLoadingMore;

    return RefreshIndicator(
      onRefresh: () => context.read<TaskCubit>().refresh(),
      child: ListView.separated(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        // +1 for the count header, +1 for the footer spinner when fetching.
        itemCount: tasks.length + 1 + (showSpinner ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          if (i == 0) {
            return _CountHeader(loaded: tasks.length, total: bucket.total);
          }
          if (i > tasks.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          return _TaskRow(task: tasks[i - 1]);
        },
      ),
    );
  }
}

/// Swipe-to-edit/delete row shared by every tab that renders individual
/// tasks: the three status buckets ([_TaskList]) and the PDR-003 timeline
/// ([_TimelineList]/[_DaySection]) must offer the exact same actions on a
/// task regardless of which tab it is currently being viewed from.
class _TaskRow extends StatelessWidget {
  final Task task;

  const _TaskRow({required this.task});

  @override
  Widget build(BuildContext context) {
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
            onPressed: (_) => _confirmDeleteTask(context, task),
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
  }
}

Future<void> _confirmDeleteTask(BuildContext context, Task task) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Eliminar tarea'),
      content: Text('¿Seguro que quieres eliminar "${task.title}"?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
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

/// PDR-003: "Todas" as a day-grouped timeline instead of a flat list — "Sin
/// fecha" first (if any undated tasks exist), then one section per day with
/// tasks, oldest to newest, each capped at 3 rows plus a "Mostrar más"
/// reveal. Scrolling near the bottom extends the window (see
/// TasksPageState._onScroll); revealing a day's extra rows is purely local
/// state and never triggers a request.
class _TimelineList extends StatefulWidget {
  final Map<DateTime, List<Task>> days;
  final List<Task> undated;
  final bool loading;
  final bool loadingMore;
  final String emptyLabel;
  final ScrollController controller;

  const _TimelineList({
    required this.days,
    required this.undated,
    required this.loading,
    required this.loadingMore,
    required this.emptyLabel,
    required this.controller,
  });

  @override
  State<_TimelineList> createState() => _TimelineListState();
}

class _TimelineListState extends State<_TimelineList> {
  /// Days (and, via [_undatedExpanded], the "Sin fecha" section) whose full
  /// list is revealed instead of just the first 3 — local UI state, not
  /// cubit state, since revealing already-loaded rows fetches nothing.
  final Set<DateTime> _expandedDays = {};
  bool _undatedExpanded = false;

  Future<void> _reload() async {
    final householdId = context.read<TaskCubit>().householdId;
    if (householdId != null) {
      await context.read<TaskCubit>().loadTimeline(householdId);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading && widget.days.isEmpty && widget.undated.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final sortedDays = widget.days.keys.toList()..sort();
    final sections = <Widget>[
      if (widget.undated.isNotEmpty)
        _DaySection(
          title: 'Sin fecha',
          tasks: widget.undated,
          expanded: _undatedExpanded,
          onShowMore: () => setState(() => _undatedExpanded = true),
        ),
      for (final day in sortedDays)
        if (widget.days[day]!.isNotEmpty)
          _DaySection(
            title: formatDueDate(day),
            tasks: widget.days[day]!,
            expanded: _expandedDays.contains(day),
            onShowMore: () => setState(() => _expandedDays.add(day)),
          ),
    ];

    if (sections.isEmpty) {
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          controller: widget.controller,
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: EmptyState(
                icon: Icons.calendar_month_outlined,
                title: widget.emptyLabel,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        controller: widget.controller,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: sections.length + (widget.loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 20),
        itemBuilder: (context, i) {
          if (i >= sections.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return sections[i];
        },
      ),
    );
  }
}

/// One day's (or "Sin fecha"'s) section: header, up to 3 tasks, and a
/// "Mostrar más (N)" button revealing the rest once tapped.
class _DaySection extends StatelessWidget {
  static const _collapsedCount = 3;

  final String title;
  final List<Task> tasks;
  final bool expanded;
  final VoidCallback onShowMore;

  const _DaySection({
    required this.title,
    required this.tasks,
    required this.expanded,
    required this.onShowMore,
  });

  @override
  Widget build(BuildContext context) {
    final visible = expanded ? tasks : tasks.take(_collapsedCount).toList();
    final remaining = tasks.length - visible.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        for (final task in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _TaskRow(task: task),
          ),
        if (remaining > 0)
          TextButton(
            onPressed: onShowMore,
            child: Text('Mostrar más ($remaining)'),
          ),
      ],
    );
  }
}

/// "12 de 61" — without it a paginated list gives no way to tell "that's
/// everything" from "there is more below".
class _CountHeader extends StatelessWidget {
  final int loaded;
  final int? total;

  const _CountHeader({required this.loaded, required this.total});

  @override
  Widget build(BuildContext context) {
    // `total` only arrives with the first page; keep showing just the count
    // rather than a stale or missing denominator.
    final label = total == null ? '$loaded tareas' : '$loaded de $total';

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
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

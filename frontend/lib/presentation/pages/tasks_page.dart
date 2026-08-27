import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../config/theme.dart';
import '../../core/utils/ui_helpers.dart';
import '../../data/models/task.dart';
import '../cubit/task_cubit.dart';
import '../cubit/timeline_cubit.dart';
import '../widgets/common.dart';
import '../widgets/task_tile.dart';
import 'task_form_page.dart';
import 'trash_page.dart';

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
/// How close to the bottom the timeline starts fetching the next page, in
/// logical pixels. A distance rather than a fraction of the scroll extent: a
/// percentage means a different amount of remaining content depending on how
/// much is loaded, so a long timeline would prefetch far too late.
const double _kPrefetchThreshold = 600;

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
  /// "Todas" (PDR-003) is the keyset timeline of TD-064, not a status bucket,
  /// so it extends through [TimelineCubit.loadMore].
  ///
  /// The threshold there is `extentAfter` rather than a fraction of
  /// maxScrollExtent (docs/TD-064-DESIGN.md §4): a percentage means a
  /// different amount of remaining content depending on how long the list is,
  /// so a long timeline would prefetch far too late. A fixed distance from
  /// the bottom behaves the same however much is loaded.
  ///
  /// Only DATED pages are prefetched. Undated tasks are paginated by an
  /// explicit "Ver más" and never by scrolling — see [_UndatedSection].
  void _onScroll(int index, ScrollController controller) {
    if (index != _tabController.index) return;
    if (!controller.hasClients) return;

    final position = controller.position;
    if (_tabs[index].filter == TaskFilter.all) {
      if (position.extentAfter < _kPrefetchThreshold) {
        context.read<TimelineCubit>().loadMore();
      }
      return;
    }
    if (position.pixels > position.maxScrollExtent * 0.8) {
      context.read<TaskCubit>().loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tareas',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Papelera',
            onPressed: () => _openTrash(context),
          ),
        ],
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
                  // "Todas" is the PDR-003 timeline, owned by TimelineCubit
                  // since TD-064 — a separate BlocBuilder so a bucket-only
                  // TaskState change does not rebuild it, and vice versa.
                  _TimelineList(
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
        // See home_page.dart's FAB: distinct tags because the IndexedStack
        // keeps all three alive simultaneously.
        heroTag: 'tasks-fab',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TaskFormPage()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Tarea'),
      ),
    );
  }

  /// Opens the Papelera (TD-009). Kicks off the fetch before pushing the
  /// route rather than waiting for TrashPage to mount, so its BlocBuilder is
  /// already in the loading state on first frame instead of briefly showing
  /// the (still stale) empty state.
  void _openTrash(BuildContext context) {
    final cubit = context.read<TaskCubit>();
    final householdId = cubit.householdId;
    if (householdId != null) {
      cubit.loadTrashTasks(householdId);
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TrashPage()),
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
    // While a mutation on this row is in flight (TD-007/TD-060) the slide
    // actions are removed, not just the tile's taps: Editar/Eliminar live
    // outside TaskTile, so isPending alone would leave them reachable — and a
    // swipe on a row whose create has not confirmed would PATCH/DELETE against
    // its temporary `pending-` id, which the server has never seen. Removing
    // the pane makes the row simply not swipe: no dialog, no message, matching
    // the quiet cue the tile already uses.
    final isPending =
        context.watch<TaskCubit>().state.pendingIds.contains(task.id);

    return Slidable(
      key: ValueKey(task.id),
      endActionPane: isPending
          ? null
          : ActionPane(
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
        isPending: context.watch<TaskCubit>().state.pendingIds.contains(task.id),
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
/// The PDR-003 timeline, driven by TimelineCubit (TD-064).
class _TimelineList extends StatefulWidget {
  final String emptyLabel;
  final ScrollController controller;

  const _TimelineList({required this.emptyLabel, required this.controller});

  @override
  State<_TimelineList> createState() => _TimelineListState();
}

class _TimelineListState extends State<_TimelineList> {
  /// Days whose full list is revealed instead of just the first 3 — local UI
  /// state, not cubit state, since revealing already-loaded rows fetches
  /// nothing. Distinct from "Ver más", which fetches a page.
  final Set<DateTime> _expandedDays = {};
  bool _undatedExpanded = false;

  /// Pull-to-refresh. Deliberately [TimelineCubit.refresh] and not `load`:
  /// refresh keeps the current content on screen while it re-reads, so the
  /// list never flashes empty and a failed pull costs nothing.
  Future<void> _refresh() => context.read<TimelineCubit>().refresh();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TimelineCubit, TimelineState>(
      builder: (context, timeline) {
        if (timeline.isLoadingInitial && timeline.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (timeline.error != null && timeline.isEmpty) {
          return _ErrorRetry(
            message: timeline.error!,
            onRetry: _refresh,
          );
        }

        final groups = timeline.groups;
        final sortedDays = groups.days.keys.toList()..sort();
        final undated = timeline.undatedList;

        final sections = <Widget>[
          if (undated.isNotEmpty)
            _UndatedSection(
              tasks: undated,
              expanded: _undatedExpanded,
              onShowMore: () => setState(() => _undatedExpanded = true),
              // The product rule: the first page arrives with everything else,
              // further pages only on request. A drawer should not cost
              // anything to someone who never opens it.
              hasMorePages: timeline.undatedHasMore,
              loadingMorePages: timeline.isLoadingMoreUndated,
              onLoadMorePages: () => context.read<TimelineCubit>().loadMoreUndated(),
            ),
          for (final day in sortedDays)
            if (groups.days[day]!.isNotEmpty)
              _DaySection(
                title: formatDueDate(day),
                tasks: groups.days[day]!,
                expanded: _expandedDays.contains(day),
                onShowMore: () => setState(() => _expandedDays.add(day)),
              ),
        ];

        final banner = timeline.isStale ? const _StaleBanner() : null;

        if (sections.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              controller: widget.controller,
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (banner != null) banner,
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

        final leading = banner == null ? 0 : 1;
        final trailing = timeline.isLoadingMore ? 1 : 0;

        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView.separated(
            controller: widget.controller,
            // Always scrollable, even when the content fits: without this a
            // household with few tasks cannot overscroll, and pull-to-refresh
            // silently does nothing exactly where the list is quickest to
            // read. The empty branch above already had it; this one did not.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            itemCount: leading + sections.length + trailing,
            separatorBuilder: (_, __) => const SizedBox(height: 20),
            itemBuilder: (context, i) {
              if (banner != null && i == 0) return banner;
              final index = i - leading;
              if (index >= sections.length) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return sections[index];
            },
          ),
        );
      },
    );
  }
}

/// Shown when the timeline is being served from the local cache.
///
/// Says the content may be behind, and does NOT hide it: an empty screen is
/// worse than a slightly old one, and the pull-to-refresh above is the way
/// back. Not an error — being offline is a normal state for this app
/// (ADR-010).
class _StaleBanner extends StatelessWidget {
  const _StaleBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('timeline-stale-banner'),
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.textSecondary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 16, color: AppColors.textSecondary),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Sin conexión: mostrando lo último guardado',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Sin fecha", which paginates differently from the dated days on purpose.
///
/// Two affordances that look similar and are not: "Mostrar más (N)" reveals
/// rows already loaded, "Ver más" fetches the next page from the server. The
/// second only appears when the server said there is one.
class _UndatedSection extends StatelessWidget {
  final List<Task> tasks;
  final bool expanded;
  final VoidCallback onShowMore;
  final bool hasMorePages;
  final bool loadingMorePages;
  final VoidCallback onLoadMorePages;

  const _UndatedSection({
    required this.tasks,
    required this.expanded,
    required this.onShowMore,
    required this.hasMorePages,
    required this.loadingMorePages,
    required this.onLoadMorePages,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DaySection(
          title: 'Sin fecha',
          tasks: tasks,
          expanded: expanded,
          onShowMore: onShowMore,
        ),
        if (hasMorePages)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('undated-load-more'),
              onPressed: loadingMorePages ? null : onLoadMorePages,
              child: loadingMorePages
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Ver más'),
            ),
          ),
      ],
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

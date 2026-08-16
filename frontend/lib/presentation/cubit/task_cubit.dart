import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/errors/failures.dart';
import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';
import '../../services/connectivity_service.dart';
import '../../services/notification_service.dart';
import '../../services/sentry_service.dart';

/// Shown once (via BlocListener) after a mutation the repository could only
/// perform optimistically, offline (TD-003).
const kOfflineNoticeMessage =
    'Guardado offline, se sincronizará cuando haya conexión';

enum TaskStatusUi { initial, loading, loaded, error }

/// Which slice of the household's tasks a tab is showing.
///
/// Each value maps to a server-side query, not to a local `where`: filtering a
/// paginated list on the client shows only what happens to be loaded, which is
/// how "Completadas" used to look empty until the user had scrolled past every
/// pending task.
enum TaskFilter { all, pending, completed }

extension TaskFilterQuery on TaskFilter {
  /// The `?status=` value, or null for the unfiltered list.
  String? get statusParam {
    switch (this) {
      case TaskFilter.pending:
        return 'pending';
      case TaskFilter.completed:
        return 'completed';
      case TaskFilter.all:
        return null;
    }
  }

  /// Whether a task belongs in this slice — used to keep buckets consistent
  /// when a realtime event or a local mutation changes a task's status.
  bool matches(Task task) {
    switch (this) {
      case TaskFilter.all:
        return true;
      case TaskFilter.pending:
        return !task.isCompleted;
      case TaskFilter.completed:
        return task.isCompleted;
    }
  }
}

/// Independent pagination state for one filter.
///
/// Tabs must not share a cursor: advancing "Pendientes" would otherwise skip
/// rows in "Completadas", and one tab's spinner would appear in all three.
class TaskBucket extends Equatable {
  final List<Task> items;
  final String? nextCursor;
  final bool hasMore;
  final bool isLoadingMore;

  /// Server-side total for this filter, from its first page (later pages send
  /// null). Kept so the header can show "12 de 61", and nudged optimistically
  /// by local mutations so it does not go stale the instant the user acts.
  final int? total;

  /// Whether this bucket has ever completed a real fetch — including one that
  /// legitimately came back empty. Without this, "empty because never
  /// visited" and "empty because there is nothing completed" are
  /// indistinguishable, and setFilter cannot tell whether to refetch.
  final bool loaded;

  const TaskBucket({
    this.items = const [],
    this.nextCursor,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.total,
    this.loaded = false,
  });

  TaskBucket copyWith({
    List<Task>? items,
    String? nextCursor,
    bool? hasMore,
    bool? isLoadingMore,
    int? total,
    bool? loaded,
  }) {
    return TaskBucket(
      items: items ?? this.items,
      // Explicitly nullable: reaching the last page must be able to clear it.
      nextCursor: nextCursor,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      total: total ?? this.total,
      loaded: loaded ?? this.loaded,
    );
  }

  @override
  List<Object?> get props =>
      [items, nextCursor, hasMore, isLoadingMore, total, loaded];
}

class TaskState extends Equatable {
  final TaskStatusUi status;
  final String? error;

  /// The filter the visible tab is showing.
  final TaskFilter activeFilter;

  /// One independent pagination bucket per filter.
  final Map<TaskFilter, TaskBucket> buckets;

  /// True when the most recent [TaskCubit.load] could not reach the server
  /// and fell back to the Hive cache (TD-003). Persists across mutations —
  /// unlike [error], it is not cleared by every emit — until the next load
  /// either confirms connectivity or fails again offline.
  final bool isOffline;

  /// One-shot "saved offline" notice for a create/update/delete that could
  /// only be applied optimistically. Cleared like [error]: every emit resets
  /// it to null unless explicitly re-passed, so a BlocListener only sees it
  /// exactly once, then calls [TaskCubit.clearOfflineNotice].
  final String? offlineNotice;

  /// True while [TaskCubit.syncPending] is replaying the offline queue —
  /// drives the spinner in the offline banner (TD-003).
  final bool isSyncing;

  /// Day-grouped timeline for the "Todas" tab (PDR-003) — deliberately
  /// separate from [buckets]: [TaskFilter.all] stays the unfiltered,
  /// unbounded-by-date list Home/Calendar read via [allTasks], while the
  /// timeline is scoped to a rolling from/to window that would otherwise
  /// silently drop tasks outside it from those dashboards.
  ///
  /// Keyed by local midnight ([DateTime] with only year/month/day set) so a
  /// task's day is decided once, in [TaskCubit], rather than re-derived by
  /// every widget that reads it.
  final Map<DateTime, List<Task>> timelineDays;

  /// Tasks with no dueDate — always included in every from/to window response
  /// (see task.service.ts `dueDateWindowFilter`) since they have no day to be
  /// grouped under; the UI puts them in a "Sin fecha" section instead.
  final List<Task> timelineUndated;

  final String? timelineCursor;
  final bool timelineHasMore;

  /// Current window bounds, so [TaskCubit.loadMoreTimeline] knows what to
  /// extend. Null before the first [TaskCubit.loadTimeline] call.
  final DateTime? timelineWindowFrom;
  final DateTime? timelineWindowTo;

  final bool timelineLoading;
  final bool timelineLoadingMore;
  final String? timelineError;

  /// One row per recurring series for the Recurrentes tab (TD-035): the
  /// current occurrence (pending if one exists, otherwise the most
  /// recently due completed one), sorted by next due date. Populated by
  /// [TaskCubit.loadRecurringTasks] — deliberately NOT derived from
  /// [allTasks] or any [buckets] entry, both of which are only ever
  /// partially paginated; see that method's doc comment.
  final List<Task> recurringTasks;
  final bool recurringLoading;
  final bool recurringLoaded;
  final String? recurringError;

  /// Soft-deleted tasks for the Papelera/trash view (TD-009), most recently
  /// deleted first. Populated by [TaskCubit.loadTrashTasks] — same
  /// walk-the-full-list-then-filter-client-side approach as [recurringTasks]
  /// (TD-035), deliberately not derived from [buckets]/[allTasks], which the
  /// backend never returns deleted rows into in the first place.
  final List<Task> trashTasks;
  final bool trashLoading;
  final bool trashLoaded;
  final String? trashError;

  const TaskState({
    this.status = TaskStatusUi.initial,
    this.error,
    this.activeFilter = TaskFilter.all,
    this.buckets = const {},
    this.isOffline = false,
    this.offlineNotice,
    this.isSyncing = false,
    this.timelineDays = const {},
    this.timelineUndated = const [],
    this.timelineCursor,
    this.timelineHasMore = false,
    this.timelineWindowFrom,
    this.timelineWindowTo,
    this.timelineLoading = false,
    this.timelineLoadingMore = false,
    this.timelineError,
    this.recurringTasks = const [],
    this.recurringLoading = false,
    this.recurringLoaded = false,
    this.recurringError,
    this.trashTasks = const [],
    this.trashLoading = false,
    this.trashLoaded = false,
    this.trashError,
  });

  /// Pagination state for [filter], empty if it has never been loaded.
  TaskBucket bucket(TaskFilter filter) => buckets[filter] ?? const TaskBucket();

  /// The active tab's bucket — what the tasks page renders.
  TaskBucket get active => bucket(activeFilter);

  List<Task> get tasks => active.items;
  String? get nextCursor => active.nextCursor;
  bool get hasMore => active.hasMore;
  bool get isLoadingMore => active.isLoadingMore;
  int? get total => active.total;

  /// Every task loaded under the unfiltered slice.
  ///
  /// Dashboard-style consumers (home, calendar) must read this rather than
  /// [tasks]: otherwise switching the tasks tab to "Completadas" would empty
  /// their views too.
  List<Task> get allTasks => bucket(TaskFilter.all).items;

  TaskState copyWith({
    TaskStatusUi? status,
    String? error,
    TaskFilter? activeFilter,
    Map<TaskFilter, TaskBucket>? buckets,
    bool? isOffline,
    String? offlineNotice,
    bool? isSyncing,
    Map<DateTime, List<Task>>? timelineDays,
    List<Task>? timelineUndated,
    String? timelineCursor,
    bool? timelineHasMore,
    DateTime? timelineWindowFrom,
    DateTime? timelineWindowTo,
    bool? timelineLoading,
    bool? timelineLoadingMore,
    String? timelineError,
    List<Task>? recurringTasks,
    bool? recurringLoading,
    bool? recurringLoaded,
    String? recurringError,
    List<Task>? trashTasks,
    bool? trashLoading,
    bool? trashLoaded,
    String? trashError,
  }) {
    return TaskState(
      status: status ?? this.status,
      error: error,
      activeFilter: activeFilter ?? this.activeFilter,
      buckets: buckets ?? this.buckets,
      isOffline: isOffline ?? this.isOffline,
      offlineNotice: offlineNotice,
      isSyncing: isSyncing ?? this.isSyncing,
      timelineDays: timelineDays ?? this.timelineDays,
      timelineUndated: timelineUndated ?? this.timelineUndated,
      // Explicitly nullable, like TaskBucket.nextCursor: the window running
      // out of pages must be able to clear it.
      timelineCursor: timelineCursor,
      timelineHasMore: timelineHasMore ?? this.timelineHasMore,
      timelineWindowFrom: timelineWindowFrom ?? this.timelineWindowFrom,
      timelineWindowTo: timelineWindowTo ?? this.timelineWindowTo,
      timelineLoading: timelineLoading ?? this.timelineLoading,
      timelineLoadingMore: timelineLoadingMore ?? this.timelineLoadingMore,
      timelineError: timelineError,
      recurringTasks: recurringTasks ?? this.recurringTasks,
      recurringLoading: recurringLoading ?? this.recurringLoading,
      recurringLoaded: recurringLoaded ?? this.recurringLoaded,
      // Explicitly nullable, like timelineError/error: must clear on success.
      recurringError: recurringError,
      trashTasks: trashTasks ?? this.trashTasks,
      trashLoading: trashLoading ?? this.trashLoading,
      trashLoaded: trashLoaded ?? this.trashLoaded,
      // Explicitly nullable, like recurringError: must clear on success.
      trashError: trashError,
    );
  }

  @override
  List<Object?> get props => [
        status,
        error,
        activeFilter,
        buckets,
        isOffline,
        offlineNotice,
        isSyncing,
        timelineDays,
        timelineUndated,
        timelineCursor,
        timelineHasMore,
        timelineWindowFrom,
        timelineWindowTo,
        timelineLoading,
        timelineLoadingMore,
        timelineError,
        recurringTasks,
        recurringLoading,
        recurringLoaded,
        recurringError,
        trashTasks,
        trashLoading,
        trashLoaded,
        trashError,
      ];
}

/// Manages the task list for the active household, including realtime sync.
class TaskCubit extends Cubit<TaskState> {
  final TaskRepository _repo;
  final NotificationService _notifications;
  final ConnectivityService _connectivity;

  String? _householdId;
  StreamSubscription<bool>? _connectivitySub;

  /// Last connectivity value seen, so the subscription can detect a
  /// false→true edge rather than firing on every emission (the stream may
  /// repeat `true` without ever having gone offline).
  bool _wasOnline = true;

  TaskCubit(this._repo, this._notifications, {ConnectivityService? connectivity})
      : _connectivity = connectivity ?? ConnectivityService(),
        super(const TaskState()) {
    _connectivitySub = _connectivity.isOnline.listen((online) {
      if (online && !_wasOnline) {
        syncPending();
      }
      _wasOnline = online;
    });
  }

  @override
  Future<void> close() {
    _connectivitySub?.cancel();
    return super.close();
  }

  String? get householdId => _householdId;

  /// Replay the queued offline operations, then refresh from the server if
  /// anything was actually applied — called automatically on reconnection,
  /// and available for a manual "retry sync" action in the UI.
  Future<void> syncPending() async {
    emit(state.copyWith(isSyncing: true));
    try {
      final processed = await _repo.syncPendingOperations();
      if (processed > 0 && _householdId != null) {
        await load(_householdId!, filter: state.activeFilter);
      }
    } finally {
      emit(state.copyWith(isSyncing: false));
    }
  }

  /// Consume the one-shot [TaskState.offlineNotice] after the UI has shown
  /// it, without disturbing [TaskState.error].
  void clearOfflineNotice() {
    emit(state.copyWith(error: state.error));
  }

  Map<TaskFilter, TaskBucket> _withBucket(
      TaskFilter filter, TaskBucket bucket) {
    return {...state.buckets, filter: bucket};
  }

  /// Load the FIRST page of [filter], replacing that bucket and resetting its
  /// cursor. Other buckets are untouched.
  ///
  /// A null [filter] means the unfiltered list and sends no query param.
  Future<void> load(String householdId, {TaskFilter? filter}) async {
    _householdId = householdId;
    final target = filter ?? TaskFilter.all;

    emit(state.copyWith(
      status: TaskStatusUi.loading,
      activeFilter: target,
      error: null,
    ));

    try {
      final page = await _repo.list(householdId, status: target.statusParam);
      emit(state.copyWith(
        status: TaskStatusUi.loaded,
        isOffline: _repo.lastListWasFromCache,
        buckets: _withBucket(
          target,
          TaskBucket(
            items: _sorted(page.items),
            nextCursor: page.nextCursor,
            hasMore: page.hasMore,
            isLoadingMore: false,
            total: page.total,
            loaded: true,
          ),
        ),
      ));
    } on Failure catch (f) {
      emit(state.copyWith(status: TaskStatusUi.error, error: f.message));
    }
  }

  /// Switch tabs. Fetches only when [filter]'s bucket has never completed a
  /// real load — a tab that is already loaded, including one that is
  /// legitimately empty (e.g. no completed tasks yet), just becomes visible.
  Future<void> setFilter(TaskFilter? filter) async {
    final target = filter ?? TaskFilter.all;
    final alreadyLoaded = state.bucket(target).loaded;

    if (target == state.activeFilter) {
      if (alreadyLoaded) return;
    } else if (alreadyLoaded) {
      emit(state.copyWith(activeFilter: target));
      return;
    }

    if (_householdId == null) {
      emit(state.copyWith(activeFilter: target));
      return;
    }
    await load(_householdId!, filter: target);
  }

  Future<void> refresh() async {
    if (_householdId != null) {
      await load(_householdId!, filter: state.activeFilter);
    }
  }

  /// Append the next page of the ACTIVE filter. No-op when that bucket is
  /// exhausted or already fetching — the scroll listener fires on every pixel.
  Future<void> loadMore() async {
    if (_householdId == null) return;

    final filter = state.activeFilter;
    final current = state.bucket(filter);
    if (!current.hasMore ||
        current.isLoadingMore ||
        current.nextCursor == null) {
      return;
    }

    emit(state.copyWith(
      buckets: _withBucket(
        filter,
        current.copyWith(nextCursor: current.nextCursor, isLoadingMore: true),
      ),
    ));

    try {
      final page = await _repo.list(
        _householdId!,
        status: filter.statusParam,
        cursor: current.nextCursor,
      );
      emit(state.copyWith(
        status: TaskStatusUi.loaded,
        buckets: _withBucket(
          filter,
          current.copyWith(
            items: _sorted([...current.items, ...page.items]),
            nextCursor: page.nextCursor,
            hasMore: page.hasMore,
            isLoadingMore: false,
          ),
        ),
      ));
    } on Failure catch (f) {
      // Keep the pages already loaded; only surface the error.
      emit(state.copyWith(
        error: f.message,
        buckets: _withBucket(
          filter,
          current.copyWith(
              nextCursor: current.nextCursor, isLoadingMore: false),
        ),
      ));
    }
  }

  /// Fetch the initial timeline window for the "Todas" tab (PDR-003):
  /// yesterday through today+6, computed from the DEVICE's local calendar so
  /// day boundaries match what the user actually sees, independent of
  /// TD-013 (household timezone, not yet implemented).
  Future<void> loadTimeline(String householdId) async {
    _householdId = householdId;
    final now = DateTime.now();
    final from = _startOfLocalDay(now.subtract(const Duration(days: _timelineLookbackDays)));
    final to = _endOfLocalDay(now.add(const Duration(days: _timelineInitialForwardDays)));

    emit(state.copyWith(timelineLoading: true, timelineError: null));
    try {
      final result = await _repo.list(householdId, from: from, to: to);
      final grouped = _groupTasksByLocalDay(result.items);
      emit(state.copyWith(
        timelineLoading: false,
        timelineDays: grouped.days,
        timelineUndated: grouped.undated,
        timelineCursor: result.nextCursor,
        timelineHasMore: result.hasMore,
        timelineWindowFrom: from,
        timelineWindowTo: to,
      ));
    } on Failure catch (f) {
      emit(state.copyWith(timelineLoading: false, timelineError: f.message));
    }
  }

  /// Continue the timeline: first drains any further pages of the CURRENT
  /// window via [TaskState.timelineCursor] (a household with a busy week can
  /// exceed one page), then — once that window is exhausted — extends `to`
  /// forward by [_timelineExtendDays] and fetches page one of the wider
  /// window. Either way the response is merged into the existing buckets by
  /// task id rather than appended, so re-fetching an already-seen item when
  /// the window widens (a plain superset re-fetch, since `from` never moves)
  /// overwrites it in place instead of duplicating it.
  Future<void> loadMoreTimeline() async {
    if (_householdId == null || state.timelineLoadingMore) return;

    final from = state.timelineWindowFrom;
    var to = state.timelineWindowTo;
    if (from == null || to == null) return; // loadTimeline() never ran.

    final continuingWithinWindow = state.timelineHasMore && state.timelineCursor != null;
    final cursor = continuingWithinWindow ? state.timelineCursor : null;
    if (!continuingWithinWindow) {
      to = _endOfLocalDay(to.add(const Duration(days: _timelineExtendDays)));
    }

    emit(state.copyWith(timelineLoadingMore: true));
    try {
      final result = await _repo.list(_householdId!, from: from, to: to, cursor: cursor);
      final merged = _mergeTimelineItems(state.timelineDays, state.timelineUndated, result.items);
      emit(state.copyWith(
        timelineLoadingMore: false,
        timelineDays: merged.days,
        timelineUndated: merged.undated,
        timelineCursor: result.nextCursor,
        timelineHasMore: result.hasMore,
        timelineWindowTo: to,
      ));
    } on Failure catch (f) {
      emit(state.copyWith(timelineLoadingMore: false, timelineError: f.message));
    }
  }

  /// Ask the backend to generate any missed recurring occurrences, then reload
  /// if new tasks were created. Silent + non-critical: never surfaces errors.
  Future<void> catchUpRecurringTasks(String householdId) async {
    try {
      final data = await _repo.generateRecurringInstances(householdId);
      final generated = (data['generated'] as num?)?.toInt() ?? 0;
      if (generated > 0) {
        await load(householdId, filter: state.activeFilter);
      }
    } catch (_) {
      // Non-critical background task; ignore failures.
    }
  }

  /// Fetch every recurring task's current-occurrence representative for the
  /// Recurrentes tab (TD-035), sorted by next due date. Exhaustively drains
  /// the UNFILTERED task list (same status=null population [TaskFilter.all]'s
  /// bucket uses) rather than reading whatever page happens to already be
  /// cached — filtering a partially-loaded paginated list is exactly why this
  /// tab was removed the first time (see [TaskFilter]'s own doc comment).
  /// Deliberately does NOT use a status=pending/status=completed filtered
  /// fetch even though that would be cheaper: [TaskRepository.list] only
  /// caches a first page (`cursor == null`) as "this household's tasks" —
  /// caching a status-filtered first page here would silently evict the other
  /// statuses' entries from the offline cache (`CacheService.saveTasks`
  /// replaces, it does not merge). No new backend endpoint (TD-035's original
  /// proposal): the existing paginated list already has everything needed, it
  /// just has to be walked to completion instead of one page. An offline
  /// cache fallback returns everything in a single non-paginated page (see
  /// [TaskRepository.list]'s doc comment), so this loop still terminates in
  /// one iteration when there is no connectivity.
  Future<void> loadRecurringTasks(String householdId) async {
    _householdId = householdId;
    emit(state.copyWith(recurringLoading: true, recurringError: null));
    try {
      final all = <Task>[];
      String? cursor;
      while (true) {
        final page = await _repo.list(householdId, cursor: cursor);
        all.addAll(page.items);
        if (!page.hasMore || page.nextCursor == null) break;
        cursor = page.nextCursor;
      }
      emit(state.copyWith(
        recurringLoading: false,
        recurringLoaded: true,
        recurringTasks: _representativeRecurringTasks(all),
      ));
    } on Failure catch (f) {
      emit(state.copyWith(recurringLoading: false, recurringError: f.message));
    }
  }

  /// Fetch every soft-deleted task for the Papelera/trash view (TD-009),
  /// most recently deleted first. Exhaustively drains the `includeDeleted`
  /// list (same reasoning as [loadRecurringTasks]: filtering a partially
  /// loaded paginated list would randomly miss deleted rows depending on
  /// where they happen to sort by status/dueDate) rather than adding a
  /// dedicated backend endpoint — `?includeDeleted=true` already returns
  /// everything needed, just mixed with active tasks.
  Future<void> loadTrashTasks(String householdId) async {
    _householdId = householdId;
    emit(state.copyWith(trashLoading: true, trashError: null));
    try {
      final all = <Task>[];
      String? cursor;
      while (true) {
        final page = await _repo.list(householdId, cursor: cursor, includeDeleted: true);
        all.addAll(page.items);
        if (!page.hasMore || page.nextCursor == null) break;
        cursor = page.nextCursor;
      }
      final trashed = all.where((t) => t.isDeleted).toList()
        ..sort((a, b) {
          final ad = a.deletedAt;
          final bd = b.deletedAt;
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return bd.compareTo(ad); // most recently deleted first
        });
      emit(state.copyWith(trashLoading: false, trashLoaded: true, trashTasks: trashed));
    } on Failure catch (f) {
      emit(state.copyWith(trashLoading: false, trashError: f.message));
    }
  }

  /// Restore a soft-deleted task from the trash view. Drops it from
  /// [TaskState.trashTasks] and upserts the now-active task back into
  /// whichever buckets it belongs to (`_upsert` keys purely off status), so
  /// it reappears in the normal tabs immediately instead of waiting for a
  /// manual refresh.
  Future<void> restoreTask(String taskId) async {
    if (_householdId == null) return;
    try {
      final task = await _repo.restore(_householdId!, taskId);
      _upsert(task);
      emit(state.copyWith(
        trashTasks: state.trashTasks.where((t) => t.id != taskId).toList(),
      ));
    } on Failure catch (f) {
      emit(state.copyWith(trashError: f.message));
    }
  }

  /// "Vaciar papelera" (TD-048): hard-delete trash entries older than 30 days
  /// (the backend's default). Reloads [TaskState.trashTasks] from the server
  /// afterwards rather than guessing locally which rows were purged — the
  /// server is the only place that knows each row's exact age. Returns the
  /// purged count on success, or null on failure (with [TaskState.trashError]
  /// set — e.g. a non-admin caller sees the backend's 403).
  Future<int?> purgeTrash() async {
    if (_householdId == null) return null;
    try {
      final deleted = await _repo.purgeTrash(_householdId!);
      await loadTrashTasks(_householdId!);
      return deleted;
    } on Failure catch (f) {
      emit(state.copyWith(trashError: f.message));
      return null;
    }
  }

  Future<Task?> createTask(Map<String, dynamic> payload) async {
    if (_householdId == null) return null;
    try {
      final task = await _repo.create(_householdId!, payload);
      _upsert(task, offlineNotice: task.isSynced ? null : kOfflineNoticeMessage);
      // Phase 3.3: schedule a local reminder if the task has a due date.
      await _notifications.scheduleTaskReminder(task);
      // PDR-004: independent "starts in 30 min" reminder if the task has a
      // startsAt — no-op otherwise, and never set on a recurring task (the
      // backend already strips startsAt/endsAt from one).
      await _notifications.scheduleTaskStartReminder(task);
      return task;
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
      return null;
    }
  }

  Future<void> updateTask(String taskId, Map<String, dynamic> payload) async {
    if (_householdId == null) return;
    try {
      final task = await _repo.update(_householdId!, taskId, payload);
      _upsert(task, offlineNotice: task.isSynced ? null : kOfflineNoticeMessage);
      await _notifications.scheduleTaskReminder(task);
      await _notifications.scheduleTaskStartReminder(task);
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    }
  }

  Future<void> completeTask(String taskId) async {
    if (_householdId == null) return;
    try {
      final task = await _repo.complete(_householdId!, taskId);
      SentryService.addBreadcrumb(
        'Task completed',
        category: 'task',
        data: {'householdId': _householdId, 'synced': task.isSynced},
      );
      _upsert(task, offlineNotice: task.isSynced ? null : kOfflineNoticeMessage);
      await _notifications.cancelTaskReminder(taskId);
      await _notifications.cancelTaskStartReminder(taskId);
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    }
  }

  /// Online, the repository deletes for real and returns null — remove the
  /// row. Offline, it returns the task marked `isDeleted: true` — keep it
  /// upserted (struck through by the tile) rather than removing it, so the
  /// user can see the delete is queued, not lost.
  Future<void> deleteTask(String taskId) async {
    if (_householdId == null) return;
    try {
      final marked = await _repo.delete(_householdId!, taskId);
      if (marked != null) {
        _upsert(marked, offlineNotice: kOfflineNoticeMessage);
      } else {
        _remove(taskId);
      }
      await _notifications.cancelTaskReminder(taskId);
      await _notifications.cancelTaskStartReminder(taskId);
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    }
  }

  /// Apply an incoming realtime socket event to local state.
  void applyRealtime(String event, dynamic data) {
    if (data is! Map) return;
    final map = Map<String, dynamic>.from(data);

    // Only react to events for the household currently loaded.
    if (_householdId != null &&
        map['householdId'] != null &&
        map['householdId'].toString() != _householdId) {
      return;
    }

    if (event == 'task:deleted') {
      _remove(map['id'].toString());
    } else {
      _upsert(Task.fromJson(map));
    }
  }

  /// Place [task] in every bucket whose filter it matches and drop it from the
  /// rest, so completing a task moves it from "Pendientes" to "Completadas"
  /// without a refetch. Each affected bucket's total is nudged by exactly the
  /// same net change — created moves 0→1 (+1 wherever it now belongs),
  /// completed moves pending→completed (−1/+1, "all" stays put since the task
  /// never left it), a plain edit that changes nothing about membership
  /// leaves every total untouched. The same math applies whether the call
  /// came from a local mutation or a realtime event from another device, so
  /// header counts stay correct either way.
  void _upsert(Task task, {String? offlineNotice}) {
    final updated = <TaskFilter, TaskBucket>{};

    for (final filter in TaskFilter.values) {
      final bucket = state.bucket(filter);
      final items = List<Task>.from(bucket.items);
      final index = items.indexWhere((t) => t.id == task.id);
      final belongs = filter.matches(task);
      final existed = index >= 0;

      if (belongs) {
        if (existed) {
          items[index] = task;
        } else {
          items.add(task);
        }
      } else if (existed) {
        items.removeAt(index);
      } else {
        // Nothing to do for this bucket; keep it as-is to avoid needless rebuilds.
        updated[filter] = bucket;
        continue;
      }

      updated[filter] = bucket.copyWith(
        items: _sorted(items),
        nextCursor: bucket.nextCursor,
        total: _adjustedTotal(bucket,
            delta: belongs && !existed ? 1 : (!belongs && existed ? -1 : 0)),
      );
    }

    final timeline = _timelineAfterUpsert(task);
    emit(state.copyWith(
      status: TaskStatusUi.loaded,
      buckets: updated,
      offlineNotice: offlineNotice,
      timelineDays: timeline?.days,
      timelineUndated: timeline?.undated,
    ));
  }

  void _remove(String id) {
    final updated = <TaskFilter, TaskBucket>{};
    for (final filter in TaskFilter.values) {
      final bucket = state.bucket(filter);
      final existed = bucket.items.any((t) => t.id == id);
      updated[filter] = bucket.copyWith(
        items: bucket.items.where((t) => t.id != id).toList(),
        nextCursor: bucket.nextCursor,
        total: _adjustedTotal(bucket, delta: existed ? -1 : 0),
      );
    }

    final timeline = _timelineAfterRemove(id);
    emit(state.copyWith(
      buckets: updated,
      timelineDays: timeline?.days,
      timelineUndated: timeline?.undated,
    ));
  }

  /// Keep [TaskState.timelineDays]/[TaskState.timelineUndated] consistent with
  /// [task], the same way the loop above keeps [TaskState.buckets] consistent
  /// — the PDR-003 "Todas" tab renders the timeline directly (see
  /// tasks_page.dart's `_TimelineList`), not `buckets[TaskFilter.all]`, so a
  /// local mutation or realtime event that only patched buckets left an
  /// equally real staleness bug there: a created task invisible until
  /// pull-to-refresh, a deleted one stuck on screen, a rescheduled one stuck
  /// on its old day.
  ///
  /// Mirrors what a fresh [loadTimeline] response would contain: [task] lands
  /// in its due date's day (moved if the date changed since the last upsert),
  /// in "Sin fecha" if it has none (the backend always includes undated tasks
  /// regardless of window), or is dropped if its date now falls outside
  /// [TaskState.timelineWindowFrom]..[TaskState.timelineWindowTo] — e.g. a
  /// task just rescheduled past the loaded window. Returns null (no-op) until
  /// the first [loadTimeline] call establishes those window bounds.
  _TimelineGroups? _timelineAfterUpsert(Task task) {
    final from = state.timelineWindowFrom;
    final to = state.timelineWindowTo;
    if (from == null || to == null) return null;

    final byId = <String, Task>{
      for (final t in state.timelineDays.values.expand((l) => l)) t.id: t,
      for (final t in state.timelineUndated) t.id: t,
    };

    final due = task.dueDate?.toLocal();
    final withinWindow = due == null || (!due.isBefore(from) && !due.isAfter(to));
    if (withinWindow) {
      byId[task.id] = task;
    } else {
      byId.remove(task.id);
    }
    return _groupTasksByLocalDay(byId.values.toList());
  }

  /// Companion to [_timelineAfterUpsert] for a hard delete/removal by [id].
  /// Same null-means-no-op rule before the first [loadTimeline] call.
  _TimelineGroups? _timelineAfterRemove(String id) {
    if (state.timelineWindowFrom == null || state.timelineWindowTo == null) {
      return null;
    }

    final byId = <String, Task>{
      for (final t in state.timelineDays.values.expand((l) => l)) t.id: t,
      for (final t in state.timelineUndated) t.id: t,
    };
    if (byId.remove(id) == null) return null; // wasn't in the timeline anyway.
    return _groupTasksByLocalDay(byId.values.toList());
  }

  /// [bucket.total] shifted by [delta], but only once the bucket has actually
  /// been fetched: a total of null means "unknown", and unknown ± 1 is still
  /// unknown, not 1. That bucket gets an accurate total the moment it is
  /// visited for real.
  int? _adjustedTotal(TaskBucket bucket, {required int delta}) {
    if (!bucket.loaded || bucket.total == null || delta == 0) {
      return bucket.total;
    }
    return bucket.total! + delta;
  }

  /// Pending first, then by due date ascending (nulls last).
  List<Task> _sorted(List<Task> tasks) => _sortTasksForDisplay(tasks);
}

/// Timeline window (PDR-003): starts at "yesterday" so a task due yesterday
/// but not yet done is never hidden the moment the clock ticks past
/// midnight, and initially reaches 6 days into the future (an 8-day window
/// total: yesterday, today, +1..+6).
const _timelineLookbackDays = 1;
const _timelineInitialForwardDays = 6;

/// Extra days appended to the window each time [TaskCubit.loadMoreTimeline]
/// runs out of pages within the current one.
const _timelineExtendDays = 7;

DateTime _startOfLocalDay(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _endOfLocalDay(DateTime d) =>
    DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

/// Grouped items for the timeline: dated tasks keyed by local midnight, plus
/// the undated ones the backend always includes alongside a from/to window.
class _TimelineGroups {
  final Map<DateTime, List<Task>> days;
  final List<Task> undated;
  const _TimelineGroups(this.days, this.undated);
}

_TimelineGroups _groupTasksByLocalDay(List<Task> tasks) {
  final days = <DateTime, List<Task>>{};
  final undated = <Task>[];
  for (final task in tasks) {
    final due = task.dueDate;
    if (due == null) {
      undated.add(task);
      continue;
    }
    final key = _startOfLocalDay(due.toLocal());
    (days[key] ??= []).add(task);
  }
  for (final key in days.keys) {
    days[key] = _sortTasksForDisplay(days[key]!);
  }
  return _TimelineGroups(days, undated);
}

/// Pending first, then by due date ascending — same ordering rule as
/// TaskCubit._sorted, kept as a top-level function since the merge helper
/// below needs it too and does not have a TaskCubit instance to call it on.
List<Task> _sortTasksForDisplay(List<Task> tasks) {
  final copy = List<Task>.from(tasks);
  copy.sort((a, b) {
    if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
    final ad = a.dueDate;
    final bd = b.dueDate;
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return ad.compareTo(bd);
  });
  return copy;
}

/// Merge a newly-fetched page into the existing timeline buckets, keyed by
/// task id so a widened window's superset re-fetch overwrites rather than
/// duplicates already-bucketed items.
_TimelineGroups _mergeTimelineItems(
  Map<DateTime, List<Task>> existingDays,
  List<Task> existingUndated,
  List<Task> newItems,
) {
  final byId = <String, Task>{
    for (final t in existingDays.values.expand((l) => l)) t.id: t,
    for (final t in existingUndated) t.id: t,
  };
  for (final t in newItems) {
    byId[t.id] = t;
  }
  return _groupTasksByLocalDay(byId.values.toList());
}

/// One row per recurring series (grouped by parentTaskId, or the task's own
/// id for a series' very first occurrence): the PENDING occurrence if one
/// exists (the "current" one — completing a recurring task immediately
/// regenerates the next pending instance, task.service.ts's
/// generateNextInstance, so this is the normal case), otherwise the most
/// recently due completed one, so a series briefly caught between completion
/// and catch-up still shows something instead of vanishing. Every generated
/// occurrence inherits isRecurring: true (not just the series template), so
/// grouping by series is required — a raw `isRecurring == true` filter would
/// list one row per historical occurrence instead of one per series.
List<Task> _representativeRecurringTasks(List<Task> tasks) {
  final bySeries = <String, Task>{};
  for (final task in tasks) {
    if (!task.isRecurring) continue;
    final seriesId = task.parentTaskId ?? task.id;
    final existing = bySeries[seriesId];
    if (existing == null || _isBetterRecurringRepresentative(task, existing)) {
      bySeries[seriesId] = task;
    }
  }
  return _sortByNextOccurrence(bySeries.values.toList());
}

bool _isBetterRecurringRepresentative(Task candidate, Task current) {
  if (candidate.isCompleted != current.isCompleted) {
    return !candidate.isCompleted; // prefer pending over completed
  }
  final cd = candidate.dueDate;
  final xd = current.dueDate;
  if (cd == null) return false;
  if (xd == null) return true;
  return cd.isAfter(xd); // among same-status candidates, the latest one
}

List<Task> _sortByNextOccurrence(List<Task> tasks) {
  final copy = List<Task>.from(tasks);
  copy.sort((a, b) {
    final ad = a.dueDate;
    final bd = b.dueDate;
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return ad.compareTo(bd);
  });
  return copy;
}

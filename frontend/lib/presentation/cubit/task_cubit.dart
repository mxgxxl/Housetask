import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/errors/failures.dart';
import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';
import '../../services/notification_service.dart';

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

  const TaskState({
    this.status = TaskStatusUi.initial,
    this.error,
    this.activeFilter = TaskFilter.all,
    this.buckets = const {},
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
  }) {
    return TaskState(
      status: status ?? this.status,
      error: error,
      activeFilter: activeFilter ?? this.activeFilter,
      buckets: buckets ?? this.buckets,
    );
  }

  @override
  List<Object?> get props => [status, error, activeFilter, buckets];
}

/// Manages the task list for the active household, including realtime sync.
class TaskCubit extends Cubit<TaskState> {
  final TaskRepository _repo;
  final NotificationService _notifications;

  String? _householdId;

  TaskCubit(this._repo, this._notifications) : super(const TaskState());

  String? get householdId => _householdId;

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

  Future<Task?> createTask(Map<String, dynamic> payload) async {
    if (_householdId == null) return null;
    try {
      final task = await _repo.create(_householdId!, payload);
      _upsert(task);
      // Phase 3.3: schedule a local reminder if the task has a due date.
      await _notifications.scheduleTaskReminder(task);
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
      _upsert(task);
      await _notifications.scheduleTaskReminder(task);
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    }
  }

  Future<void> completeTask(String taskId) async {
    if (_householdId == null) return;
    try {
      final task = await _repo.complete(_householdId!, taskId);
      _upsert(task);
      await _notifications.cancelTaskReminder(taskId);
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    }
  }

  Future<void> deleteTask(String taskId) async {
    if (_householdId == null) return;
    try {
      await _repo.delete(_householdId!, taskId);
      _remove(taskId);
      await _notifications.cancelTaskReminder(taskId);
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
  void _upsert(Task task) {
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

    emit(state.copyWith(status: TaskStatusUi.loaded, buckets: updated));
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
    emit(state.copyWith(buckets: updated));
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
  List<Task> _sorted(List<Task> tasks) {
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
}

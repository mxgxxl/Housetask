import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/errors/failures.dart';
import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';
import '../../services/notification_service.dart';

enum TaskStatusUi { initial, loading, loaded, error }

class TaskState extends Equatable {
  final TaskStatusUi status;
  final List<Task> tasks;
  final String? error;

  /// Cursor for the next page, or null when the list is fully loaded.
  final String? nextCursor;

  /// Whether the server reported more rows after the last page.
  final bool hasMore;

  /// A page fetch is in flight; guards against the scroll listener firing
  /// repeatedly while one request is already running.
  final bool isLoadingMore;

  /// Server-side total, captured from the first page (later pages send null).
  final int? total;

  const TaskState({
    this.status = TaskStatusUi.initial,
    this.tasks = const [],
    this.error,
    this.nextCursor,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.total,
  });

  List<Task> get pending => tasks.where((t) => !t.isCompleted).toList();
  List<Task> get completed => tasks.where((t) => t.isCompleted).toList();
  List<Task> get recurring => tasks.where((t) => t.isRecurring).toList();

  TaskState copyWith({
    TaskStatusUi? status,
    List<Task>? tasks,
    String? error,
    String? nextCursor,
    bool? hasMore,
    bool? isLoadingMore,
    int? total,
  }) {
    return TaskState(
      status: status ?? this.status,
      tasks: tasks ?? this.tasks,
      error: error,
      // Explicitly nullable: reaching the last page must be able to clear it.
      nextCursor: nextCursor,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      total: total ?? this.total,
    );
  }

  @override
  List<Object?> get props =>
      [status, tasks, error, nextCursor, hasMore, isLoadingMore, total];
}

/// Manages the task list for the active household, including realtime sync.
class TaskCubit extends Cubit<TaskState> {
  final TaskRepository _repo;
  final NotificationService _notifications;

  String? _householdId;

  TaskCubit(this._repo, this._notifications) : super(const TaskState());

  String? get householdId => _householdId;

  /// Load the FIRST page, replacing whatever was loaded before and resetting
  /// the cursor. Used by initial load and pull-to-refresh.
  Future<void> load(String householdId) async {
    _householdId = householdId;
    emit(state.copyWith(status: TaskStatusUi.loading, error: null));
    try {
      final page = await _repo.list(householdId);
      emit(state.copyWith(
        status: TaskStatusUi.loaded,
        tasks: _sorted(page.items),
        nextCursor: page.nextCursor,
        hasMore: page.hasMore,
        isLoadingMore: false,
        total: page.total,
      ));
    } on Failure catch (f) {
      emit(state.copyWith(status: TaskStatusUi.error, error: f.message));
    }
  }

  /// Append the next page. No-op when the list is exhausted or a fetch is
  /// already running — the scroll listener fires on every pixel of movement.
  Future<void> loadMore() async {
    if (_householdId == null) return;
    if (!state.hasMore || state.isLoadingMore || state.nextCursor == null) return;

    emit(state.copyWith(nextCursor: state.nextCursor, isLoadingMore: true, error: null));
    try {
      final page = await _repo.list(_householdId!, cursor: state.nextCursor);
      emit(state.copyWith(
        status: TaskStatusUi.loaded,
        tasks: _sorted([...state.tasks, ...page.items]),
        nextCursor: page.nextCursor,
        hasMore: page.hasMore,
        isLoadingMore: false,
      ));
    } on Failure catch (f) {
      // Keep the pages already loaded; only surface the error.
      emit(state.copyWith(
        nextCursor: state.nextCursor,
        isLoadingMore: false,
        error: f.message,
      ));
    }
  }

  Future<void> refresh() async {
    if (_householdId != null) await load(_householdId!);
  }

  /// Ask the backend to generate any missed recurring occurrences, then reload
  /// if new tasks were created. Silent + non-critical: never surfaces errors.
  Future<void> catchUpRecurringTasks(String householdId) async {
    try {
      final data = await _repo.generateRecurringInstances(householdId);
      final generated = (data['generated'] as num?)?.toInt() ?? 0;
      if (generated > 0) {
        await load(householdId);
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

  void _upsert(Task task) {
    final list = List<Task>.from(state.tasks);
    final idx = list.indexWhere((t) => t.id == task.id);
    if (idx >= 0) {
      list[idx] = task;
    } else {
      list.add(task);
    }
    emit(state.copyWith(
      status: TaskStatusUi.loaded,
      tasks: _sorted(list),
      nextCursor: state.nextCursor,
    ));
  }

  void _remove(String id) {
    final list = state.tasks.where((t) => t.id != id).toList();
    emit(state.copyWith(tasks: list, nextCursor: state.nextCursor));
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

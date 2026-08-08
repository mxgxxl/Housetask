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

  const TaskState({
    this.status = TaskStatusUi.initial,
    this.tasks = const [],
    this.error,
  });

  List<Task> get pending => tasks.where((t) => !t.isCompleted).toList();
  List<Task> get completed => tasks.where((t) => t.isCompleted).toList();
  List<Task> get recurring => tasks.where((t) => t.isRecurring).toList();

  TaskState copyWith({TaskStatusUi? status, List<Task>? tasks, String? error}) {
    return TaskState(
      status: status ?? this.status,
      tasks: tasks ?? this.tasks,
      error: error,
    );
  }

  @override
  List<Object?> get props => [status, tasks, error];
}

/// Manages the task list for the active household, including realtime sync.
class TaskCubit extends Cubit<TaskState> {
  final TaskRepository _repo;
  final NotificationService _notifications;

  String? _householdId;

  TaskCubit(this._repo, this._notifications) : super(const TaskState());

  String? get householdId => _householdId;

  Future<void> load(String householdId) async {
    _householdId = householdId;
    emit(state.copyWith(status: TaskStatusUi.loading, error: null));
    try {
      final tasks = await _repo.list(householdId);
      emit(state.copyWith(status: TaskStatusUi.loaded, tasks: _sorted(tasks)));
    } on Failure catch (f) {
      emit(state.copyWith(status: TaskStatusUi.error, error: f.message));
    }
  }

  Future<void> refresh() async {
    if (_householdId != null) await load(_householdId!);
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
    emit(state.copyWith(status: TaskStatusUi.loaded, tasks: _sorted(list)));
  }

  void _remove(String id) {
    final list = state.tasks.where((t) => t.id != id).toList();
    emit(state.copyWith(tasks: list));
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

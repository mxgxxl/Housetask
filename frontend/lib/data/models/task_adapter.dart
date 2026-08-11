import 'package:hive/hive.dart';
import 'task.dart';

/// Full, round-trippable serialization of a [Task] for the Hive cache.
///
/// [Task.toJson] is deliberately payload-shaped (mutable fields only, ids
/// instead of full user refs) for create/update requests. Caching needs
/// everything back — populated assignee/creator objects, completion
/// metadata — so this is its own map, not a reuse of toJson().
Map<String, dynamic> taskToCacheMap(Task task) {
  return {
    'id': task.id,
    'householdId': task.householdId,
    'title': task.title,
    'description': task.description,
    'assignedTo': task.assignedTo.map((u) => u.toJson()).toList(),
    'createdBy': task.createdBy?.toJson(),
    'status': task.status,
    'priority': task.priority,
    'category': task.category,
    'dueDate': task.dueDate?.toIso8601String(),
    'completedAt': task.completedAt?.toIso8601String(),
    'completedBy': task.completedBy?.toJson(),
    'isRecurring': task.isRecurring,
    'recurrenceRule': task.recurrenceRule?.toJson(),
    'parentTaskId': task.parentTaskId,
  };
}

/// [Task.fromJson] already tolerates populated refs (via [User.fromRef]), so
/// it round-trips [taskToCacheMap]'s output without any extra logic.
Task taskFromCacheMap(Map<dynamic, dynamic> map) =>
    Task.fromJson(Map<String, dynamic>.from(map));

/// Hand-written rather than generated via hive_generator/build_runner: the
/// classic hive_generator package is abandoned at `analyzer <7.0.0`, which
/// conflicts with the `analyzer >=8.0.0` this project's test toolchain
/// (bloc_test → test 1.31) already requires. TypeAdapter is a small, stable,
/// fully public Hive interface — hand-writing it skips a broken
/// dev-dependency without any behavioural difference from generated code.
class TaskAdapter extends TypeAdapter<Task> {
  @override
  final int typeId = 0;

  @override
  Task read(BinaryReader reader) => taskFromCacheMap(reader.readMap());

  @override
  void write(BinaryWriter writer, Task obj) => writer.writeMap(taskToCacheMap(obj));
}

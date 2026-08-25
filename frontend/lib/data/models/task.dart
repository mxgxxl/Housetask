import 'package:equatable/equatable.dart';
import 'user.dart';
import 'recurrence_rule.dart';

/// A household task.
class Task extends Equatable {
  final String id;
  final String householdId;
  final String title;
  final String? description;
  final List<User> assignedTo;
  final User? createdBy;
  final String status; // 'pending' | 'completed'
  final String priority; // 'low' | 'medium' | 'high'
  final String category; // cleaning | cooking | shopping | maintenance | other
  final DateTime? dueDate;

  /// Optional duration (PDR-004): both null = an instantaneous task
  /// (retrocompatible default). A recurring task never carries these — the
  /// backend ignores/clears them (duration + recurrence is out of scope this
  /// round), so the form hides the pickers whenever recurrence is on.
  final DateTime? startsAt;
  final DateTime? endsAt;

  final DateTime? completedAt;
  final User? completedBy;
  final bool isRecurring;
  final RecurrenceRule? recurrenceRule;
  final String? parentTaskId;

  /// Local-only: false while a create/update/delete made offline is still
  /// waiting in the pending-operations queue. Never sent to the server —
  /// see [toJson] — and irrelevant once the write has synced.
  final bool isSynced;

  /// True when this task is deleted — either the server's own soft-delete
  /// state (TD-009: the backend marks a task deleted instead of removing it,
  /// and the default task list excludes it, so this only ever comes back
  /// `true` from an explicit `includeDeleted=true` fetch, e.g. the trash
  /// view), or a local-only marker set while a delete made offline is still
  /// waiting in the pending-operations queue. Either way the row renders
  /// struck through — see [TaskTile] — until it is genuinely gone from the
  /// user's normal lists.
  final bool isDeleted;

  /// When the task was soft-deleted (TD-009), from the server. Null for an
  /// offline-only pending delete (the server hasn't recorded it yet) or a
  /// task that was never deleted.
  final DateTime? deletedAt;

  const Task({
    required this.id,
    required this.householdId,
    required this.title,
    this.description,
    this.assignedTo = const [],
    this.createdBy,
    this.status = 'pending',
    this.priority = 'medium',
    this.category = 'other',
    this.dueDate,
    this.startsAt,
    this.endsAt,
    this.completedAt,
    this.completedBy,
    this.isRecurring = false,
    this.recurrenceRule,
    this.parentTaskId,
    this.isSynced = true,
    this.isDeleted = false,
    this.deletedAt,
  });

  bool get isCompleted => status == 'completed';

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      householdId: (json['householdId'] ?? '').toString(),
      title: (json['title'] ?? '') as String,
      description: json['description'] as String?,
      assignedTo: (json['assignedTo'] as List<dynamic>?)
              ?.map(User.fromRef)
              .toList() ??
          const [],
      createdBy: json['createdBy'] != null ? User.fromRef(json['createdBy']) : null,
      status: (json['status'] ?? 'pending') as String,
      priority: (json['priority'] ?? 'medium') as String,
      category: (json['category'] ?? 'other') as String,
      dueDate:
          json['dueDate'] != null ? DateTime.tryParse(json['dueDate'].toString()) : null,
      startsAt:
          json['startsAt'] != null ? DateTime.tryParse(json['startsAt'].toString()) : null,
      endsAt: json['endsAt'] != null ? DateTime.tryParse(json['endsAt'].toString()) : null,
      completedAt: json['completedAt'] != null
          ? DateTime.tryParse(json['completedAt'].toString())
          : null,
      completedBy:
          json['completedBy'] != null ? User.fromRef(json['completedBy']) : null,
      isRecurring: (json['isRecurring'] ?? false) as bool,
      recurrenceRule: json['recurrenceRule'] != null
          // `Map.from`, not a cast. This map arrives from two places: an HTTP
          // response, where it really is a Map<String, dynamic>, and the Hive
          // cache, where NESTED maps come back as _Map<dynamic, dynamic> — the
          // adapter's `Map<String, dynamic>.from` only retypes the top level.
          // The hard cast that used to be here meant one cached recurring task
          // made `Hive.openBox<Task>` throw, which killed CacheService.init()
          // before runApp and left the app on a blank screen. Permanently: the
          // row stays on disk, so every relaunch failed the same way.
          ? RecurrenceRule.fromJson(
              Map<String, dynamic>.from(json['recurrenceRule'] as Map))
          : null,
      parentTaskId: json['parentTaskId']?.toString(),
      isSynced: (json['isSynced'] ?? true) as bool,
      isDeleted: (json['isDeleted'] ?? false) as bool,
      deletedAt:
          json['deletedAt'] != null ? DateTime.tryParse(json['deletedAt'].toString()) : null,
    );
  }

  /// Payload for create/update requests (only mutable fields). Deliberately
  /// excludes [isSynced]/[isDeleted]: they are local sync-queue bookkeeping,
  /// never something the server has an opinion on.
  Map<String, dynamic> toJson() => {
        'title': title,
        'description': description,
        'assignedTo': assignedTo.map((u) => u.id).toList(),
        'status': status,
        'priority': priority,
        'category': category,
        'dueDate': dueDate?.toIso8601String(),
        'startsAt': startsAt?.toIso8601String(),
        'endsAt': endsAt?.toIso8601String(),
        'isRecurring': isRecurring,
        if (recurrenceRule != null) 'recurrenceRule': recurrenceRule!.toJson(),
        'parentTaskId': parentTaskId,
      };

  Task copyWith({
    String? title,
    String? description,
    List<User>? assignedTo,
    String? status,
    String? priority,
    String? category,
    DateTime? dueDate,
    DateTime? startsAt,
    DateTime? endsAt,
    bool? isRecurring,
    RecurrenceRule? recurrenceRule,
    bool? isSynced,
    bool? isDeleted,
    DateTime? deletedAt,
  }) {
    return Task(
      id: id,
      householdId: householdId,
      title: title ?? this.title,
      description: description ?? this.description,
      assignedTo: assignedTo ?? this.assignedTo,
      createdBy: createdBy,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      category: category ?? this.category,
      dueDate: dueDate ?? this.dueDate,
      startsAt: startsAt ?? this.startsAt,
      endsAt: endsAt ?? this.endsAt,
      completedAt: completedAt,
      completedBy: completedBy,
      isRecurring: isRecurring ?? this.isRecurring,
      recurrenceRule: recurrenceRule ?? this.recurrenceRule,
      parentTaskId: parentTaskId,
      isSynced: isSynced ?? this.isSynced,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  @override
  List<Object?> get props => [
        id,
        householdId,
        title,
        description,
        assignedTo,
        status,
        priority,
        category,
        dueDate,
        startsAt,
        endsAt,
        completedAt,
        isRecurring,
        parentTaskId,
        isSynced,
        isDeleted,
        deletedAt,
      ];
}

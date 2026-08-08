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
  final DateTime? completedAt;
  final User? completedBy;
  final bool isRecurring;
  final RecurrenceRule? recurrenceRule;

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
    this.completedAt,
    this.completedBy,
    this.isRecurring = false,
    this.recurrenceRule,
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
      completedAt: json['completedAt'] != null
          ? DateTime.tryParse(json['completedAt'].toString())
          : null,
      completedBy:
          json['completedBy'] != null ? User.fromRef(json['completedBy']) : null,
      isRecurring: (json['isRecurring'] ?? false) as bool,
      recurrenceRule: json['recurrenceRule'] != null
          ? RecurrenceRule.fromJson(json['recurrenceRule'] as Map<String, dynamic>)
          : null,
    );
  }

  /// Payload for create/update requests (only mutable fields).
  Map<String, dynamic> toJson() => {
        'title': title,
        'description': description,
        'assignedTo': assignedTo.map((u) => u.id).toList(),
        'status': status,
        'priority': priority,
        'category': category,
        'dueDate': dueDate?.toIso8601String(),
        'isRecurring': isRecurring,
        if (recurrenceRule != null) 'recurrenceRule': recurrenceRule!.toJson(),
      };

  Task copyWith({
    String? title,
    String? description,
    List<User>? assignedTo,
    String? status,
    String? priority,
    String? category,
    DateTime? dueDate,
    bool? isRecurring,
    RecurrenceRule? recurrenceRule,
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
      completedAt: completedAt,
      completedBy: completedBy,
      isRecurring: isRecurring ?? this.isRecurring,
      recurrenceRule: recurrenceRule ?? this.recurrenceRule,
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
        completedAt,
        isRecurring,
      ];
}

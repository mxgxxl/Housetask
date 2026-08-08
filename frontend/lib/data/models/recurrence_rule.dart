import 'package:equatable/equatable.dart';

/// Recurrence configuration for a recurring task.
class RecurrenceRule extends Equatable {
  final String type; // 'daily' | 'weekly' | 'monthly' | 'custom'
  final int? interval;
  final List<int>? daysOfWeek; // 0=Sunday ... 6=Saturday
  final int? dayOfMonth;

  const RecurrenceRule({
    required this.type,
    this.interval,
    this.daysOfWeek,
    this.dayOfMonth,
  });

  factory RecurrenceRule.fromJson(Map<String, dynamic> json) {
    return RecurrenceRule(
      type: (json['type'] ?? 'daily') as String,
      interval: json['interval'] as int?,
      daysOfWeek: (json['daysOfWeek'] as List<dynamic>?)
          ?.map((e) => (e as num).toInt())
          .toList(),
      dayOfMonth: json['dayOfMonth'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        if (interval != null) 'interval': interval,
        if (daysOfWeek != null) 'daysOfWeek': daysOfWeek,
        if (dayOfMonth != null) 'dayOfMonth': dayOfMonth,
      };

  @override
  List<Object?> get props => [type, interval, daysOfWeek, dayOfMonth];
}

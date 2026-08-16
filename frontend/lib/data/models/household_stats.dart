import 'package:equatable/equatable.dart';

/// Per-period stats window (PDR-007).
enum StatsPeriod { last30days, allTime }

extension StatsPeriodQuery on StatsPeriod {
  String get queryValue => this == StatsPeriod.last30days ? 'last30days' : 'allTime';
}

/// Per-member load/completion counts within a [HouseholdStats] response.
class MemberStat extends Equatable {
  final String userId;
  final String userName;
  final String? avatarUrl;
  final int created;
  final int completed;

  const MemberStat({
    required this.userId,
    required this.userName,
    this.avatarUrl,
    required this.created,
    required this.completed,
  });

  factory MemberStat.fromJson(Map<String, dynamic> json) {
    return MemberStat(
      userId: (json['userId'] ?? '').toString(),
      userName: (json['userName'] ?? '') as String,
      avatarUrl: json['avatarUrl'] as String?,
      created: (json['created'] ?? 0) as int,
      completed: (json['completed'] ?? 0) as int,
    );
  }

  @override
  List<Object?> get props => [userId, userName, avatarUrl, created, completed];
}

/// Household member with the most completions in the period, or null if
/// nobody completed anything yet.
class TopCompleter extends Equatable {
  final String userId;
  final String userName;
  final int completed;

  const TopCompleter({required this.userId, required this.userName, required this.completed});

  factory TopCompleter.fromJson(Map<String, dynamic> json) {
    return TopCompleter(
      userId: (json['userId'] ?? '').toString(),
      userName: (json['userName'] ?? '') as String,
      completed: (json['completed'] ?? 0) as int,
    );
  }

  @override
  List<Object?> get props => [userId, userName, completed];
}

/// GET /households/:householdId/stats response (PDR-007): load/completion
/// visibility, the seed for future retention features.
class HouseholdStats extends Equatable {
  final int totalTasks;
  final int completedTasks;
  final double completionRate;
  final List<MemberStat> memberStats;
  final TopCompleter? topCompleter;
  final StatsPeriod period;

  const HouseholdStats({
    required this.totalTasks,
    required this.completedTasks,
    required this.completionRate,
    required this.memberStats,
    required this.topCompleter,
    required this.period,
  });

  factory HouseholdStats.fromJson(Map<String, dynamic> json) {
    return HouseholdStats(
      totalTasks: (json['totalTasks'] ?? 0) as int,
      completedTasks: (json['completedTasks'] ?? 0) as int,
      completionRate: ((json['completionRate'] ?? 0) as num).toDouble(),
      memberStats: (json['memberStats'] as List<dynamic>? ?? [])
          .map((e) => MemberStat.fromJson(e as Map<String, dynamic>))
          .toList(),
      topCompleter: json['topCompleter'] != null
          ? TopCompleter.fromJson(json['topCompleter'] as Map<String, dynamic>)
          : null,
      period: (json['period'] == 'allTime') ? StatsPeriod.allTime : StatsPeriod.last30days,
    );
  }

  @override
  List<Object?> get props =>
      [totalTasks, completedTasks, completionRate, memberStats, topCompleter, period];
}

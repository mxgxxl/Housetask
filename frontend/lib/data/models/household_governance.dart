import 'package:equatable/equatable.dart';

/// What leaving a household changed on the server (TD-067, PDR-022 D3).
///
/// Deliberately not a [Household]: the caller stopped being a member, so the
/// server does not hand back the roster or the invite code. The two ids are
/// what the UI needs to explain the succession that just happened — "Ana is
/// now the administrator" — and both name people the caller lived with a
/// moment ago.
class LeaveOutcome extends Equatable {
  /// Who was promoted to admin because the leaver was the last one, if anyone.
  final String? promotedUserId;

  /// Who inherited ownership because the leaver was the creator, if anyone.
  final String? newOwnerId;

  const LeaveOutcome({this.promotedUserId, this.newOwnerId});

  factory LeaveOutcome.fromJson(Map<String, dynamic> json) => LeaveOutcome(
        promotedUserId: json['promotedUserId']?.toString(),
        newOwnerId: json['newOwnerId']?.toString(),
      );

  @override
  List<Object?> get props => [promotedUserId, newOwnerId];
}

/// Whether a household is scheduled for deletion (TD-067, PDR-022 D4).
///
/// Every member can read this even though only the creator can schedule or
/// cancel one: a pending deletion is something everyone living in the
/// household is entitled to see.
class DestructionStatus extends Equatable {
  final bool scheduled;

  /// When the grace period expires. Null when nothing is pending.
  final DateTime? scheduledAt;

  /// Who asked for it. Null when nothing is pending.
  final String? scheduledBy;

  const DestructionStatus({
    this.scheduled = false,
    this.scheduledAt,
    this.scheduledBy,
  });

  /// True once the deadline has passed and the deletion can be confirmed.
  ///
  /// Computed from the clock on every read rather than stored, because it is a
  /// fact about *now*: a value captured when the screen opened would go stale
  /// while the user is looking at it.
  bool get isExpired =>
      scheduledAt != null && !scheduledAt!.isAfter(DateTime.now());

  /// The response to `schedule`, which carries a deadline but no `scheduled`
  /// flag — it is scheduled by construction — and to `destruction-status`,
  /// which carries both.
  factory DestructionStatus.fromJson(Map<String, dynamic> json) {
    final at = json['scheduledAt'] != null
        ? DateTime.tryParse(json['scheduledAt'].toString())
        : null;
    return DestructionStatus(
      scheduled: (json['scheduled'] as bool?) ?? (at != null),
      scheduledAt: at,
      scheduledBy: json['scheduledBy']?.toString(),
    );
  }

  @override
  List<Object?> get props => [scheduled, scheduledAt, scheduledBy];
}

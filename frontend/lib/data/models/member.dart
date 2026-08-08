import 'package:equatable/equatable.dart';
import 'user.dart';

/// A household member: the user plus their role and join date.
class Member extends Equatable {
  final User user;
  final String role; // 'admin' | 'member'
  final DateTime? joinedAt;

  const Member({required this.user, required this.role, this.joinedAt});

  bool get isAdmin => role == 'admin';

  factory Member.fromJson(Map<String, dynamic> json) {
    return Member(
      user: User.fromRef(json['user']),
      role: (json['role'] ?? 'member') as String,
      joinedAt: json['joinedAt'] != null
          ? DateTime.tryParse(json['joinedAt'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'user': user.toJson(),
        'role': role,
        'joinedAt': joinedAt?.toIso8601String(),
      };

  @override
  List<Object?> get props => [user, role, joinedAt];
}

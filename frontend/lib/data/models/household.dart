import 'package:equatable/equatable.dart';
import 'member.dart';

/// A household groups members and owns tasks + shopping items.
class Household extends Equatable {
  final String id;
  final String name;
  final String inviteCode;
  final String createdBy;
  final DateTime? createdAt;
  final List<Member> members;

  const Household({
    required this.id,
    required this.name,
    required this.inviteCode,
    required this.createdBy,
    this.createdAt,
    this.members = const [],
  });

  factory Household.fromJson(Map<String, dynamic> json) {
    return Household(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      name: (json['name'] ?? '') as String,
      inviteCode: (json['inviteCode'] ?? '') as String,
      createdBy: (json['createdBy'] ?? '').toString(),
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString())
          : null,
      members: (json['members'] as List<dynamic>?)
              ?.map((e) => Member.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'inviteCode': inviteCode,
        'createdBy': createdBy,
        'createdAt': createdAt?.toIso8601String(),
        'members': members.map((m) => m.toJson()).toList(),
      };

  @override
  List<Object?> get props => [id, name, inviteCode, createdBy, members];
}

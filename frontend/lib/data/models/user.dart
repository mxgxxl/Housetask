import 'package:equatable/equatable.dart';

/// An application user. Immutable value object.
class User extends Equatable {
  final String id;
  final String email;
  final String name;
  final String? avatarUrl;
  final List<String> households;

  const User({
    required this.id,
    required this.email,
    required this.name,
    this.avatarUrl,
    this.households = const [],
  });

  /// Parse a user from JSON. Tolerates both a full object and a bare id
  /// string (as returned when a reference is not populated).
  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      email: (json['email'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      avatarUrl: json['avatarUrl'] as String?,
      households: (json['households'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  /// Build a user from a value that may be a Map (populated) or a String id.
  static User fromRef(dynamic value) {
    // `is Map`, not `is Map<String, dynamic>`: a populated ref read back from
    // the Hive cache is a _Map<dynamic, dynamic>, so the narrow test was false
    // for it and execution fell through to the bare-id branch below — which
    // does not throw, it just stringifies the WHOLE map into the id. Cached
    // assignees came back as `{id: u1, email: ..., name: ...}` with no name and
    // no email, quietly breaking avatars and the "Ex-miembro" check offline
    // (Hard Rule 16). Same root cause as the recurrenceRule cast in Task.
    if (value is Map) return User.fromJson(Map<String, dynamic>.from(value));
    return User(id: value?.toString() ?? '', email: '', name: '');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'name': name,
        'avatarUrl': avatarUrl,
        'households': households,
      };

  /// First-letter initials for avatar placeholders.
  String get initials {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  User copyWith({String? name, String? avatarUrl, List<String>? households}) {
    return User(
      id: id,
      email: email,
      name: name ?? this.name,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      households: households ?? this.households,
    );
  }

  @override
  List<Object?> get props => [id, email, name, avatarUrl, households];
}

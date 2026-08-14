import 'package:equatable/equatable.dart';

/// The household's shared pet (PDR-001). `hunger`/`mood` arrive already
/// decayed to "now" by the backend (economy.service.ts's computeDecay) —
/// this model just carries whatever the server sent, it never computes
/// decay itself.
class Pet extends Equatable {
  final String id;
  final String householdId;
  final String species; // cat | dog
  final String name;
  final num hunger;
  final num mood;
  final DateTime? lastFedAt;
  final DateTime? lastPlayedAt;
  final List<String> cosmetics;
  final String? activeCosmetic;

  const Pet({
    required this.id,
    required this.householdId,
    required this.species,
    required this.name,
    this.hunger = 80,
    this.mood = 80,
    this.lastFedAt,
    this.lastPlayedAt,
    this.cosmetics = const [],
    this.activeCosmetic,
  });

  factory Pet.fromJson(Map<String, dynamic> json) {
    return Pet(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      householdId: (json['householdId'] ?? '').toString(),
      species: (json['species'] ?? 'cat') as String,
      name: (json['name'] ?? '') as String,
      hunger: (json['hunger'] ?? 80) as num,
      mood: (json['mood'] ?? 80) as num,
      lastFedAt: json['lastFedAt'] != null
          ? DateTime.tryParse(json['lastFedAt'].toString())
          : null,
      lastPlayedAt: json['lastPlayedAt'] != null
          ? DateTime.tryParse(json['lastPlayedAt'].toString())
          : null,
      cosmetics: (json['cosmetics'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      activeCosmetic: json['activeCosmetic'] as String?,
    );
  }

  Pet copyWith({
    num? hunger,
    num? mood,
    DateTime? lastFedAt,
    DateTime? lastPlayedAt,
    List<String>? cosmetics,
    String? activeCosmetic,
  }) {
    return Pet(
      id: id,
      householdId: householdId,
      species: species,
      name: name,
      hunger: hunger ?? this.hunger,
      mood: mood ?? this.mood,
      lastFedAt: lastFedAt ?? this.lastFedAt,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      cosmetics: cosmetics ?? this.cosmetics,
      activeCosmetic: activeCosmetic ?? this.activeCosmetic,
    );
  }

  @override
  List<Object?> get props => [
        id,
        householdId,
        species,
        name,
        hunger,
        mood,
        lastFedAt,
        lastPlayedAt,
        cosmetics,
        activeCosmetic,
      ];
}

/// A household's in-flight adoption proposal (PDR-001 A2/A3): one member
/// starts it, a DIFFERENT member must confirm. Mirrors backend
/// AdoptionRequest — see GET/POST/DELETE .../pet/adopt.
class AdoptionRequest extends Equatable {
  final String id;
  final String householdId;
  final String species;
  final String name;
  final String requestedBy;

  const AdoptionRequest({
    required this.id,
    required this.householdId,
    required this.species,
    required this.name,
    required this.requestedBy,
  });

  factory AdoptionRequest.fromJson(Map<String, dynamic> json) {
    return AdoptionRequest(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      householdId: (json['householdId'] ?? '').toString(),
      species: (json['species'] ?? 'cat') as String,
      name: (json['name'] ?? '') as String,
      requestedBy: (json['requestedBy'] ?? '').toString(),
    );
  }

  @override
  List<Object?> get props => [id, householdId, species, name, requestedBy];
}

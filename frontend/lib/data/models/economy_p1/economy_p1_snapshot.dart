import 'package:hive/hive.dart';

import 'economy_p1.dart';

/// One household's P1 economy as cached on disk (TD-066 F1).
///
/// ── Why it is stored as one snapshot ─────────────────────────────────────
/// Unlike tasks, which are normalized by id and only ever upserted (TD-064),
/// the P1 economy is a single coherent reading: a wallet, a plan and a streak
/// that were true together at one instant. Merging halves of two readings
/// would produce a state that never existed on the server — a balance from
/// one moment beside a budget from another — and the number people are most
/// likely to notice being wrong is their own money.
///
/// So a fresher snapshot REPLACES an older one wholesale, and there is
/// nothing to merge.
///
/// ── Versioning ───────────────────────────────────────────────────────────
/// [schemaVersion] travels inside the record rather than in a side channel:
/// on read, a record written by an older build is discarded instead of being
/// coerced, because a half-understood wallet is worse than no wallet. That is
/// the same call the app already makes for a cache whose owner does not match
/// (TD-062) — what cannot be trusted is not shown.
class EconomyP1Snapshot {
  /// Bumped whenever the stored shape changes in a way an older or newer
  /// build could misread. Any mismatch means "throw it away and refetch".
  static const int currentSchemaVersion = 1;

  final String householdId;
  final int schemaVersion;
  final PersonalEconomy personal;
  final HouseholdEconomy household;
  final DateTime refreshedAt;

  const EconomyP1Snapshot({
    required this.householdId,
    required this.personal,
    required this.household,
    required this.refreshedAt,
    this.schemaVersion = currentSchemaVersion,
  });

  /// True when this record was written by the build that is reading it.
  bool get isReadable => schemaVersion == currentSchemaVersion;

  EconomyP1 toEconomy() => EconomyP1(
        personal: personal,
        household: household,
        refreshedAt: refreshedAt,
      );

  Map<String, dynamic> toJson() => {
        'householdId': householdId,
        'schemaVersion': schemaVersion,
        'personal': personal.toJson(),
        'household': household.toJson(),
        'refreshedAt': refreshedAt.toIso8601String(),
      };

  factory EconomyP1Snapshot.fromJson(Map<String, dynamic> json) => EconomyP1Snapshot(
        householdId: (json['householdId'] ?? '').toString(),
        // Absent means "written before versioning existed", which is exactly
        // the case that must not be read as current.
        schemaVersion: json['schemaVersion'] is int ? json['schemaVersion'] as int : 0,
        personal: PersonalEconomy.fromJson(
          Map<String, dynamic>.from((json['personal'] as Map?) ?? const {}),
        ),
        household: HouseholdEconomy.fromJson(
          Map<String, dynamic>.from((json['household'] as Map?) ?? const {}),
        ),
        refreshedAt:
            DateTime.tryParse((json['refreshedAt'] ?? '').toString()) ?? DateTime.now().toUtc(),
      );
}

/// Hand-written for the same reason as the other adapters (see
/// task_adapter.dart): hive_generator is abandoned and incompatible with this
/// project's `analyzer >=8.0.0` test toolchain.
class EconomyP1SnapshotAdapter extends TypeAdapter<EconomyP1Snapshot> {
  @override
  final int typeId = 6;

  @override
  EconomyP1Snapshot read(BinaryReader reader) =>
      EconomyP1Snapshot.fromJson(Map<String, dynamic>.from(reader.readMap()));

  @override
  void write(BinaryWriter writer, EconomyP1Snapshot obj) => writer.writeMap(obj.toJson());
}

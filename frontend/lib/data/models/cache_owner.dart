import 'package:hive/hive.dart';

/// Who the locally cached data belongs to (TD-062).
///
/// The offline cache and the pending-write queue outlive a session: an expired
/// session clears the tokens (`AuthLocalDataSource.clear()`) but never touches
/// Hive, so without this marker a different account signing in on the same
/// device inherits the previous one's queue and replays it under its own
/// token.
///
/// It lives in Hive rather than SharedPreferences on purpose: it describes who
/// owns the Hive data, so it must die with it — `CacheService.clearAll()`
/// wipes it alongside the boxes it describes. Kept in SharedPreferences it
/// could outlive a Hive wipe and go on claiming ownership of data that is no
/// longer there.
///
/// [updatedAt] is not used by any decision. It is here because the question
/// asked while debugging this is never just "whose cache is it" but "since
/// when", and a marker that cannot answer that sends you to the logs.
class CacheOwner {
  final String userId;
  final DateTime updatedAt;

  const CacheOwner({required this.userId, required this.updatedAt});

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory CacheOwner.fromJson(Map<String, dynamic> json) => CacheOwner(
        userId: json['userId'] as String,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}

/// Hand-written for the same reason as the other adapters (see
/// task_adapter.dart): hive_generator is abandoned and incompatible with this
/// project's `analyzer >=8.0.0` test toolchain.
class CacheOwnerAdapter extends TypeAdapter<CacheOwner> {
  @override
  final int typeId = 4;

  @override
  CacheOwner read(BinaryReader reader) =>
      CacheOwner.fromJson(Map<String, dynamic>.from(reader.readMap()));

  @override
  void write(BinaryWriter writer, CacheOwner obj) => writer.writeMap(obj.toJson());
}

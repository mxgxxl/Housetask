import 'package:hive/hive.dart';
import 'household.dart';

/// Hand-written for the same reason as [TaskAdapter] (see task_adapter.dart):
/// hive_generator is abandoned and incompatible with this project's
/// `analyzer >=8.0.0` test toolchain.
///
/// Unlike Task/ShoppingItem, [Household.toJson] is already a full,
/// round-trippable representation (members included), so this adapter reuses
/// it directly instead of needing its own cache-map function.
class HouseholdAdapter extends TypeAdapter<Household> {
  @override
  final int typeId = 2;

  @override
  Household read(BinaryReader reader) =>
      Household.fromJson(Map<String, dynamic>.from(reader.readMap()));

  @override
  void write(BinaryWriter writer, Household obj) => writer.writeMap(obj.toJson());
}

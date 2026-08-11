import 'package:hive/hive.dart';
import 'shopping_item.dart';

/// Full, round-trippable serialization of a [ShoppingItem] for the Hive
/// cache — see [taskToCacheMap] for why this cannot reuse [ShoppingItem.toJson].
Map<String, dynamic> shoppingItemToCacheMap(ShoppingItem item) {
  return {
    'id': item.id,
    'householdId': item.householdId,
    'name': item.name,
    'quantity': item.quantity,
    'unit': item.unit,
    'category': item.category,
    'isPurchased': item.isPurchased,
    'purchasedAt': item.purchasedAt?.toIso8601String(),
    'purchasedBy': item.purchasedBy?.toJson(),
    'addedBy': item.addedBy?.toJson(),
    'isRecurring': item.isRecurring,
    'recurrenceIntervalDays': item.recurrenceIntervalDays,
    'estimatedPrice': item.estimatedPrice,
  };
}

ShoppingItem shoppingItemFromCacheMap(Map<dynamic, dynamic> map) =>
    ShoppingItem.fromJson(Map<String, dynamic>.from(map));

/// Hand-written for the same reason as [TaskAdapter] (see task_adapter.dart):
/// hive_generator is abandoned and incompatible with this project's
/// `analyzer >=8.0.0` test toolchain.
class ShoppingItemAdapter extends TypeAdapter<ShoppingItem> {
  @override
  final int typeId = 1;

  @override
  ShoppingItem read(BinaryReader reader) => shoppingItemFromCacheMap(reader.readMap());

  @override
  void write(BinaryWriter writer, ShoppingItem obj) =>
      writer.writeMap(shoppingItemToCacheMap(obj));
}

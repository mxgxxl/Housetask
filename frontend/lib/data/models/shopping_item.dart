import 'package:equatable/equatable.dart';
import 'user.dart';

/// A shopping-list item belonging to a household.
class ShoppingItem extends Equatable {
  final String id;
  final String householdId;
  final String name;
  final num quantity;
  final String unit;
  final String category; // fridge | pantry | cleaning | personal | other
  final bool isPurchased;
  final DateTime? purchasedAt;
  final User? purchasedBy;
  final User? addedBy;
  final bool isRecurring;
  final int? recurrenceIntervalDays;
  final num? estimatedPrice;

  /// Local-only: false while a create/update/delete made offline is still
  /// waiting in the pending-operations queue. Never sent to the server —
  /// see [toJson].
  final bool isSynced;

  /// Local-only: true when this item was deleted while offline. The row
  /// stays in the cache (struck through in the UI) until the queued delete
  /// actually reaches the server.
  final bool isDeleted;

  const ShoppingItem({
    required this.id,
    required this.householdId,
    required this.name,
    this.quantity = 1,
    this.unit = 'uds',
    this.category = 'other',
    this.isPurchased = false,
    this.purchasedAt,
    this.purchasedBy,
    this.addedBy,
    this.isRecurring = false,
    this.recurrenceIntervalDays,
    this.estimatedPrice,
    this.isSynced = true,
    this.isDeleted = false,
  });

  factory ShoppingItem.fromJson(Map<String, dynamic> json) {
    return ShoppingItem(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      householdId: (json['householdId'] ?? '').toString(),
      name: (json['name'] ?? '') as String,
      quantity: (json['quantity'] ?? 1) as num,
      unit: (json['unit'] ?? 'uds') as String,
      category: (json['category'] ?? 'other') as String,
      isPurchased: (json['isPurchased'] ?? false) as bool,
      purchasedAt: json['purchasedAt'] != null
          ? DateTime.tryParse(json['purchasedAt'].toString())
          : null,
      purchasedBy:
          json['purchasedBy'] != null ? User.fromRef(json['purchasedBy']) : null,
      addedBy: json['addedBy'] != null ? User.fromRef(json['addedBy']) : null,
      isRecurring: (json['isRecurring'] ?? false) as bool,
      recurrenceIntervalDays: json['recurrenceIntervalDays'] as int?,
      estimatedPrice: json['estimatedPrice'] as num?,
      isSynced: (json['isSynced'] ?? true) as bool,
      isDeleted: (json['isDeleted'] ?? false) as bool,
    );
  }

  /// Payload for create/update requests (mutable fields only). Deliberately
  /// excludes [isSynced]/[isDeleted]: local sync-queue bookkeeping only.
  Map<String, dynamic> toJson() => {
        'name': name,
        'quantity': quantity,
        'unit': unit,
        'category': category,
        'isPurchased': isPurchased,
        'isRecurring': isRecurring,
        if (recurrenceIntervalDays != null)
          'recurrenceIntervalDays': recurrenceIntervalDays,
        if (estimatedPrice != null) 'estimatedPrice': estimatedPrice,
      };

  ShoppingItem copyWith({
    String? name,
    num? quantity,
    String? unit,
    String? category,
    bool? isPurchased,
    bool? isRecurring,
    int? recurrenceIntervalDays,
    num? estimatedPrice,
    bool? isSynced,
    bool? isDeleted,
  }) {
    return ShoppingItem(
      id: id,
      householdId: householdId,
      name: name ?? this.name,
      quantity: quantity ?? this.quantity,
      unit: unit ?? this.unit,
      category: category ?? this.category,
      isPurchased: isPurchased ?? this.isPurchased,
      purchasedAt: purchasedAt,
      purchasedBy: purchasedBy,
      addedBy: addedBy,
      isRecurring: isRecurring ?? this.isRecurring,
      recurrenceIntervalDays: recurrenceIntervalDays ?? this.recurrenceIntervalDays,
      estimatedPrice: estimatedPrice ?? this.estimatedPrice,
      isSynced: isSynced ?? this.isSynced,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }

  @override
  List<Object?> get props => [
        id,
        householdId,
        name,
        quantity,
        unit,
        category,
        isPurchased,
        isRecurring,
        isSynced,
        isDeleted,
      ];
}

import 'package:equatable/equatable.dart';

/// One entry from GET /economy's recentTransactions (PDR-001).
class EconomyTransaction extends Equatable {
  final num amount;
  final String reason;
  final String? refId;
  final DateTime? createdAt;

  const EconomyTransaction({
    required this.amount,
    required this.reason,
    this.refId,
    this.createdAt,
  });

  factory EconomyTransaction.fromJson(Map<String, dynamic> json) {
    return EconomyTransaction(
      amount: (json['amount'] ?? 0) as num,
      reason: (json['reason'] ?? '') as String,
      refId: json['refId'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString())
          : null,
    );
  }

  @override
  List<Object?> get props => [amount, reason, refId, createdAt];
}

/// A household's coin economy snapshot — GET /households/:id/economy.
class Economy extends Equatable {
  final num balance;
  final num dailyEarned;
  final List<EconomyTransaction> recentTransactions;

  const Economy({
    this.balance = 0,
    this.dailyEarned = 0,
    this.recentTransactions = const [],
  });

  factory Economy.fromJson(Map<String, dynamic> json) {
    return Economy(
      balance: (json['balance'] ?? 0) as num,
      dailyEarned: (json['dailyEarned'] ?? 0) as num,
      recentTransactions: (json['recentTransactions'] as List<dynamic>?)
              ?.map((e) =>
                  EconomyTransaction.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
    );
  }

  @override
  List<Object?> get props => [balance, dailyEarned, recentTransactions];
}

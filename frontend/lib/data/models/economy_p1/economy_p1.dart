import 'package:equatable/equatable.dart';

/// The P1 economy as the client sees it (TD-066 F1).
///
/// Mirrors what `GET /economy/p1/me` and `GET /economy/p1/household` actually
/// return, field for field. Where the backend and the UI disagree on a name
/// the WIRE name wins here and a getter provides the friendlier one — a model
/// that renames fields on the way in makes every future contract change a
/// hunt through two vocabularies.
///
/// Every class is immutable with `copyWith`, and extends `Equatable` so a
/// Cubit emitting an identical snapshot does not rebuild the tree.

/// Reads a JSON number defensively.
///
/// The API sends integers, but a value that arrives as a double (or absent,
/// from an older build talking to a newer server, or vice versa) must not
/// crash the app over a wallet balance. Defaulting beats throwing here: the
/// worst case is showing 0 where the truth was 5, which the next refresh
/// corrects.
int _int(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.round();
  return fallback;
}

List<String> _strings(dynamic value) {
  if (value is! List) return const [];
  return value.map((e) => e.toString()).toList(growable: false);
}

List<int> _ints(dynamic value) {
  if (value is! List) return const [];
  return value.map((e) => _int(e)).toList(growable: false);
}

Map<String, dynamic> _map(dynamic value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return const {};
}

/// A member's personal coin wallet (PDR-012).
class WalletPersonal extends Equatable {
  /// All-time balance: the sum of the member's ledger, never a counter.
  final int balance;

  /// What today's allocation released on its own. Zero on Sunday (PDR-013).
  final int dailyReleased;

  /// What is still claimable this week — today's release plus what is unspent.
  ///
  /// On Sunday this is usually NOT zero even though [dailyReleased] is: the
  /// week's unspent remainder stays claimable. A UI that shows "available
  /// today" must read THIS, not [dailyReleased], or it will report nothing
  /// left on a day the member can still earn.
  final int remaining;

  const WalletPersonal({
    this.balance = 0,
    this.dailyReleased = 0,
    this.remaining = 0,
  });

  factory WalletPersonal.fromJson(Map<String, dynamic> json) => WalletPersonal(
        balance: _int(json['balance']),
        dailyReleased: _int(json['dailyReleased']),
        remaining: _int(json['remaining']),
      );

  Map<String, dynamic> toJson() => {
        'balance': balance,
        'dailyReleased': dailyReleased,
        'remaining': remaining,
      };

  @override
  List<Object?> get props => [balance, dailyReleased, remaining];
}

/// One XP track — personal (portable) or household (shared), PDR-017.
class ProgressP1 extends Equatable {
  final int xp;
  final int level;

  /// Every unlock earned up to [level]: title/badge ids for the personal
  /// track, shared cosmetic ids for the household one.
  final List<String> unlocks;

  /// First completions this track has been rewarded for.
  final int tasksCompleted;

  /// XP accumulated since reaching [level].
  final int xpIntoLevel;

  /// XP the whole of [level] is worth.
  final int xpForNextLevel;

  /// XP still needed to reach `level + 1`.
  final int xpToNextLevel;

  const ProgressP1({
    this.xp = 0,
    this.level = 1,
    this.unlocks = const [],
    this.tasksCompleted = 0,
    this.xpIntoLevel = 0,
    this.xpForNextLevel = 0,
    this.xpToNextLevel = 0,
  });

  /// How far through the current level, as 0…1 — what the avatar ring draws.
  ///
  /// Guards the divisor: a level worth 0 XP would otherwise be NaN, and a
  /// NaN reaches Flutter as a layout exception rather than a wrong number.
  double get progressToNext {
    if (xpForNextLevel <= 0) return 0;
    return (xpIntoLevel / xpForNextLevel).clamp(0.0, 1.0);
  }

  factory ProgressP1.fromJson(Map<String, dynamic> json) => ProgressP1(
        xp: _int(json['xp']),
        level: _int(json['level'], 1),
        unlocks: _strings(json['unlocks']),
        tasksCompleted: _int(json['tasksCompleted']),
        xpIntoLevel: _int(json['xpIntoLevel']),
        xpForNextLevel: _int(json['xpForNextLevel']),
        xpToNextLevel: _int(json['xpToNextLevel']),
      );

  Map<String, dynamic> toJson() => {
        'xp': xp,
        'level': level,
        'unlocks': unlocks,
        'tasksCompleted': tasksCompleted,
        'xpIntoLevel': xpIntoLevel,
        'xpForNextLevel': xpForNextLevel,
        'xpToNextLevel': xpToNextLevel,
      };

  @override
  List<Object?> get props =>
      [xp, level, unlocks, tasksCompleted, xpIntoLevel, xpForNextLevel, xpToNextLevel];
}

/// One line of the weekly plan: what a task or rule is worth this week.
class BudgetAllocation extends Equatable {
  /// Stable identity of the line, which outlives any single task document.
  final String allocationKey;
  final String? taskOrRuleId;

  /// Hundredths of a completion per week — 700 is daily, 100 is weekly.
  final int expectedFrequency;

  /// Coins one completion of this line pays.
  final int coinAmount;

  /// `automatic` or `manual`; a manual line is one the member edited.
  final String mode;

  const BudgetAllocation({
    required this.allocationKey,
    this.taskOrRuleId,
    this.expectedFrequency = 0,
    this.coinAmount = 0,
    this.mode = 'automatic',
  });

  bool get isManual => mode == 'manual';

  /// The common tranche that funds unassigned tasks (owner decision P3).
  bool get isCommonTranche => allocationKey == 'common:unassigned';

  factory BudgetAllocation.fromJson(Map<String, dynamic> json) => BudgetAllocation(
        allocationKey: (json['allocationKey'] ?? '').toString(),
        taskOrRuleId: json['taskOrRuleId']?.toString(),
        expectedFrequency: _int(json['expectedFrequency']),
        coinAmount: _int(json['coinAmount']),
        mode: (json['mode'] ?? 'automatic').toString(),
      );

  Map<String, dynamic> toJson() => {
        'allocationKey': allocationKey,
        'taskOrRuleId': taskOrRuleId,
        'expectedFrequency': expectedFrequency,
        'coinAmount': coinAmount,
        'mode': mode,
      };

  @override
  List<Object?> get props => [allocationKey, taskOrRuleId, expectedFrequency, coinAmount, mode];
}

/// A member's weekly budget and its plan (PDR-011).
class PersonalBudget extends Equatable {
  /// ISO week, `YYYY-Www`, derived in [periodTimeZone].
  final String weekKey;

  /// The IANA zone the week's day boundaries were computed in, snapshotted
  /// when the week opened. It wins over whatever zone the device reports
  /// later — a member who travels mid-week must not re-slice a settled week.
  final String periodTimeZone;

  final int weeklyCap;
  final int releasedCoins;
  final int grantedCoins;

  /// Bumped on every plan change, so an edit made from a stale plan can be
  /// told to refetch instead of overwriting a newer one.
  final int planVersion;

  final List<BudgetAllocation> allocations;

  const PersonalBudget({
    this.weekKey = '',
    this.periodTimeZone = 'UTC',
    this.weeklyCap = 0,
    this.releasedCoins = 0,
    this.grantedCoins = 0,
    this.planVersion = 0,
    this.allocations = const [],
  });

  /// True when any line has been edited by hand — what "Volver a automático"
  /// is offered for.
  bool get hasManualEdits => allocations.any((a) => a.isManual);

  factory PersonalBudget.fromJson(Map<String, dynamic> json) => PersonalBudget(
        weekKey: (json['weekKey'] ?? '').toString(),
        periodTimeZone: (json['periodTimeZone'] ?? 'UTC').toString(),
        weeklyCap: _int(json['weeklyCap']),
        releasedCoins: _int(json['releasedCoins']),
        grantedCoins: _int(json['grantedCoins']),
        planVersion: _int(json['planVersion']),
        allocations: (json['allocations'] as List<dynamic>? ?? const [])
            .map((e) => BudgetAllocation.fromJson(_map(e)))
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'weekKey': weekKey,
        'periodTimeZone': periodTimeZone,
        'weeklyCap': weeklyCap,
        'releasedCoins': releasedCoins,
        'grantedCoins': grantedCoins,
        'planVersion': planVersion,
        'allocations': allocations.map((a) => a.toJson()).toList(growable: false),
      };

  @override
  List<Object?> get props =>
      [weekKey, periodTimeZone, weeklyCap, releasedCoins, grantedCoins, planVersion, allocations];
}

/// A member's activity streak and ice reserve (PDR-019).
class PersonalStreak extends Equatable {
  final int current;

  /// The highest run ever reached, which a reset never lowers — it is what
  /// proves the progress survived a bad day.
  final int longest;

  final int iceReserve;

  /// Which of 7/14/30/50/100 the longest run has passed.
  final List<int> iceMilestonesReached;

  const PersonalStreak({
    this.current = 0,
    this.longest = 0,
    this.iceReserve = 0,
    this.iceMilestonesReached = const [],
  });

  factory PersonalStreak.fromJson(Map<String, dynamic> json) => PersonalStreak(
        current: _int(json['current']),
        longest: _int(json['longest']),
        iceReserve: _int(json['iceReserve']),
        iceMilestonesReached: _ints(json['iceMilestonesReached']),
      );

  Map<String, dynamic> toJson() => {
        'current': current,
        'longest': longest,
        'iceReserve': iceReserve,
        'iceMilestonesReached': iceMilestonesReached,
      };

  @override
  List<Object?> get props => [current, longest, iceReserve, iceMilestonesReached];
}

/// One member's total contribution to a goal (UX-P1-SPEC §6: «Tú: 40 · Ana: 28»).
class SavingsContributor extends Equatable {
  final String userId;
  final String name;
  final int amount;

  const SavingsContributor({
    required this.userId,
    this.name = '',
    this.amount = 0,
  });

  factory SavingsContributor.fromJson(Map<String, dynamic> json) => SavingsContributor(
        userId: (json['userId'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        amount: _int(json['amount']),
      );

  Map<String, dynamic> toJson() => {'userId': userId, 'name': name, 'amount': amount};

  @override
  List<Object?> get props => [userId, name, amount];
}

/// The household's joint savings goal (PDR-018).
///
/// Not a shared wallet: coins stay personal, and this is the cooperative way
/// to buy one shared item. Cancelling it, or leaving the household, returns
/// each contributor's coins.
class SavingsGoal extends Equatable {
  final String id;
  final String itemType;
  final String itemId;
  final int targetCoins;
  final int contributedCoins;

  /// `active`, `unlocked` or `cancelled`. The backend says `unlocked`, not
  /// "completed": reaching the price unlocks the item.
  final String status;

  final String createdBy;

  /// One figure per person, not one row per contribution.
  final List<SavingsContributor> contributions;

  const SavingsGoal({
    required this.id,
    this.itemType = '',
    this.itemId = '',
    this.targetCoins = 0,
    this.contributedCoins = 0,
    this.status = 'active',
    this.createdBy = '',
    this.contributions = const [],
  });

  bool get isActive => status == 'active';
  bool get isUnlocked => status == 'unlocked';

  /// How close the household is, as 0…1. Guards the divisor for the same
  /// reason [ProgressP1.progressToNext] does.
  double get progress {
    if (targetCoins <= 0) return 0;
    return (contributedCoins / targetCoins).clamp(0.0, 1.0);
  }

  factory SavingsGoal.fromJson(Map<String, dynamic> json) => SavingsGoal(
        id: (json['id'] ?? json['_id'] ?? '').toString(),
        itemType: (json['itemType'] ?? '').toString(),
        itemId: (json['itemId'] ?? '').toString(),
        targetCoins: _int(json['targetCoins']),
        contributedCoins: _int(json['contributedCoins']),
        status: (json['status'] ?? 'active').toString(),
        createdBy: (json['createdBy'] ?? '').toString(),
        contributions: (json['contributions'] as List<dynamic>? ?? const [])
            .map((e) => SavingsContributor.fromJson(_map(e)))
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'itemType': itemType,
        'itemId': itemId,
        'targetCoins': targetCoins,
        'contributedCoins': contributedCoins,
        'status': status,
        'createdBy': createdBy,
        'contributions': contributions.map((c) => c.toJson()).toList(growable: false),
      };

  @override
  List<Object?> get props =>
      [id, itemType, itemId, targetCoins, contributedCoins, status, createdBy, contributions];
}

/// One member of the household, with the shared-progress signals only.
///
/// Carries no wallet, budget or streak: PDR-012 makes those private, and the
/// household endpoint never sends them.
class HouseholdMemberProgress extends Equatable {
  final String userId;
  final String name;
  final String? avatarUrl;
  final int level;
  final int xp;

  const HouseholdMemberProgress({
    required this.userId,
    this.name = '',
    this.avatarUrl,
    this.level = 1,
    this.xp = 0,
  });

  factory HouseholdMemberProgress.fromJson(Map<String, dynamic> json) =>
      HouseholdMemberProgress(
        userId: (json['userId'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        avatarUrl: json['avatarUrl']?.toString(),
        level: _int(json['level'], 1),
        xp: _int(json['xp']),
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'name': name,
        'avatarUrl': avatarUrl,
        'level': level,
        'xp': xp,
      };

  @override
  List<Object?> get props => [userId, name, avatarUrl, level, xp];
}

/// `GET /economy/p1/me`.
class PersonalEconomy extends Equatable {
  /// False while P1 is off for the household — every household today.
  ///
  /// The backend answers a complete, ZEROED structure rather than a 404 in
  /// that case, so this is what tells the UI to hide itself rather than render
  /// zeroes as if they were real.
  final bool enabled;

  final WalletPersonal wallet;
  final ProgressP1 personalProgress;
  final PersonalStreak streak;
  final PersonalBudget weeklyBudget;

  const PersonalEconomy({
    this.enabled = false,
    this.wallet = const WalletPersonal(),
    this.personalProgress = const ProgressP1(),
    this.streak = const PersonalStreak(),
    this.weeklyBudget = const PersonalBudget(),
  });

  factory PersonalEconomy.fromJson(Map<String, dynamic> json) => PersonalEconomy(
        enabled: json['enabled'] == true,
        wallet: WalletPersonal.fromJson(_map(json['wallet'])),
        personalProgress: ProgressP1.fromJson(_map(json['personalProgress'])),
        streak: PersonalStreak.fromJson(_map(json['streak'])),
        weeklyBudget: PersonalBudget.fromJson(_map(json['weeklyBudget'])),
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'wallet': wallet.toJson(),
        'personalProgress': personalProgress.toJson(),
        'streak': streak.toJson(),
        'weeklyBudget': weeklyBudget.toJson(),
      };

  PersonalEconomy copyWith({
    bool? enabled,
    WalletPersonal? wallet,
    ProgressP1? personalProgress,
    PersonalStreak? streak,
    PersonalBudget? weeklyBudget,
  }) =>
      PersonalEconomy(
        enabled: enabled ?? this.enabled,
        wallet: wallet ?? this.wallet,
        personalProgress: personalProgress ?? this.personalProgress,
        streak: streak ?? this.streak,
        weeklyBudget: weeklyBudget ?? this.weeklyBudget,
      );

  @override
  List<Object?> get props => [enabled, wallet, personalProgress, streak, weeklyBudget];
}

/// `GET /economy/p1/household`.
class HouseholdEconomy extends Equatable {
  final bool enabled;
  final ProgressP1 householdProgress;
  final SavingsGoal? activeSavingsGoal;

  /// In JOIN order, never ranked by XP — the product rules out a leaderboard
  /// (UX-P1-SPEC §8), and a client that sorted this would render one.
  final List<HouseholdMemberProgress> members;

  const HouseholdEconomy({
    this.enabled = false,
    this.householdProgress = const ProgressP1(),
    this.activeSavingsGoal,
    this.members = const [],
  });

  factory HouseholdEconomy.fromJson(Map<String, dynamic> json) {
    final goal = json['activeSavingsGoal'];
    return HouseholdEconomy(
      enabled: json['enabled'] == true,
      householdProgress: ProgressP1.fromJson(_map(json['householdProgress'])),
      activeSavingsGoal: goal == null ? null : SavingsGoal.fromJson(_map(goal)),
      members: (json['members'] as List<dynamic>? ?? const [])
          .map((e) => HouseholdMemberProgress.fromJson(_map(e)))
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'householdProgress': householdProgress.toJson(),
        'activeSavingsGoal': activeSavingsGoal?.toJson(),
        'members': members.map((m) => m.toJson()).toList(growable: false),
      };

  HouseholdEconomy copyWith({
    bool? enabled,
    ProgressP1? householdProgress,
    SavingsGoal? activeSavingsGoal,
    bool clearGoal = false,
    List<HouseholdMemberProgress>? members,
  }) =>
      HouseholdEconomy(
        enabled: enabled ?? this.enabled,
        householdProgress: householdProgress ?? this.householdProgress,
        activeSavingsGoal: clearGoal ? null : (activeSavingsGoal ?? this.activeSavingsGoal),
        members: members ?? this.members,
      );

  @override
  List<Object?> get props => [enabled, householdProgress, activeSavingsGoal, members];
}

/// Both halves together — what a screen actually needs, and what the cache
/// stores as one snapshot.
class EconomyP1 extends Equatable {
  final PersonalEconomy personal;
  final HouseholdEconomy household;

  /// When this snapshot was fetched. Drives "this may be stale" states, which
  /// is a display decision and never a reason to discard the content.
  final DateTime? refreshedAt;

  const EconomyP1({
    this.personal = const PersonalEconomy(),
    this.household = const HouseholdEconomy(),
    this.refreshedAt,
  });

  /// True only when BOTH halves report the economy on. They come from two
  /// requests and could in principle disagree mid-activation; treating that
  /// as "off" keeps the UI from rendering half a feature.
  bool get enabled => personal.enabled && household.enabled;

  EconomyP1 copyWith({
    PersonalEconomy? personal,
    HouseholdEconomy? household,
    DateTime? refreshedAt,
  }) =>
      EconomyP1(
        personal: personal ?? this.personal,
        household: household ?? this.household,
        refreshedAt: refreshedAt ?? this.refreshedAt,
      );

  @override
  List<Object?> get props => [personal, household, refreshedAt];
}

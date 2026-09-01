import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:uuid/uuid.dart';

import '../../core/errors/failures.dart';
import '../../data/models/economy_p1/economy_p1.dart';
import '../../data/repositories/economy_p1_repository.dart';
import '../../services/connectivity_service.dart';
import '../../services/device_timezone_service.dart';

// ── Payload readers ────────────────────────────────────────────────────────
// Same defensive treatment the F1 models and EconomyP1Cubit give network
// input: a malformed field yields a default rather than throwing, because a
// socket frame must never be able to crash the tab it updates.

Map<String, dynamic> _payload(dynamic data) {
  if (data is Map) return Map<String, dynamic>.from(data);
  return const <String, dynamic>{};
}

int _int(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.round();
  return fallback;
}

List<String> _strings(dynamic value) {
  if (value is! List) return const [];
  return value.map((e) => e.toString()).toList(growable: false);
}

int _atLeastZero(int value) => value < 0 ? 0 : value;

/// Which kind of shared thing just happened, so the UI can pick modal vs
/// toast without re-deriving it from copy (UX-P1-SPEC §3's hierarchy).
enum HouseholdNoticeKind {
  /// Modal, «lo habéis conseguido juntos» (UX-P1-SPEC §3).
  levelUp,

  /// Toast — the pooled task count crossed 25/100/250/750.
  milestone,

  /// Modal — the joint savings goal reached its price (PDR-018).
  goalUnlocked,
}

/// One shared thing worth telling the household about.
///
/// [sequence] exists for the same reason [EconomyP1Notice]'s does: the state
/// is Equatable, so two identical notices in a row would compare equal and the
/// second would never reach the UI. A monotonic counter makes each distinct.
class HouseholdEconomyNotice extends Equatable {
  final HouseholdNoticeKind kind;
  final String message;

  /// Shared unlocks announced with a household level-up; empty otherwise.
  final List<String> unlocks;

  /// The household level reached, for [HouseholdNoticeKind.levelUp].
  final int level;

  /// The milestone value crossed, for [HouseholdNoticeKind.milestone].
  final int value;

  final int sequence;

  const HouseholdEconomyNotice({
    required this.kind,
    required this.message,
    required this.sequence,
    this.unlocks = const [],
    this.level = 0,
    this.value = 0,
  });

  @override
  List<Object?> get props => [kind, message, unlocks, level, value, sequence];
}

enum HouseholdEconomyStatus { initial, loading, ready, failure }

/// Why «Elegid algo para los dos» is not available (TD-066 F4).
///
/// [goalExists] is PDR-018's «en v1 solo hay una meta activa», enforced
/// server-side by a partial unique index — so this is the client saying the
/// same thing early, not the client enforcing it.
enum GoalCreateUnavailableReason { none, flagOff, goalExists, offline, inFlight }

/// Why «Cancelar meta» is not available (TD-066 F4).
///
/// [notAllowed] mirrors the backend rule: only the goal's creator or a
/// household admin may dissolve it, because the money in it belongs to
/// everyone who put some in.
enum GoalCancelUnavailableReason {
  none,
  flagOff,
  noGoal,
  goalInactive,
  notAllowed,
  offline,
  inFlight,
}

/// Everything the «Hogar» section renders (TD-066 F3).
///
/// Shared only. There is deliberately no wallet, budget or streak here: those
/// are personal (PDR-012), they never leave the personal room, and the
/// household read endpoint does not send them. What IS shared is household XP
/// and level, the roster with each member's personal level/XP (owner decision,
/// 2026-08-27) and the joint savings goal with its per-member breakdown —
/// which UX-P1-SPEC §4 renders in as many words as «Tú: 40 · Ana: 28».
class HouseholdEconomyState extends Equatable {
  final HouseholdEconomyStatus status;

  /// False while P1 is off for this household — every household today.
  ///
  /// When false the section renders NOTHING. The backend answers a complete
  /// zeroed structure rather than a 404, so a UI that trusted the numbers
  /// would show a real-looking level 1 and a household of members all sitting
  /// at 0 XP to a household whose economy was simply never switched on.
  final bool enabled;

  final ProgressP1 householdProgress;

  /// In JOIN order, exactly as the server sent it.
  ///
  /// Never sorted, never re-ordered, and never rendered with a position:
  /// UX-P1-SPEC §0 rules out leaderboards, and sorting this list by XP is all
  /// it would take to build one by accident.
  final List<HouseholdMemberProgress> members;

  /// The one goal PDR-018 allows at a time, or null.
  ///
  /// It lingers here for a moment after `household:savings_goal_unlocked`
  /// with `status: 'unlocked'`, so the section can say so; the next read drops
  /// it, because `GET /economy/p1/household` only returns an ACTIVE goal.
  final SavingsGoal? activeSavingsGoal;

  /// Who is looking, so the breakdown can say «Tú» for one of the rows.
  final String? currentUserId;

  /// Whether the viewer is a household admin (TD-066 F4).
  ///
  /// Only used to decide whether «Cancelar meta» is offered. The BACKEND is
  /// the authority — it refuses a cancel from anyone but the creator or an
  /// admin with a 403 — so a wrong value here costs a button, never a
  /// permission. Roles cannot change while the app runs, since
  /// promotion/demotion is TD-067 and unimplemented.
  final bool currentUserIsAdmin;

  final DateTime? refreshedAt;

  /// The content came from cache because the network could not be reached.
  /// Never an error: stale content beats an empty screen (TD-064's pattern).
  final bool isStale;

  /// A failed LOAD. Fatal to the section.
  final String? error;

  /// A failed WRITE — a refused create or cancel. Shown in a snackbar and
  /// deliberately separate from [error]: the section keeps rendering.
  final String? actionError;

  final bool isOnline;
  final bool isCreatingGoal;
  final bool isCancellingGoal;

  /// Modal-class: a household level-up or an unlocked goal.
  final HouseholdEconomyNotice? celebration;

  /// Toast-class: a pooled milestone.
  final HouseholdEconomyNotice? notice;

  const HouseholdEconomyState({
    this.status = HouseholdEconomyStatus.initial,
    this.enabled = false,
    this.householdProgress = const ProgressP1(),
    this.members = const [],
    this.activeSavingsGoal,
    this.currentUserId,
    this.currentUserIsAdmin = false,
    this.refreshedAt,
    this.isStale = false,
    this.error,
    this.actionError,
    this.isOnline = true,
    this.isCreatingGoal = false,
    this.isCancellingGoal = false,
    this.celebration,
    this.notice,
  });

  /// Shared unlocks earned up to the current household level. A getter rather
  /// than a field, for the same reason [EconomyP1State.unlocks] is one.
  List<String> get unlocks => householdProgress.unlocks;

  /// Whether the «Hogar» section should render at all.
  bool get isVisible => enabled && status != HouseholdEconomyStatus.initial;

  /// XP still needed for the next shared level — the «200 XP para nivel 6»
  /// figure UX-P1-SPEC §4 asks the household card to show.
  int get xpToNextLevel => householdProgress.xpToNextLevel;

  /// Whether the viewer may dissolve the goal: its creator, or an admin.
  ///
  /// The same rule the backend enforces. Duplicated deliberately — the
  /// backend's copy is the one that decides, this one only decides whether to
  /// OFFER the button, and a button that 403s on tap is worse than no button.
  bool get canCancelGoal {
    final goal = activeSavingsGoal;
    if (goal == null) return false;
    return currentUserIsAdmin || goal.createdBy == currentUserId;
  }

  GoalCreateUnavailableReason get createGoalReason {
    if (!enabled) return GoalCreateUnavailableReason.flagOff;
    if (isCreatingGoal) return GoalCreateUnavailableReason.inFlight;
    // An UNLOCKED goal is not an active one, so it does not block a new goal
    // server-side either: the partial unique index only covers `active`.
    final goal = activeSavingsGoal;
    if (goal != null && goal.isActive) {
      return GoalCreateUnavailableReason.goalExists;
    }
    if (!isOnline) return GoalCreateUnavailableReason.offline;
    return GoalCreateUnavailableReason.none;
  }

  bool get canCreateGoal =>
      createGoalReason == GoalCreateUnavailableReason.none;

  GoalCancelUnavailableReason get cancelGoalReason {
    if (!enabled) return GoalCancelUnavailableReason.flagOff;
    if (isCancellingGoal) return GoalCancelUnavailableReason.inFlight;
    final goal = activeSavingsGoal;
    if (goal == null) return GoalCancelUnavailableReason.noGoal;
    if (!goal.isActive) return GoalCancelUnavailableReason.goalInactive;
    if (!canCancelGoal) return GoalCancelUnavailableReason.notAllowed;
    if (!isOnline) return GoalCancelUnavailableReason.offline;
    return GoalCancelUnavailableReason.none;
  }

  bool get canCancel => cancelGoalReason == GoalCancelUnavailableReason.none;

  /// Nullable fields use explicit `clearX` sentinels rather than
  /// unconditional assignment — the TD-056 fix. Without them a `copyWith()`
  /// that did not mention [error] would keep a stale one alive forever, and
  /// one that meant to clear it could not say so.
  HouseholdEconomyState copyWith({
    HouseholdEconomyStatus? status,
    bool? enabled,
    ProgressP1? householdProgress,
    List<HouseholdMemberProgress>? members,
    SavingsGoal? activeSavingsGoal,
    bool clearGoal = false,
    String? currentUserId,
    bool? currentUserIsAdmin,
    DateTime? refreshedAt,
    bool? isStale,
    String? error,
    bool clearError = false,
    String? actionError,
    bool clearActionError = false,
    bool? isOnline,
    bool? isCreatingGoal,
    bool? isCancellingGoal,
    HouseholdEconomyNotice? celebration,
    bool clearCelebration = false,
    HouseholdEconomyNotice? notice,
    bool clearNotice = false,
  }) =>
      HouseholdEconomyState(
        status: status ?? this.status,
        enabled: enabled ?? this.enabled,
        householdProgress: householdProgress ?? this.householdProgress,
        members: members ?? this.members,
        activeSavingsGoal:
            clearGoal ? null : (activeSavingsGoal ?? this.activeSavingsGoal),
        currentUserId: currentUserId ?? this.currentUserId,
        currentUserIsAdmin: currentUserIsAdmin ?? this.currentUserIsAdmin,
        refreshedAt: refreshedAt ?? this.refreshedAt,
        isStale: isStale ?? this.isStale,
        error: clearError ? null : (error ?? this.error),
        actionError: clearActionError ? null : (actionError ?? this.actionError),
        isOnline: isOnline ?? this.isOnline,
        isCreatingGoal: isCreatingGoal ?? this.isCreatingGoal,
        isCancellingGoal: isCancellingGoal ?? this.isCancellingGoal,
        celebration: clearCelebration ? null : (celebration ?? this.celebration),
        notice: clearNotice ? null : (notice ?? this.notice),
      );

  @override
  List<Object?> get props => [
        status,
        enabled,
        householdProgress,
        members,
        activeSavingsGoal,
        currentUserId,
        currentUserIsAdmin,
        refreshedAt,
        isStale,
        error,
        actionError,
        isOnline,
        isCreatingGoal,
        isCancellingGoal,
        celebration,
        notice,
      ];
}

/// «Hogar» — the cooperative half of the P1 economy (TD-066 F3).
///
/// ── Why a second cubit rather than fields on EconomyP1Cubit ──────────────
/// The two halves have different AUDIENCES, and the split is the privacy
/// boundary made structural. Personal state arrives on `user_<id>` and must
/// never be broadcast; shared state arrives on `household_<id>` and is seen by
/// everyone. Keeping them in one state object would put a wallet balance one
/// careless `copyWith` away from a widget that renders the household roster.
///
/// ── Socket events apply their own payload ────────────────────────────────
/// Every household event carries what it changed, so the state takes it
/// directly instead of refetching — the same rule F2 follows, for the same
/// reason: a busy evening in a shared household would otherwise become a
/// burst of identical GETs. An event this build does not recognise is the one
/// case that DOES refetch: an unknown name means the server is ahead of the
/// app.
///
/// ── What no event can keep fresh ─────────────────────────────────────────
/// A housemate's own level and XP. `economy:level_up` is personal-room only,
/// so THIS device never hears about anyone else's; the household room only
/// carries the pooled `household:xp_updated`, which does not say who earned
/// it. The roster's per-member figures therefore move on the next read (the
/// Mascota tab refreshes on entry), not on the event — see the PR's Proposed
/// Improvements for the shape a fix would take.
///
/// ── Which writes live here, and which do not ─────────────────────────────
/// Opening a goal and cancelling one do (TD-066 F4): both act on a HOUSEHOLD
/// resource and neither needs a wallet balance to decide anything. The third,
/// contributing, lives on EconomyP1Cubit instead — it is a debit that has to
/// be validated against a live personal balance, which only that cubit has.
/// It hands the resulting goal back through [applyGoal].
///
/// Neither write is ever queued offline. PDR-018 makes a goal real money —
/// cancelling one moves coins back into several wallets — and TD-066-DESIGN
/// §7 rules out queueing any of it until offline compensation is designed.
class HouseholdEconomyCubit extends Cubit<HouseholdEconomyState> {
  final EconomyP1Repository _repo;
  final DeviceTimeZoneService _timeZone;
  final ConnectivityService _connectivity;
  final Uuid _uuid;

  StreamSubscription<bool>? _connectivitySub;

  String? _householdId;

  /// The in-flight refresh, so concurrent callers coalesce onto one request
  /// instead of racing (the single-flight shape TimelineCubit uses).
  Future<void>? _inFlight;

  int _noticeSequence = 0;

  /// Bumped whenever the state this cubit describes stops being the one an
  /// in-flight request was started for — a logout, or a switch to another
  /// household. A response that comes back against an old generation is
  /// dropped rather than emitted. Same guard EconomyP1Cubit uses.
  int _generation = 0;

  HouseholdEconomyCubit(
    this._repo, {
    DeviceTimeZoneService? timeZone,
    ConnectivityService? connectivity,
    Uuid? uuid,
  })  : _timeZone = timeZone ?? DeviceTimeZoneService(),
        _connectivity = connectivity ?? ConnectivityService(),
        _uuid = uuid ?? const Uuid(),
        super(const HouseholdEconomyState()) {
    _connectivitySub = _connectivity.isOnline.listen((online) {
      if (isClosed) return;
      emit(state.copyWith(isOnline: online));
    });
  }

  @override
  Future<void> close() {
    _connectivitySub?.cancel();
    return super.close();
  }

  /// Reset to a blank state on logout or session expiry (TD-055/TD-058).
  ///
  /// Household XP is not private, but the roster names are, and the next
  /// account must not open the app on the previous one's household.
  void reset() {
    if (isClosed) return;
    _householdId = null;
    _inFlight = null;
    _generation++;
    emit(const HouseholdEconomyState());
  }

  /// Load the shared economy for [householdId].
  ///
  /// [currentUserId] is what lets the savings breakdown say «Tú» for one of
  /// its rows. Optional rather than required: the section is worth rendering
  /// before the profile has resolved, and a missing id costs one label, not
  /// the whole read.
  ///
  /// [isAdmin] decides only whether «Cancelar meta» is OFFERED — the backend
  /// is the authority and refuses a cancel from anyone else with a 403, so a
  /// stale value here costs a button, never a permission.
  Future<void> load(
    String householdId, {
    String? currentUserId,
    bool? isAdmin,
  }) async {
    // Switching households: nothing from the previous one may survive, and
    // its in-flight response must not land here. Deliberately not done on the
    // FIRST load — emitting a blank state equal to the initial one would
    // still be a real emission, since bloc only suppresses equal states after
    // the first.
    if (_householdId != null && _householdId != householdId) {
      _generation++;
      _inFlight = null;
      emit(const HouseholdEconomyState());
    }
    _householdId = householdId;

    if (!isClosed && (currentUserId != null || isAdmin != null)) {
      emit(state.copyWith(
        currentUserId: currentUserId,
        currentUserIsAdmin: isAdmin,
      ));
    }

    final cached = _repo.cached(householdId);
    if (cached != null && !isClosed) {
      emit(_applySnapshot(state, cached, isStale: true).copyWith(
        status: HouseholdEconomyStatus.ready,
      ));
    } else if (!isClosed) {
      emit(state.copyWith(
        status: HouseholdEconomyStatus.loading,
        clearError: true,
      ));
    }

    return refresh();
  }

  /// Refetch, coalescing concurrent callers onto one request.
  Future<void> refresh() {
    final existing = _inFlight;
    if (existing != null) return existing;

    final future = _refresh().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<void> _refresh() async {
    final householdId = _householdId;
    if (householdId == null) return;
    final generation = _generation;

    try {
      final timeZone = await _timeZone.resolve();
      final economy = await _repo.load(householdId, timeZone: timeZone);
      if (isClosed || generation != _generation) return;

      emit(_applySnapshot(
        state,
        economy,
        isStale: _repo.lastLoadWasFromCache,
      ).copyWith(status: HouseholdEconomyStatus.ready, clearError: true));
    } catch (e) {
      if (isClosed || generation != _generation) return;
      // Only fatal when there was nothing to show. With content already on
      // screen a failed refresh is staleness, not an error state.
      if (state.status == HouseholdEconomyStatus.ready) {
        emit(state.copyWith(isStale: true));
      } else {
        emit(state.copyWith(
          status: HouseholdEconomyStatus.failure,
          error: _messageFor(e),
        ));
      }
    }
  }

  HouseholdEconomyState _applySnapshot(
    HouseholdEconomyState base,
    EconomyP1 economy, {
    required bool isStale,
  }) {
    final household = economy.household;
    return base.copyWith(
      // `EconomyP1.enabled` requires BOTH halves to report on. They come from
      // two requests and could disagree mid-activation; treating that as off
      // keeps the UI from rendering half a feature.
      enabled: economy.enabled,
      householdProgress: household.householdProgress,
      members: household.members,
      activeSavingsGoal: household.activeSavingsGoal,
      // A read is authoritative about whether a goal exists at all: it is the
      // only thing that can tell us one was cancelled while the app was shut.
      clearGoal: household.activeSavingsGoal == null,
      refreshedAt: economy.refreshedAt,
      isStale: isStale,
    );
  }

  // ── Realtime ────────────────────────────────────────────────────────────

  /// Apply one household-room socket event (CLAUDE.md's `household:*` table).
  void applyRealtime(String event, dynamic data) {
    if (isClosed) return;

    // An event for a household whose snapshot has not loaded — or whose flag
    // this build still believes is off — means the local picture is behind the
    // server's. That is the one case worth a round trip: activation just
    // happened, and no payload can describe the rest of the structure.
    if (state.status != HouseholdEconomyStatus.ready || !state.enabled) {
      unawaited(refresh());
      return;
    }

    final json = _payload(data);

    switch (event) {
      case 'household:xp_updated':
        _applyXpUpdated(json);
      case 'household:level_up':
        _applyLevelUp(json);
      case 'household:milestone':
        _applyMilestone(json);
      case 'household:savings_goal_created':
        _applyGoalCreated(json);
      case 'household:savings_contribution':
        _applyContribution(json);
      case 'household:savings_goal_unlocked':
        _applyGoalUnlocked(json);
      case 'household:savings_goal_cancelled':
        _applyGoalCancelled();
      default:
        // A name this build does not know. The server is ahead of the app;
        // refetching is the only honest response.
        unawaited(refresh());
    }
  }

  /// `{ householdXp, level }` — the pooled XP moved.
  ///
  /// The payload carries a total, not a delta, so the delta is computed here
  /// to advance the level bar. The bar's SIZE (`xpForNextLevel`) is not
  /// recomputed: the level curve lives on the server, and inferring it would
  /// draw progress against a made-up total.
  ///
  /// When the payload's level differs from the one on screen, this completion
  /// also crossed a level. `household:level_up` follows immediately with the
  /// unlocks, and both agree on the reset — the bar restarts at zero rather
  /// than briefly rendering the old level's fill against the new level.
  void _applyXpUpdated(Map<String, dynamic> json) {
    final progress = state.householdProgress;
    final xp = _int(json['householdXp'], progress.xp);
    final level = _int(json['level'], progress.level);
    final gained = _atLeastZero(xp - progress.xp);
    final levelChanged = level != progress.level;

    emit(state.copyWith(
      householdProgress: ProgressP1(
        xp: xp,
        level: level,
        unlocks: progress.unlocks,
        tasksCompleted: progress.tasksCompleted + 1,
        xpIntoLevel: levelChanged ? 0 : progress.xpIntoLevel + gained,
        xpForNextLevel: progress.xpForNextLevel,
        xpToNextLevel: levelChanged
            ? progress.xpForNextLevel
            : _atLeastZero(progress.xpToNextLevel - gained),
      ),
    ));
  }

  /// `{ track, level, previousLevel, xp, unlocks[] }`.
  ///
  /// Guarded on `track` for symmetry with the personal handler: the two
  /// tracks travel under different event names on different rooms, so a
  /// mix-up should be impossible — and a shared level-up moving a personal
  /// ring is exactly the bug worth making impossible twice.
  void _applyLevelUp(Map<String, dynamic> json) {
    if (json['track'] == 'personal') return;

    final progress = state.householdProgress;
    final level = _int(json['level'], progress.level);
    final unlocks = _strings(json['unlocks']);

    emit(state.copyWith(
      householdProgress: ProgressP1(
        xp: _int(json['xp'], progress.xp),
        level: level,
        // Unlocks are cumulative up to the level; the event carries the full
        // list, so it replaces rather than appends.
        unlocks: unlocks.isEmpty ? progress.unlocks : unlocks,
        tasksCompleted: progress.tasksCompleted,
        // The new level restarts the bar. Its size is unknown until the next
        // read, and guessing it would draw progress against a made-up total.
        xpIntoLevel: 0,
        xpForNextLevel: progress.xpForNextLevel,
        xpToNextLevel: progress.xpForNextLevel,
      ),
      celebration: _nextNotice(
        HouseholdNoticeKind.levelUp,
        'Lo habéis conseguido juntos: nivel de hogar $level.',
        unlocks: unlocks,
        level: level,
      ),
    ));
  }

  /// `{ kind: 'tasks_completed', value, total }` — 25/100/250/750 crossed.
  ///
  /// `total` is authoritative, so it corrects the count [_applyXpUpdated]
  /// increments optimistically.
  void _applyMilestone(Map<String, dynamic> json) {
    final progress = state.householdProgress;
    final value = _int(json['value']);
    final total = _int(json['total'], progress.tasksCompleted);

    emit(state.copyWith(
      householdProgress: ProgressP1(
        xp: progress.xp,
        level: progress.level,
        unlocks: progress.unlocks,
        tasksCompleted: total,
        xpIntoLevel: progress.xpIntoLevel,
        xpForNextLevel: progress.xpForNextLevel,
        xpToNextLevel: progress.xpToNextLevel,
      ),
      notice: _nextNotice(
        HouseholdNoticeKind.milestone,
        '$value tareas completadas entre todos. Cada una contó.',
        value: value,
      ),
    ));
  }

  /// The whole goal document (PDR-018). A brand-new goal has no
  /// contributions yet, so taking the payload verbatim loses nothing.
  void _applyGoalCreated(Map<String, dynamic> json) {
    emit(state.copyWith(activeSavingsGoal: SavingsGoal.fromJson(json)));
  }

  /// `{ goalId, userId, amount, contributedCoins, targetCoins }`.
  ///
  /// `amount` is the increment this contribution added, while
  /// `contributedCoins` is the goal's new total — so the total is taken
  /// verbatim and only the contributor's own line is incremented.
  ///
  /// The breakdown's ORDER is preserved and a first-time contributor is
  /// appended, never inserted by size. UX-P1-SPEC §8 requires contributions
  /// be shown «nunca ordenadas ni comparadas como ranking», and re-sorting
  /// «Tú: 40 · Ana: 28» by amount is the whole of what building a leaderboard
  /// would take.
  void _applyContribution(Map<String, dynamic> json) {
    final goal = state.activeSavingsGoal;
    final goalId = (json['goalId'] ?? '').toString();

    // A contribution to a goal this build has never seen. The server knows
    // about a goal we do not, which no payload can reconstruct — it carries
    // the totals but not the item, the price or who opened it.
    if (goal == null || goal.id != goalId) {
      unawaited(refresh());
      return;
    }

    final userId = (json['userId'] ?? '').toString();
    final amount = _int(json['amount']);

    final contributions = <SavingsContributor>[];
    var matched = false;
    for (final c in goal.contributions) {
      if (c.userId == userId) {
        matched = true;
        contributions.add(SavingsContributor(
          userId: c.userId,
          name: c.name,
          amount: c.amount + amount,
        ));
      } else {
        contributions.add(c);
      }
    }
    if (!matched) {
      // The payload carries no name — it is a household event about coins,
      // not a roster update — so the roster is where the name comes from. An
      // unknown member renders nameless rather than having their contribution
      // dropped, which would silently make the breakdown stop adding up to
      // the total printed beside it.
      contributions.add(SavingsContributor(
        userId: userId,
        name: _memberName(userId),
        amount: amount,
      ));
    }

    emit(state.copyWith(
      activeSavingsGoal: SavingsGoal(
        id: goal.id,
        itemType: goal.itemType,
        itemId: goal.itemId,
        targetCoins: _int(json['targetCoins'], goal.targetCoins),
        contributedCoins: _int(json['contributedCoins'], goal.contributedCoins),
        status: goal.status,
        createdBy: goal.createdBy,
        contributions: contributions,
      ),
    ));
  }

  /// The whole goal document again, now `status: 'unlocked'`.
  ///
  /// Merged rather than replaced: the document carries no `contributions`
  /// array — that breakdown is assembled by the read endpoint from a separate
  /// collection — so applying the payload verbatim would blank «Tú: 40 ·
  /// Ana: 28» at the exact moment the household is looking at it.
  void _applyGoalUnlocked(Map<String, dynamic> json) {
    final incoming = SavingsGoal.fromJson(json);
    final goal = state.activeSavingsGoal;

    emit(state.copyWith(
      activeSavingsGoal: SavingsGoal(
        id: incoming.id,
        itemType: incoming.itemType,
        itemId: incoming.itemId,
        targetCoins: incoming.targetCoins,
        contributedCoins: incoming.contributedCoins,
        status: incoming.status,
        createdBy: incoming.createdBy,
        contributions: incoming.contributions.isNotEmpty
            ? incoming.contributions
            : (goal != null && goal.id == incoming.id
                ? goal.contributions
                : const []),
      ),
      celebration: _nextNotice(
        HouseholdNoticeKind.goalUnlocked,
        'Lo habéis conseguido juntos: vuestra meta está desbloqueada.',
      ),
    ));
  }

  /// `{ goal, refunds[] }` — the goal is gone and every coin went back.
  ///
  /// The payload is deliberately unread: `refunds[]` is a per-member list of
  /// amounts, and the only figure worth showing is how much came back to YOU.
  /// That arrives privately as `economy:savings_refunded` on the personal
  /// room, where EconomyP1Cubit turns it into a notice. Reading the array
  /// here would mean holding — one careless render away from displaying —
  /// what each housemate had put in, at the moment they got it back.
  void _applyGoalCancelled() {
    emit(state.copyWith(clearGoal: true));
  }

  /// A roster name for [userId], or the empty string when this build has not
  /// seen them (a member who joined since the last read).
  String _memberName(String userId) {
    for (final member in state.members) {
      if (member.userId == userId) return member.name;
    }
    return '';
  }

  HouseholdEconomyNotice _nextNotice(
    HouseholdNoticeKind kind,
    String message, {
    List<String> unlocks = const [],
    int level = 0,
    int value = 0,
  }) {
    _noticeSequence++;
    return HouseholdEconomyNotice(
      kind: kind,
      message: message,
      sequence: _noticeSequence,
      unlocks: unlocks,
      level: level,
      value: value,
    );
  }

  // ── Writes (TD-066 F4) ──────────────────────────────────────────────────

  /// Adopt a goal produced by a write, wherever it was performed.
  ///
  /// Public because the third savings write — contributing — happens on
  /// EconomyP1Cubit, which owns the wallet it debits; the composition root
  /// wires its `onGoalChanged` to this. Idempotent by construction: a goal is
  /// replaced wholesale, so applying the same one twice (the HTTP response
  /// and then the socket echo) lands on the same state.
  ///
  /// A goal that is no longer active is CLEARED rather than kept, with one
  /// exception: an `unlocked` goal lingers so the section can say so until the
  /// next read. A cancelled one has nothing left to show.
  void applyGoal(SavingsGoal goal) {
    if (isClosed) return;
    if (goal.status == 'cancelled') {
      emit(state.copyWith(clearGoal: true));
      return;
    }
    emit(state.copyWith(activeSavingsGoal: goal));
  }

  /// Open the household's one active goal for a catalog item (PDR-018).
  ///
  /// Only `itemType`/`itemId` travel: the PRICE comes from the server-side
  /// catalog. A client that could name its own target would unlock a 40-coin
  /// cosmetic by declaring the target to be 1, and the economy's ceiling
  /// would be decorative.
  Future<void> createGoal({
    required String itemType,
    required String itemId,
  }) async {
    final householdId = _householdId;
    if (householdId == null || isClosed) return;
    if (!state.canCreateGoal) return;

    // Re-checked on the hot path: `state.isOnline` follows a stream that can
    // lag a transition, and everything downstream of this is money.
    final online = await _connectivity.checkConnectivity();
    if (isClosed) return;
    if (!online) {
      emit(state.copyWith(
        actionError: 'Sin conexión: no se puede crear una meta ahora.',
      ));
      return;
    }

    emit(state.copyWith(isCreatingGoal: true, clearActionError: true));

    // One id per logical creation, reused across whatever retries happen
    // inside ApiService, so a timeout that actually reached the server
    // replays instead of opening a second goal.
    final operationId = _uuid.v4();

    try {
      final goal = await _repo.createSavingsGoal(
        householdId,
        itemType: itemType,
        itemId: itemId,
        operationId: operationId,
      );
      if (isClosed) return;
      emit(state.copyWith(isCreatingGoal: false, activeSavingsGoal: goal));
    } catch (e) {
      if (isClosed) return;
      emit(state.copyWith(
        isCreatingGoal: false,
        actionError: _createMessageFor(e),
      ));
      // A 409 means the household already has a goal this build has not seen
      // — someone else opened one seconds ago. Refetching is what makes the
      // section show THEIR goal instead of leaving the create button up.
      if (e is ConflictFailure) unawaited(refresh());
    }
  }

  /// Cancel the active goal and refund every contributor (PDR-018).
  ///
  /// The refunds are the server's work, inside one transaction: this only
  /// asks. Each contributor learns what came back to them privately, through
  /// `economy:savings_refunded` on their own room — nothing about the amounts
  /// is announced to the household.
  Future<void> cancelGoal() async {
    final householdId = _householdId;
    final goal = state.activeSavingsGoal;
    if (householdId == null || goal == null || isClosed) return;
    if (!state.canCancel) return;

    final online = await _connectivity.checkConnectivity();
    if (isClosed) return;
    if (!online) {
      emit(state.copyWith(
        actionError: 'Sin conexión: no se puede cancelar la meta ahora.',
      ));
      return;
    }

    emit(state.copyWith(isCancellingGoal: true, clearActionError: true));

    // Minted once per logical cancel, not per attempt: cancelling writes a
    // refund entry per contributor, so a replay under a fresh key would be a
    // second set of refunds.
    final operationId = _uuid.v4();

    try {
      await _repo.cancelSavingsGoal(
        householdId,
        goal.id,
        operationId: operationId,
      );
      if (isClosed) return;
      emit(state.copyWith(isCancellingGoal: false, clearGoal: true));
    } catch (e) {
      if (isClosed) return;
      emit(state.copyWith(
        isCancellingGoal: false,
        actionError: _cancelMessageFor(e),
      ));
      // Already cancelled or already unlocked elsewhere: the local picture is
      // behind, and only a read can say which.
      if (e is ConflictFailure) unawaited(refresh());
    }
  }

  void clearActionError() {
    if (isClosed) return;
    emit(state.copyWith(clearActionError: true));
  }

  /// What to tell the household when opening a goal is refused.
  ///
  /// Authored here rather than passed through: the backend's messages in this
  /// area are English («Unknown cosmetic: x») while the app is Spanish
  /// throughout, and `ApiService` flattens every 409 into a generic
  /// "operation already in progress" that would be actively wrong for the
  /// case that actually happens — a housemate opening a goal first.
  String _createMessageFor(Object error) {
    if (error is ConflictFailure) {
      return 'Vuestro hogar ya tiene una meta activa.';
    }
    if (error is NetworkFailure) {
      return 'Sin conexión: no se pudo crear la meta.';
    }
    // 400 is what `priceOfItem` throws for an item the catalog does not know.
    // It is reachable in practice because the client's catalog is a hand-kept
    // mirror of the server's (see pet_config.dart), so the two can drift.
    if (error is ServerFailure && error.statusCode == 400) {
      return 'Ese artículo ya no está disponible. Actualiza la app y prueba otro.';
    }
    return 'No se pudo crear la meta. Inténtalo de nuevo.';
  }

  String _cancelMessageFor(Object error) {
    if (error is ConflictFailure) {
      return 'Esta meta ya no está activa.';
    }
    if (error is NetworkFailure) {
      return 'Sin conexión: no se pudo cancelar la meta.';
    }
    if (error is ServerFailure && error.statusCode == 403) {
      return 'Solo quien creó la meta o un admin puede cancelarla.';
    }
    if (error is ServerFailure && error.statusCode == 404) {
      return 'Esa meta ya no existe.';
    }
    return 'No se pudo cancelar la meta. Inténtalo de nuevo.';
  }

  void dismissCelebration() {
    if (isClosed) return;
    emit(state.copyWith(clearCelebration: true));
  }

  void dismissNotice() {
    if (isClosed) return;
    emit(state.copyWith(clearNotice: true));
  }

  /// ApiService already maps status codes to typed, human-readable failures,
  /// so the message it carries is the one to show.
  String _messageFor(Object error) {
    if (error is Failure) return error.message;
    return 'No se pudo cargar el progreso del hogar.';
  }
}

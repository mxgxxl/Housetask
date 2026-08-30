import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors/failures.dart';
import '../../data/models/economy_p1/economy_p1.dart';
import '../../data/repositories/economy_p1_repository.dart';
import '../../services/connectivity_service.dart';
import '../../services/device_timezone_service.dart';

/// What one streak ice costs, and how many a member may hold (UX-P1-SPEC §5).
///
/// Duplicated from the server's `economy-p1.ts` on purpose for now: no P1
/// endpoint exposes the catalog, and the button needs a price to grey itself
/// out before the member taps. The server remains the authority — a purchase
/// that disagrees with these numbers is refused there, not here — so the
/// worst case is a button that looks wrong for one refresh. See the PR's
/// Proposed Improvements: these belong in the `/p1/me` payload.
const int kIcePriceCoins = 20;
const int kMaxIceReserve = 2;

// ── Payload readers ────────────────────────────────────────────────────────
// Socket payloads are `dynamic` and arrive from the network. They get the
// same defensive treatment the F1 models give HTTP bodies: a malformed field
// yields a default rather than throwing, because a socket frame must never be
// able to crash the tab it updates.

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

/// Floor at zero. Written out rather than `clamp`, whose static return type
/// on `int` depends on a special case in the type system that is easy to
/// trip over when one operand stops being an `int`.
int _atLeastZero(int value) => value < 0 ? 0 : value;

/// Which kind of thing just happened, so the UI can pick modal vs banner
/// without re-deriving it from copy (UX-P1-SPEC §3's celebration hierarchy).
enum EconomyP1NoticeKind {
  levelUp,
  milestone,
  streakMilestone,
  iceConsumed,
  iceRefunded,
  streakBroken,
}

/// One thing worth telling the member about.
///
/// [sequence] exists because the state is Equatable: two identical notices in
/// a row — the same milestone hit twice across a reconnect, say — would
/// otherwise compare equal and the second would never reach the UI. A
/// monotonic counter makes every notice a distinct state.
class EconomyP1Notice extends Equatable {
  final EconomyP1NoticeKind kind;
  final String message;

  /// Unlocks announced with a level-up; empty for every other kind.
  final List<String> unlocks;

  /// The level reached, for [EconomyP1NoticeKind.levelUp].
  final int level;

  /// The milestone value crossed, for milestone kinds.
  final int value;

  final int sequence;

  const EconomyP1Notice({
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

/// Why the "comprar hielo" button is not available.
///
/// The four the owner specified are [flagOff], [reserveFull],
/// [insufficientCoins] and [offline]; [inFlight] is the ordinary
/// double-tap guard and [noHousehold] only occurs before the first load.
enum IceUnavailableReason {
  none,
  flagOff,
  reserveFull,
  insufficientCoins,
  offline,
  inFlight,
  noHousehold,
}

enum EconomyP1Status { initial, loading, ready, failure }

/// Everything "Mi progreso" renders (TD-066 F2).
///
/// Personal only. The household half of the snapshot is deliberately absent:
/// F3 and F4 add it, and holding a field no widget reads would invite one to
/// be rendered before the section that owns it exists.
class EconomyP1State extends Equatable {
  final EconomyP1Status status;

  /// False while P1 is off for this household — every household today.
  ///
  /// When false the section renders NOTHING. The backend answers a complete
  /// zeroed structure rather than a 404, so a UI that trusted the numbers
  /// would show a real-looking wallet of 0 🪙 and a dead streak to a member
  /// whose economy simply has not been switched on.
  final bool enabled;

  final WalletPersonal wallet;
  final PersonalBudget weeklyBudget;
  final PersonalStreak streak;
  final ProgressP1 personalProgress;

  /// When the snapshot behind this state was fetched.
  final DateTime? refreshedAt;

  /// The content came from cache because the network could not be reached.
  /// Never an error: stale content beats an empty screen (TD-064's pattern).
  final bool isStale;

  final bool isOnline;
  final bool isBuyingIce;

  /// A failed LOAD. Fatal to the section.
  final String? error;

  /// A failed WRITE — a refused ice purchase. Shown in a snackbar and
  /// deliberately separate from [error]: the section keeps rendering.
  final String? actionError;

  /// Modal-class: a personal level-up or a task milestone.
  final EconomyP1Notice? celebration;

  /// Banner-class: ice consumed/refunded, streak broken, streak milestone.
  final EconomyP1Notice? notice;

  const EconomyP1State({
    this.status = EconomyP1Status.initial,
    this.enabled = false,
    this.wallet = const WalletPersonal(),
    this.weeklyBudget = const PersonalBudget(),
    this.streak = const PersonalStreak(),
    this.personalProgress = const ProgressP1(),
    this.refreshedAt,
    this.isStale = false,
    this.isOnline = true,
    this.isBuyingIce = false,
    this.error,
    this.actionError,
    this.celebration,
    this.notice,
  });

  /// Unlocks earned up to the current level.
  ///
  /// A getter, not a field: they already live on [personalProgress], and two
  /// copies would be two things to keep in step across ten socket events.
  List<String> get unlocks => personalProgress.unlocks;

  /// Whether "Mi progreso" should render at all.
  bool get isVisible => enabled && status != EconomyP1Status.initial;

  /// Sunday (PDR-013): nothing new was released, but the week's unspent
  /// remainder is still claimable. The two conditions together are what
  /// distinguishes a rest day from a week that is simply exhausted.
  bool get isRestDay => wallet.dailyReleased == 0 && wallet.remaining > 0;

  /// The week is spent AND nothing new released — not a rest day, just done.
  bool get isExhausted => wallet.dailyReleased == 0 && wallet.remaining <= 0;

  IceUnavailableReason get iceUnavailableReason {
    if (!enabled) return IceUnavailableReason.flagOff;
    if (isBuyingIce) return IceUnavailableReason.inFlight;
    if (streak.iceReserve >= kMaxIceReserve) return IceUnavailableReason.reserveFull;
    if (wallet.balance < kIcePriceCoins) return IceUnavailableReason.insufficientCoins;
    if (!isOnline) return IceUnavailableReason.offline;
    return IceUnavailableReason.none;
  }

  bool get canBuyIce => iceUnavailableReason == IceUnavailableReason.none;

  /// Nullable fields use explicit `clearX` sentinels rather than
  /// unconditional assignment — the TD-056 fix. Without them, any
  /// `copyWith()` that did not mention [error] would silently keep a stale
  /// one alive forever, and one that meant to clear it could not say so.
  EconomyP1State copyWith({
    EconomyP1Status? status,
    bool? enabled,
    WalletPersonal? wallet,
    PersonalBudget? weeklyBudget,
    PersonalStreak? streak,
    ProgressP1? personalProgress,
    DateTime? refreshedAt,
    bool? isStale,
    bool? isOnline,
    bool? isBuyingIce,
    String? error,
    bool clearError = false,
    String? actionError,
    bool clearActionError = false,
    EconomyP1Notice? celebration,
    bool clearCelebration = false,
    EconomyP1Notice? notice,
    bool clearNotice = false,
  }) =>
      EconomyP1State(
        status: status ?? this.status,
        enabled: enabled ?? this.enabled,
        wallet: wallet ?? this.wallet,
        weeklyBudget: weeklyBudget ?? this.weeklyBudget,
        streak: streak ?? this.streak,
        personalProgress: personalProgress ?? this.personalProgress,
        refreshedAt: refreshedAt ?? this.refreshedAt,
        isStale: isStale ?? this.isStale,
        isOnline: isOnline ?? this.isOnline,
        isBuyingIce: isBuyingIce ?? this.isBuyingIce,
        error: clearError ? null : (error ?? this.error),
        actionError: clearActionError ? null : (actionError ?? this.actionError),
        celebration: clearCelebration ? null : (celebration ?? this.celebration),
        notice: clearNotice ? null : (notice ?? this.notice),
      );

  @override
  List<Object?> get props => [
        status,
        enabled,
        wallet,
        weeklyBudget,
        streak,
        personalProgress,
        refreshedAt,
        isStale,
        isOnline,
        isBuyingIce,
        error,
        actionError,
        celebration,
        notice,
      ];
}

/// "Mi progreso" — the personal half of the P1 economy (TD-066 F2).
///
/// ── Socket events apply their own payload ────────────────────────────────
/// Every personal event carries the value it changed, so the state takes it
/// directly instead of refetching. Ten events firing ten GETs would make a
/// busy evening in a shared household a burst of identical requests, and the
/// member would watch the flame lag a second behind their own tap. An event
/// this cubit does not recognise is the one case that DOES refetch: an
/// unknown name means the server knows something this build does not.
///
/// ── Writes never queue ───────────────────────────────────────────────────
/// Buying an ice is a debit. TD-066-DESIGN §7 is explicit that contributing,
/// cancelling and buying must not be queued until their offline compensation
/// is designed, because a debit replayed under last-write-wins can charge
/// twice for one tap. Offline, the button is disabled and a failed purchase
/// surfaces as a message — never as a pending operation.
class EconomyP1Cubit extends Cubit<EconomyP1State> {
  final EconomyP1Repository _repo;
  final DeviceTimeZoneService _timeZone;
  final ConnectivityService _connectivity;
  final Uuid _uuid;

  String? _householdId;

  /// The in-flight refresh, so concurrent callers coalesce onto one request
  /// instead of racing (the single-flight shape TimelineCubit uses).
  Future<void>? _inFlight;

  StreamSubscription<bool>? _connectivitySub;
  int _noticeSequence = 0;

  /// Bumped whenever the state this cubit describes stops being the one an
  /// in-flight request was started for — a logout, or a switch to another
  /// household. A response that comes back against an old generation is
  /// dropped rather than emitted: without this, logging out and straight
  /// back in as someone else would let the previous member's wallet land on
  /// the new session's screen. Same guard TimelineCubit uses.
  int _generation = 0;

  EconomyP1Cubit(
    this._repo, {
    DeviceTimeZoneService? timeZone,
    ConnectivityService? connectivity,
    Uuid? uuid,
  })  : _timeZone = timeZone ?? DeviceTimeZoneService(),
        _connectivity = connectivity ?? ConnectivityService(),
        _uuid = uuid ?? const Uuid(),
        super(const EconomyP1State()) {
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
  /// A wallet and a streak are personal data; leaving them on screen while
  /// the next account logs in is the leak SessionListeners exists to stop.
  void reset() {
    if (isClosed) return;
    _householdId = null;
    _inFlight = null;
    _generation++;
    emit(const EconomyP1State());
  }

  /// Load the personal economy for [householdId].
  ///
  /// Paints the cached snapshot first when there is one, so the tab opens on
  /// content rather than a spinner, then refreshes over it.
  Future<void> load(String householdId) async {
    // Switching households: nothing from the previous one may survive, and
    // its in-flight response must not land here. Deliberately not done on the
    // FIRST load — emitting a blank state equal to the initial one would
    // still be a real emission, since bloc only suppresses equal states after
    // the first.
    if (_householdId != null && _householdId != householdId) {
      _generation++;
      _inFlight = null;
      emit(const EconomyP1State());
    }
    _householdId = householdId;

    final cached = _repo.cached(householdId);
    if (cached != null && !isClosed) {
      emit(_applySnapshot(state, cached, isStale: true).copyWith(
        status: EconomyP1Status.ready,
      ));
    } else if (!isClosed) {
      emit(state.copyWith(status: EconomyP1Status.loading, clearError: true));
    }

    return refresh();
  }

  /// Refetch, coalescing concurrent callers onto one request.
  ///
  /// Two events arriving together, or a socket reconnect landing on top of a
  /// tab switch, must not become two round trips.
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
      ).copyWith(status: EconomyP1Status.ready, clearError: true));
    } catch (e) {
      if (isClosed || generation != _generation) return;
      // Only fatal when there was nothing to show. With content already on
      // screen a failed refresh is staleness, not an error state.
      if (state.status == EconomyP1Status.ready) {
        emit(state.copyWith(isStale: true));
      } else {
        emit(state.copyWith(
          status: EconomyP1Status.failure,
          error: _messageFor(e),
        ));
      }
    }
  }

  EconomyP1State _applySnapshot(
    EconomyP1State base,
    EconomyP1 economy, {
    required bool isStale,
  }) {
    final personal = economy.personal;
    return base.copyWith(
      // `EconomyP1.enabled` requires BOTH halves to report on. They come from
      // two requests and could disagree mid-activation; treating that as off
      // keeps the UI from rendering half a feature.
      enabled: economy.enabled,
      wallet: personal.wallet,
      weeklyBudget: personal.weeklyBudget,
      streak: personal.streak,
      personalProgress: personal.personalProgress,
      refreshedAt: economy.refreshedAt,
      isStale: isStale,
    );
  }

  // ── Realtime ────────────────────────────────────────────────────────────

  /// Apply one personal-room socket event (CLAUDE.md's `economy:*` table).
  ///
  /// Every branch writes the payload straight into the state. Nothing here
  /// fetches, because the payload IS the update.
  void applyRealtime(String event, dynamic data) {
    if (isClosed) return;

    // An event for a household whose snapshot has not loaded — or whose flag
    // this build still believes is off — means the local picture is behind
    // the server's. That is the one case worth a round trip: activation just
    // happened, and no payload can tell us the rest of the structure.
    if (state.status != EconomyP1Status.ready || !state.enabled) {
      unawaited(refresh());
      return;
    }

    final json = _payload(data);

    switch (event) {
      case 'economy:reward':
        _applyReward(json);
      case 'economy:budget_updated':
        _applyBudgetUpdated(json);
      case 'economy:streak_updated':
        _applyStreakUpdated(json);
      case 'economy:ice_consumed':
        _applyIceConsumed(json);
      case 'economy:ice_refunded':
        _applyIceRefunded(json);
      case 'economy:streak_broken':
        _applyStreakBroken(json);
      case 'economy:streak_milestone':
        _applyStreakMilestone(json);
      case 'economy:ice_purchased':
        _applyIcePurchased(json);
      case 'economy:level_up':
        _applyLevelUp(json);
      case 'economy:milestone':
        _applyMilestone(json);
      default:
        // A name this build does not know. The server is ahead of the app;
        // refetching is the only honest response.
        unawaited(refresh());
    }
  }

  /// A completion paid out: `{ receiptId, coins, personalXp }`.
  ///
  /// Coins move in two directions at once — the wallet grows, and the week's
  /// claimable remainder shrinks by the same amount, because a reward is the
  /// budget being spent on the member. [PersonalStreak] is untouched here:
  /// `economy:streak_updated` follows every completion with its own payload.
  ///
  /// `level` is deliberately NOT recomputed. Levels are server-authoritative
  /// and arrive on `economy:level_up`; inferring one from an XP total would
  /// need the curve, which the client does not have.
  void _applyReward(Map<String, dynamic> json) {
    final coins = _int(json['coins']);
    final personalXp = _int(json['personalXp']);
    final progress = state.personalProgress;

    emit(state.copyWith(
      wallet: WalletPersonal(
        balance: state.wallet.balance + coins,
        dailyReleased: state.wallet.dailyReleased,
        remaining: _atLeastZero(state.wallet.remaining - coins),
      ),
      personalProgress: ProgressP1(
        xp: progress.xp + personalXp,
        level: progress.level,
        unlocks: progress.unlocks,
        tasksCompleted: progress.tasksCompleted + 1,
        xpIntoLevel: progress.xpIntoLevel + personalXp,
        xpForNextLevel: progress.xpForNextLevel,
        xpToNextLevel: _atLeastZero(progress.xpToNextLevel - personalXp),
      ),
    ));
  }

  /// `{ weekKey, remaining, dailyReleased }`.
  ///
  /// `dailyReleased` is 0 on Sunday while `remaining` may not be (PDR-013),
  /// so both are taken verbatim rather than derived from one another.
  void _applyBudgetUpdated(Map<String, dynamic> json) {
    final weekKey = json['weekKey']?.toString();
    emit(state.copyWith(
      wallet: WalletPersonal(
        balance: state.wallet.balance,
        dailyReleased: _int(json['dailyReleased']),
        remaining: _int(json['remaining']),
      ),
      weeklyBudget: weekKey == null || weekKey.isEmpty
          ? state.weeklyBudget
          : _budgetWithWeekKey(weekKey),
    ));
  }

  PersonalBudget _budgetWithWeekKey(String weekKey) {
    final b = state.weeklyBudget;
    return PersonalBudget(
      weekKey: weekKey,
      periodTimeZone: b.periodTimeZone,
      weeklyCap: b.weeklyCap,
      releasedCoins: b.releasedCoins,
      grantedCoins: b.grantedCoins,
      planVersion: b.planVersion,
      allocations: b.allocations,
    );
  }

  /// `{ current, longest, iceReserve }` — fires on every completion.
  void _applyStreakUpdated(Map<String, dynamic> json) {
    emit(state.copyWith(
      streak: PersonalStreak(
        current: _int(json['current'], state.streak.current),
        longest: _int(json['longest'], state.streak.longest),
        iceReserve: _int(json['iceReserve'], state.streak.iceReserve),
        iceMilestonesReached: state.streak.iceMilestonesReached,
      ),
    ));
  }

  /// `{ dayKey, iceReserve, current }` — a missed weekday was covered.
  ///
  /// Copy is UX-P1-SPEC §7 verbatim, flame count included.
  void _applyIceConsumed(Map<String, dynamic> json) {
    final current = _int(json['current'], state.streak.current);
    emit(state.copyWith(
      streak: PersonalStreak(
        current: current,
        longest: state.streak.longest,
        iceReserve: _int(json['iceReserve'], state.streak.iceReserve),
        iceMilestonesReached: state.streak.iceMilestonesReached,
      ),
      notice: _nextNotice(
        EconomyP1NoticeKind.iceConsumed,
        'Ayer fue un día complicado. Un hielo cubrió tu racha 🔥 $current',
      ),
    ));
  }

  /// `{ iceReserve }` — a late offline sync proved activity on a covered day.
  void _applyIceRefunded(Map<String, dynamic> json) {
    emit(state.copyWith(
      streak: PersonalStreak(
        current: state.streak.current,
        longest: state.streak.longest,
        iceReserve: _int(json['iceReserve'], state.streak.iceReserve),
        iceMilestonesReached: state.streak.iceMilestonesReached,
      ),
      notice: _nextNotice(
        EconomyP1NoticeKind.iceRefunded,
        'Sincronizamos actividad de ese día: recuperas tu hielo ❄️',
      ),
    ));
  }

  /// `{ dayKey }` — a weekday passed with no activity and no ice.
  ///
  /// Copy is UX-P1-SPEC §7 verbatim. PDR-019: level, XP and coins are
  /// untouched, and the message says so rather than implying a loss.
  void _applyStreakBroken(Map<String, dynamic> json) {
    emit(state.copyWith(
      streak: PersonalStreak(
        current: 0,
        longest: state.streak.longest,
        iceReserve: state.streak.iceReserve,
        iceMilestonesReached: state.streak.iceMilestonesReached,
      ),
      notice: _nextNotice(
        EconomyP1NoticeKind.streakBroken,
        'La racha se reinicia; tu nivel y tu XP siguen intactos',
      ),
    ));
  }

  /// `{ value, current, iceReserve }` — 7/14/30/50/100 reached, ice earned.
  void _applyStreakMilestone(Map<String, dynamic> json) {
    final streak = state.streak;
    final value = _int(json['value']);
    final current = _int(json['current'], streak.current);
    final reached = streak.iceMilestonesReached;

    emit(state.copyWith(
      streak: PersonalStreak(
        current: current,
        // A milestone is reached by the current run, so it is also the
        // longest one unless an older run went further.
        longest: current > streak.longest ? current : streak.longest,
        iceReserve: _int(json['iceReserve'], streak.iceReserve),
        iceMilestonesReached:
            reached.contains(value) ? reached : [...reached, value],
      ),
      notice: _nextNotice(
        EconomyP1NoticeKind.streakMilestone,
        '¡$value días seguidos! Ganas un hielo ❄️',
        value: value,
      ),
    ));
  }

  /// `{ iceReserve, spent, balance }` — the authoritative echo of a purchase.
  ///
  /// Also arrives when the member bought on another device, which is why the
  /// balance is taken from the payload rather than subtracted locally.
  void _applyIcePurchased(Map<String, dynamic> json) {
    emit(state.copyWith(
      isBuyingIce: false,
      wallet: WalletPersonal(
        balance: _int(json['balance'], state.wallet.balance),
        dailyReleased: state.wallet.dailyReleased,
        remaining: state.wallet.remaining,
      ),
      streak: PersonalStreak(
        current: state.streak.current,
        longest: state.streak.longest,
        iceReserve: _int(json['iceReserve'], state.streak.iceReserve),
        iceMilestonesReached: state.streak.iceMilestonesReached,
      ),
    ));
  }

  /// `{ track, level, previousLevel, xp, unlocks[] }`.
  ///
  /// Guarded on `track`: the household track has its own event on the
  /// household room, and a shared level-up must never move a personal ring.
  void _applyLevelUp(Map<String, dynamic> json) {
    if (json['track'] == 'household') return;

    final level = _int(json['level'], state.personalProgress.level);
    final unlocks = _strings(json['unlocks']);
    final progress = state.personalProgress;

    emit(state.copyWith(
      personalProgress: ProgressP1(
        xp: _int(json['xp'], progress.xp),
        level: level,
        // Unlocks are cumulative up to the level; the event carries the full
        // list, so it replaces rather than appends.
        unlocks: unlocks.isEmpty ? progress.unlocks : unlocks,
        tasksCompleted: progress.tasksCompleted,
        // The new level restarts the ring. Its size is unknown until the next
        // read, and guessing it would draw a bar against a made-up total.
        xpIntoLevel: 0,
        xpForNextLevel: progress.xpForNextLevel,
        xpToNextLevel: progress.xpForNextLevel,
      ),
      celebration: _nextNotice(
        EconomyP1NoticeKind.levelUp,
        '¡Nivel $level! Tu progreso viaja contigo.',
        unlocks: unlocks,
        level: level,
      ),
    ));
  }

  /// `{ kind: 'tasks_completed', value, total }` — 10/50/100/365 crossed.
  ///
  /// `total` is authoritative, so it corrects the count `_applyReward`
  /// increments optimistically.
  void _applyMilestone(Map<String, dynamic> json) {
    final value = _int(json['value']);
    final total = _int(json['total'], state.personalProgress.tasksCompleted);
    final progress = state.personalProgress;

    emit(state.copyWith(
      personalProgress: ProgressP1(
        xp: progress.xp,
        level: progress.level,
        unlocks: progress.unlocks,
        tasksCompleted: total,
        xpIntoLevel: progress.xpIntoLevel,
        xpForNextLevel: progress.xpForNextLevel,
        xpToNextLevel: progress.xpToNextLevel,
      ),
      celebration: _nextNotice(
        EconomyP1NoticeKind.milestone,
        '$value tareas completadas. Cada una contó.',
        value: value,
      ),
    ));
  }

  EconomyP1Notice _nextNotice(
    EconomyP1NoticeKind kind,
    String message, {
    List<String> unlocks = const [],
    int level = 0,
    int value = 0,
  }) {
    _noticeSequence++;
    return EconomyP1Notice(
      kind: kind,
      message: message,
      sequence: _noticeSequence,
      unlocks: unlocks,
      level: level,
      value: value,
    );
  }

  // ── Writes ──────────────────────────────────────────────────────────────

  /// Buy one streak ice for [kIcePriceCoins] 🪙.
  ///
  /// Never queued offline — see the class doc. A refusal (401/403/409) is
  /// surfaced in [EconomyP1State.actionError] for a snackbar and nothing is
  /// retried: the `Idempotency-Key` makes a retry SAFE, not automatic, and
  /// a 409 specifically means the original request is still running.
  Future<void> buyIce() async {
    final householdId = _householdId;
    if (householdId == null || isClosed) return;
    if (!state.canBuyIce) return;

    // Re-checked on the hot path: `state.isOnline` follows a stream that can
    // lag a transition, and this is the last moment before spending money.
    final online = await _connectivity.checkConnectivity();
    if (isClosed) return;
    if (!online) {
      emit(state.copyWith(
        actionError: 'Sin conexión: no se puede comprar un hielo ahora.',
      ));
      return;
    }

    emit(state.copyWith(isBuyingIce: true, clearActionError: true));

    // One id per logical operation, minted here and reused by whatever
    // retries happen inside ApiService (a 401 refresh replays the same
    // request), so a timeout that actually reached the server replays
    // instead of buying a second ice.
    final operationId = _uuid.v4();

    try {
      final data = await _repo.buyIce(householdId, operationId: operationId);
      if (isClosed) return;

      // The socket echo (`economy:ice_purchased`) usually arrives too, and
      // applying both is safe: each writes the same server-authoritative
      // values rather than incrementing.
      _applyIcePurchased(_payload(data));
    } catch (e) {
      if (isClosed) return;
      emit(state.copyWith(isBuyingIce: false, actionError: _messageFor(e)));
    }
  }

  void dismissCelebration() {
    if (isClosed) return;
    emit(state.copyWith(clearCelebration: true));
  }

  void dismissNotice() {
    if (isClosed) return;
    emit(state.copyWith(clearNotice: true));
  }

  void clearActionError() {
    if (isClosed) return;
    emit(state.copyWith(clearActionError: true));
  }

  /// ApiService already maps status codes to typed, human-readable failures
  /// (401 → [AuthFailure], 409 → [ConflictFailure], 403 → [ServerFailure]),
  /// so the message it carries is the one to show.
  String _messageFor(Object error) {
    if (error is Failure) return error.message;
    return 'No se pudo completar la operación.';
  }
}

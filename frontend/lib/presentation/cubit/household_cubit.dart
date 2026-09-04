import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/errors/failures.dart';
import '../../data/models/household.dart';
import '../../data/models/household_governance.dart';
import '../../data/models/user.dart';
import '../../data/repositories/household_repository.dart';

enum HouseholdStatusUi { initial, loading, loaded, empty, error }

class HouseholdState extends Equatable {
  final HouseholdStatusUi status;
  final Household? current;
  final bool loading;
  final String? error;

  /// Pending deletion of the active household (TD-067, PDR-022 D4).
  ///
  /// Null means "not loaded yet", which is not the same as "nothing pending" —
  /// the admin section shows no banner in either case, but only the second one
  /// justifies offering the delete button.
  final DestructionStatus? destruction;

  const HouseholdState({
    this.status = HouseholdStatusUi.initial,
    this.current,
    this.loading = false,
    this.error,
    this.destruction,
  });

  HouseholdState copyWith({
    HouseholdStatusUi? status,
    Household? current,
    bool? loading,
    String? error,
    bool clearError = false,
    DestructionStatus? destruction,
    bool clearDestruction = false,
  }) {
    return HouseholdState(
      status: status ?? this.status,
      current: current ?? this.current,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      destruction:
          clearDestruction ? null : (destruction ?? this.destruction),
    );
  }

  @override
  List<Object?> get props => [status, current, loading, error, destruction];
}

/// Manages the active household and its members.
class HouseholdCubit extends Cubit<HouseholdState> {
  final HouseholdRepository _repo;

  HouseholdCubit(this._repo) : super(const HouseholdState());

  String? get currentId => state.current?.id;

  /// Resolve the active household on login/startup: use the persisted id if
  /// present, otherwise the user's first household.
  Future<void> init(User user) async {
    final savedId = await _repo.currentHouseholdId();
    final targetId = (savedId != null && user.households.contains(savedId))
        ? savedId
        : (user.households.isNotEmpty ? user.households.first : null);

    if (targetId == null) {
      emit(state.copyWith(status: HouseholdStatusUi.empty));
      return;
    }
    await loadHousehold(targetId);
  }

  Future<void> loadHousehold(String id) async {
    emit(state.copyWith(status: HouseholdStatusUi.loading, clearError: true));
    try {
      final household = await _repo.getById(id);
      await _repo.setCurrentHouseholdId(household.id);
      emit(state.copyWith(status: HouseholdStatusUi.loaded, current: household));
    } on Failure catch (f) {
      emit(state.copyWith(status: HouseholdStatusUi.error, error: f.message));
    }
  }

  Future<Household?> createHousehold(String name) async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final household = await _repo.create(name);
      await _repo.setCurrentHouseholdId(household.id);
      emit(state.copyWith(
        status: HouseholdStatusUi.loaded,
        current: household,
        loading: false,
      ));
      return household;
    } on Failure catch (f) {
      emit(state.copyWith(loading: false, error: f.message));
      return null;
    }
  }

  Future<Household?> joinHousehold(String inviteCode) async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final household = await _repo.join(inviteCode);
      await _repo.setCurrentHouseholdId(household.id);
      emit(state.copyWith(
        status: HouseholdStatusUi.loaded,
        current: household,
        loading: false,
      ));
      return household;
    } on Failure catch (f) {
      emit(state.copyWith(loading: false, error: f.message));
      return null;
    }
  }

  Future<void> switchHousehold(String id) => loadHousehold(id);

  Future<void> removeMember(String userId) async {
    final id = currentId;
    if (id == null) return;
    try {
      final household = await _repo.removeMember(id, userId);
      emit(state.copyWith(current: household));
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    }
  }

  // ---- Governance (TD-067, PDR-022) ----

  /// True when [userId] created the active household — the permission PDR-022
  /// D1 hangs everything on.
  ///
  /// A getter over the household the cubit already holds rather than a stored
  /// flag: `createdBy` moves when ownership is transferred, and a cached
  /// boolean would keep showing the admin section to someone who just gave it
  /// away (or hide it from whoever received it) until the next full reload.
  bool isCreator(String? userId) =>
      userId != null && state.current?.createdBy == userId;

  /// Promote a member to admin (D1). Returns true on success.
  Future<bool> promoteMember(String userId) =>
      _roleChange((repo, id) => repo.promoteMember(id, userId));

  /// Demote an admin to member (D1). Returns true on success.
  Future<bool> demoteMember(String userId) =>
      _roleChange((repo, id) => repo.demoteMember(id, userId));

  /// Hand ownership to another admin (D2). Returns true on success.
  Future<bool> transferOwnership(String userId) =>
      _roleChange((repo, id) => repo.transferOwnership(id, userId));

  /// The three calls that answer with the updated household differ only in
  /// which one they are, so the error handling and the state write live once.
  Future<bool> _roleChange(
    Future<Household> Function(HouseholdRepository repo, String householdId) call,
  ) async {
    final id = currentId;
    if (id == null) return false;
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final household = await call(_repo, id);
      emit(state.copyWith(current: household, loading: false));
      return true;
    } on Failure catch (f) {
      emit(state.copyWith(loading: false, error: f.message));
      return false;
    }
  }

  /// Leave the active household (D3).
  ///
  /// On success the cubit resets: the caller is no longer a member, so
  /// continuing to hold that household's roster would be showing them data
  /// they have lost the right to. Returns the succession so the page can say
  /// what happened, or null on failure.
  Future<LeaveOutcome?> leaveHousehold() async {
    final id = currentId;
    if (id == null) return null;
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final outcome = await _repo.leave(id);
      await _repo.setCurrentHouseholdId(null);
      emit(const HouseholdState(status: HouseholdStatusUi.empty));
      return outcome;
    } on Failure catch (f) {
      emit(state.copyWith(loading: false, error: f.message));
      return null;
    }
  }

  /// Read whether a deletion is pending (D4). Any member may.
  ///
  /// Failure is swallowed into `scheduled: false` rather than surfaced: this
  /// runs on entering the profile screen, and an error banner about a status
  /// nobody asked for would be noise. The consequence of getting it wrong is
  /// a missing banner, not a wrong action — every command re-checks server-side.
  Future<void> loadDestructionStatus() async {
    final id = currentId;
    if (id == null) return;
    try {
      emit(state.copyWith(destruction: await _repo.destructionStatus(id)));
    } on Failure {
      emit(state.copyWith(destruction: const DestructionStatus()));
    }
  }

  /// Start the grace period before deletion (D4).
  Future<bool> scheduleDestruction() async {
    final id = currentId;
    if (id == null) return false;
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final status = await _repo.scheduleDestruction(id);
      emit(state.copyWith(destruction: status, loading: false));
      return true;
    } on Failure catch (f) {
      emit(state.copyWith(loading: false, error: f.message));
      return false;
    }
  }

  /// Call the deletion off (D4).
  Future<bool> cancelDestruction() async {
    final id = currentId;
    if (id == null) return false;
    emit(state.copyWith(loading: true, clearError: true));
    try {
      await _repo.cancelDestruction(id);
      emit(state.copyWith(
        destruction: const DestructionStatus(),
        loading: false,
      ));
      return true;
    } on Failure catch (f) {
      emit(state.copyWith(loading: false, error: f.message));
      return false;
    }
  }

  /// Destroy the household now that the grace period has expired (D4).
  ///
  /// Resets on success for the same reason [leaveHousehold] does, and more
  /// so: the household is gone, and every request against it now answers 404.
  Future<bool> confirmDestruction() async {
    final id = currentId;
    if (id == null) return false;
    emit(state.copyWith(loading: true, clearError: true));
    try {
      await _repo.confirmDestruction(id);
      await _repo.setCurrentHouseholdId(null);
      emit(const HouseholdState(status: HouseholdStatusUi.empty));
      return true;
    } on Failure catch (f) {
      emit(state.copyWith(loading: false, error: f.message));
      return false;
    }
  }

  /// Refresh the household when members join/leave/change role via realtime.
  ///
  /// Three of the events are handled without a reload, because a reload is the
  /// wrong answer for them:
  ///   - `household:destroyed` — the household is gone, so re-fetching it
  ///     answers 404 and would surface as an error banner about something the
  ///     user did not do. Reset instead, exactly as leaving does.
  ///   - the two destruction-schedule events carry their own payload, so the
  ///     banner can move without a round trip.
  ///
  /// Everything else — joins, leaves, role changes, ownership transfers —
  /// changes the member list or `createdBy`, both of which live in the
  /// household document, so a reload is both necessary and sufficient.
  Future<void> applyRealtime(String event, dynamic data) async {
    final id = currentId;
    if (id == null || data is! Map) return;
    if (data['householdId']?.toString() != id) return;

    switch (event) {
      case 'household:destroyed':
        await _repo.setCurrentHouseholdId(null);
        emit(const HouseholdState(status: HouseholdStatusUi.empty));
        return;
      case 'household:destruction_scheduled':
        emit(state.copyWith(
          destruction: DestructionStatus.fromJson(
            Map<String, dynamic>.from(data),
          ),
        ));
        return;
      case 'household:destruction_cancelled':
        emit(state.copyWith(destruction: const DestructionStatus()));
        return;
      default:
        await loadHousehold(id);
    }
  }

  /// Drop the active household — called on logout/session-expiry (TD-058),
  /// alongside the equivalent `reset()` on TaskCubit/ShoppingCubit/PetCubit/
  /// StatsCubit.
  void reset() => emit(const HouseholdState());
}

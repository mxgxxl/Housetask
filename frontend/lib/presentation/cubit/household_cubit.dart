import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/errors/failures.dart';
import '../../data/models/household.dart';
import '../../data/models/user.dart';
import '../../data/repositories/household_repository.dart';

enum HouseholdStatusUi { initial, loading, loaded, empty, error }

class HouseholdState extends Equatable {
  final HouseholdStatusUi status;
  final Household? current;
  final bool loading;
  final String? error;

  const HouseholdState({
    this.status = HouseholdStatusUi.initial,
    this.current,
    this.loading = false,
    this.error,
  });

  HouseholdState copyWith({
    HouseholdStatusUi? status,
    Household? current,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return HouseholdState(
      status: status ?? this.status,
      current: current ?? this.current,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [status, current, loading, error];
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

  /// Refresh the household when members join/leave via realtime.
  Future<void> applyRealtime(String event, dynamic data) async {
    final id = currentId;
    if (id == null || data is! Map) return;
    if (data['householdId']?.toString() == id) {
      await loadHousehold(id);
    }
  }

  void reset() => emit(const HouseholdState());
}

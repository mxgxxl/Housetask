import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/errors/failures.dart';
import '../../data/models/household_stats.dart';
import '../../data/repositories/household_repository.dart';

enum StatsStatusUi { initial, loading, loaded, error }

class StatsState extends Equatable {
  final StatsStatusUi status;
  final HouseholdStats? stats;
  final StatsPeriod period;
  final String? error;

  const StatsState({
    this.status = StatsStatusUi.initial,
    this.stats,
    this.period = StatsPeriod.last30days,
    this.error,
  });

  StatsState copyWith({
    StatsStatusUi? status,
    HouseholdStats? stats,
    StatsPeriod? period,
    String? error,
    bool clearError = false,
  }) {
    return StatsState(
      status: status ?? this.status,
      stats: stats ?? this.stats,
      period: period ?? this.period,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [status, stats, period, error];
}

/// Household stats screen state (PDR-007): fetches and refetches on period
/// toggle. Kept out of HouseholdCubit — this is page-scoped view state
/// (loading/period), not part of "the active household".
class StatsCubit extends Cubit<StatsState> {
  final HouseholdRepository _repo;

  StatsCubit(this._repo) : super(const StatsState());

  Future<void> load(String householdId, {StatsPeriod? period}) async {
    final targetPeriod = period ?? state.period;
    emit(state.copyWith(
      status: StatsStatusUi.loading,
      period: targetPeriod,
      clearError: true,
    ));
    try {
      final stats = await _repo.stats(householdId, targetPeriod);
      emit(state.copyWith(status: StatsStatusUi.loaded, stats: stats));
    } on Failure catch (f) {
      emit(state.copyWith(status: StatsStatusUi.error, error: f.message));
    }
  }
}

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors/failures.dart';
import '../../data/models/economy.dart';
import '../../data/models/pet.dart';
import '../../data/repositories/pet_repository.dart';
import '../../services/sentry_service.dart';

enum PetStatusUi { initial, loading, noPet, pendingRequest, hasPet, error }

class PetState extends Equatable {
  final PetStatusUi status;
  final Pet? pet;
  final AdoptionRequest? pendingRequest;

  /// Only meaningful when [status] is [PetStatusUi.pendingRequest]: whether
  /// the CURRENT user is the one who proposed it (they see "waiting for
  /// confirmation"; anyone else sees a "confirm" button — PDR-001 A3).
  final bool requestedByMe;

  final Economy economy;
  final String? error;

  /// True while an adopt/confirm/cancel/feed/play/buy/setActive call is in
  /// flight — lets the UI disable buttons instead of allowing a
  /// double-submit while a request is still running.
  final bool actionInProgress;

  const PetState({
    this.status = PetStatusUi.initial,
    this.pet,
    this.pendingRequest,
    this.requestedByMe = false,
    this.economy = const Economy(),
    this.error,
    this.actionInProgress = false,
  });

  PetState copyWith({
    PetStatusUi? status,
    Pet? pet,
    AdoptionRequest? pendingRequest,
    bool? requestedByMe,
    Economy? economy,
    String? error,
    bool? actionInProgress,
    bool clearPet = false,
    bool clearPendingRequest = false,
  }) {
    return PetState(
      status: status ?? this.status,
      pet: clearPet ? null : (pet ?? this.pet),
      pendingRequest:
          clearPendingRequest ? null : (pendingRequest ?? this.pendingRequest),
      requestedByMe: requestedByMe ?? this.requestedByMe,
      economy: economy ?? this.economy,
      error: error,
      actionInProgress: actionInProgress ?? this.actionInProgress,
    );
  }

  @override
  List<Object?> get props => [
        status,
        pet,
        pendingRequest,
        requestedByMe,
        economy,
        error,
        actionInProgress,
      ];
}

/// Manages the household's pet: adoption (propose/confirm/cancel), care
/// (feed/play), the cosmetics shop, and the economy snapshot backing it.
///
/// Every mutating action applies the server's response directly to state
/// instead of re-calling [load] afterwards — the backend already returns
/// the fresh Pet (and buyCosmetic's economy is refetched once, since the
/// balance isn't part of the Pet payload) — so "refresh after every action"
/// means "trust the action's own response", not a second round trip.
class PetCubit extends Cubit<PetState> {
  final PetRepository _repo;
  String? _householdId;
  String? _currentUserId;

  PetCubit(this._repo) : super(const PetState());

  /// Load the household's pet (or pending request, or neither) plus the
  /// economy snapshot. [currentUserId] is needed to compute
  /// [PetState.requestedByMe] — PetCubit deliberately doesn't depend on
  /// AuthCubit directly (same independence TaskCubit/ShoppingCubit have);
  /// the caller (MainScaffold) already has both households' worth of
  /// context to pass it through.
  Future<void> load(String householdId, String currentUserId) async {
    _householdId = householdId;
    _currentUserId = currentUserId;
    emit(state.copyWith(status: PetStatusUi.loading, error: null));
    try {
      final pet = await _repo.getPet(householdId);
      if (pet != null) {
        final economy = await _repo.getEconomy(householdId);
        emit(state.copyWith(
          status: PetStatusUi.hasPet,
          pet: pet,
          economy: economy,
          clearPendingRequest: true,
        ));
        return;
      }

      final request = await _repo.getPendingAdoption(householdId);
      if (request != null) {
        emit(state.copyWith(
          status: PetStatusUi.pendingRequest,
          pendingRequest: request,
          requestedByMe: request.requestedBy == currentUserId,
          clearPet: true,
        ));
        return;
      }

      emit(state.copyWith(
        status: PetStatusUi.noPet,
        clearPet: true,
        clearPendingRequest: true,
      ));
    } on Failure catch (f) {
      emit(state.copyWith(status: PetStatusUi.error, error: f.message));
    }
  }

  Future<void> refresh() async {
    if (_householdId == null || _currentUserId == null) return;
    await load(_householdId!, _currentUserId!);
  }

  /// Apply an incoming realtime pet/adoption/economy socket event (PDR-001
  /// A4: pet:adopt_requested, pet:adopted, pet:adopt_cancelled, pet:updated).
  /// Pet/AdoptionRequest/Economy are each a single value per household — no
  /// list to merge into like Task/ShoppingItem's applyRealtime — so every
  /// pet:* event just means "reload", the same pattern SocketCubit already
  /// uses for tasks:batch_created -> TaskCubit.refresh(). Returns a Future
  /// (rather than fire-and-forget) so callers/tests can await completion;
  /// SocketService's callback type is void, so the socket wiring itself
  /// simply discards it, same as any other Dart void callback backed by an
  /// async method.
  ///
  /// Same household guard as TaskCubit/ShoppingCubit.applyRealtime: a user
  /// can belong to more than one household, so an event for a household
  /// other than the one currently loaded is ignored.
  Future<void> applyRealtime(String event, dynamic data) async {
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      if (_householdId != null &&
          map['householdId'] != null &&
          map['householdId'].toString() != _householdId) {
        return;
      }
    }
    await refresh();
  }

  Future<void> proposeAdoption({required String species, required String name}) async {
    if (_householdId == null) return;
    emit(state.copyWith(actionInProgress: true, error: null));
    try {
      final request = await _repo.adopt(_householdId!, species: species, name: name);
      SentryService.addBreadcrumb(
        'Adoption proposed',
        category: 'pet',
        data: {'householdId': _householdId, 'species': species},
      );
      emit(state.copyWith(
        status: PetStatusUi.pendingRequest,
        pendingRequest: request,
        requestedByMe: true,
        actionInProgress: false,
      ));
    } on Failure catch (f) {
      emit(state.copyWith(actionInProgress: false, error: f.message));
    }
  }

  Future<void> confirmAdoption() async {
    if (_householdId == null) return;
    emit(state.copyWith(actionInProgress: true, error: null));
    try {
      final pet = await _repo.confirmAdopt(_householdId!);
      final economy = await _repo.getEconomy(_householdId!);
      SentryService.addBreadcrumb(
        'Adoption confirmed',
        category: 'pet',
        data: {'householdId': _householdId, 'species': pet.species},
      );
      emit(state.copyWith(
        status: PetStatusUi.hasPet,
        pet: pet,
        economy: economy,
        actionInProgress: false,
        clearPendingRequest: true,
      ));
    } on Failure catch (f) {
      emit(state.copyWith(actionInProgress: false, error: f.message));
    }
  }

  Future<void> cancelAdoption() async {
    if (_householdId == null) return;
    emit(state.copyWith(actionInProgress: true, error: null));
    try {
      await _repo.cancelAdopt(_householdId!);
      emit(state.copyWith(
        status: PetStatusUi.noPet,
        actionInProgress: false,
        clearPendingRequest: true,
      ));
    } on Failure catch (f) {
      emit(state.copyWith(actionInProgress: false, error: f.message));
    }
  }

  Future<void> feed() async {
    if (_householdId == null) return;
    emit(state.copyWith(actionInProgress: true, error: null));
    try {
      final pet = await _repo.feed(_householdId!);
      SentryService.addBreadcrumb('Pet fed', category: 'pet', data: {'householdId': _householdId});
      emit(state.copyWith(pet: pet, actionInProgress: false));
    } on Failure catch (f) {
      emit(state.copyWith(actionInProgress: false, error: f.message));
    }
  }

  Future<void> play() async {
    if (_householdId == null) return;
    emit(state.copyWith(actionInProgress: true, error: null));
    try {
      final pet = await _repo.play(_householdId!);
      SentryService.addBreadcrumb(
        'Played with pet',
        category: 'pet',
        data: {'householdId': _householdId},
      );
      emit(state.copyWith(pet: pet, actionInProgress: false));
    } on Failure catch (f) {
      emit(state.copyWith(actionInProgress: false, error: f.message));
    }
  }

  Future<void> buyCosmetic(String cosmeticId) async {
    if (_householdId == null) return;
    emit(state.copyWith(actionInProgress: true, error: null));
    try {
      final pet = await _repo.buyCosmetic(_householdId!, cosmeticId);
      final economy = await _repo.getEconomy(_householdId!);
      SentryService.addBreadcrumb(
        'Cosmetic bought',
        category: 'pet',
        data: {'householdId': _householdId, 'cosmeticId': cosmeticId},
      );
      emit(state.copyWith(pet: pet, economy: economy, actionInProgress: false));
    } on Failure catch (f) {
      emit(state.copyWith(actionInProgress: false, error: f.message));
    }
  }

  Future<void> setActiveCosmetic(String cosmeticId) async {
    if (_householdId == null) return;
    emit(state.copyWith(actionInProgress: true, error: null));
    try {
      final pet = await _repo.setActiveCosmetic(_householdId!, cosmeticId);
      emit(state.copyWith(pet: pet, actionInProgress: false));
    } on Failure catch (f) {
      emit(state.copyWith(actionInProgress: false, error: f.message));
    }
  }
}

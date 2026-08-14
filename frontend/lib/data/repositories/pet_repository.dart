import 'package:uuid/uuid.dart';

import '../../core/errors/failures.dart';
import '../datasources/remote/api_service.dart';
import '../models/economy.dart';
import '../models/pet.dart';

/// CRUD for the household's shared pet + economy (PDR-001). Unlike
/// TaskRepository/ShoppingRepository, deliberately NOT cache-first/offline
/// (TD-003 scope was tasks/shopping only): the pet is a low-frequency,
/// consensus-gated feature where a stale offline read (e.g. showing a
/// hunger bar that's actually been fed by the other member) would be more
/// confusing than a network error.
class PetRepository {
  final ApiService _api;
  final Uuid _uuid;

  PetRepository(this._api, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// The household's pet, or null if it hasn't adopted one yet (404).
  Future<Pet?> getPet(String householdId) async {
    try {
      final data = await _api.get('/households/$householdId/pet');
      return Pet.fromJson(Map<String, dynamic>.from(data as Map));
    } on Failure catch (f) {
      if (f is ServerFailure && f.statusCode == 404) return null;
      rethrow;
    }
  }

  /// The household's pending adoption request, or null if there is none
  /// (404) — including one that expired past the backend's 7-day TTL.
  Future<AdoptionRequest?> getPendingAdoption(String householdId) async {
    try {
      final data = await _api.get('/households/$householdId/pet/adopt');
      return AdoptionRequest.fromJson(Map<String, dynamic>.from(data as Map));
    } on Failure catch (f) {
      if (f is ServerFailure && f.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<Economy> getEconomy(String householdId) async {
    final data = await _api.get('/households/$householdId/economy');
    return Economy.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Propose an adoption. Carries an Idempotency-Key (ADR-007): a resource
  /// (AdoptionRequest) is created, same as task/household creation.
  Future<AdoptionRequest> adopt(
    String householdId, {
    required String species,
    required String name,
  }) async {
    final data = await _api.post(
      '/households/$householdId/pet/adopt',
      body: {'species': species, 'name': name},
      headers: {'Idempotency-Key': _uuid.v4()},
    );
    return AdoptionRequest.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Confirm a pending adoption (must be a different member than the
  /// requester — enforced server-side). Creates the Pet, so it also carries
  /// an Idempotency-Key.
  Future<Pet> confirmAdopt(String householdId) async {
    final data = await _api.post(
      '/households/$householdId/pet/adopt/confirm',
      headers: {'Idempotency-Key': _uuid.v4()},
    );
    return Pet.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Cancel the pending request (requester or household admin only).
  Future<void> cancelAdopt(String householdId) async {
    await _api.delete('/households/$householdId/pet/adopt');
  }

  /// Feed the pet. No Idempotency-Key: this mutates existing state rather
  /// than creating a resource, and the backend's cooldown (409 on a repeat
  /// within the window) is itself the anti-duplicate guard — see
  /// pet.routes.ts on the backend.
  Future<Pet> feed(String householdId) async {
    final data = await _api.post('/households/$householdId/pet/feed');
    return Pet.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<Pet> play(String householdId) async {
    final data = await _api.post('/households/$householdId/pet/play');
    return Pet.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Spend coins on a cosmetic. Creates an EconomyLedger entry, so it
  /// carries an Idempotency-Key like adopt/confirmAdopt.
  Future<Pet> buyCosmetic(String householdId, String cosmeticId) async {
    final data = await _api.post(
      '/households/$householdId/pet/cosmetics/buy',
      body: {'cosmeticId': cosmeticId},
      headers: {'Idempotency-Key': _uuid.v4()},
    );
    return Pet.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<Pet> setActiveCosmetic(String householdId, String cosmeticId) async {
    final data = await _api.post(
      '/households/$householdId/pet/cosmetics/active',
      body: {'cosmeticId': cosmeticId},
    );
    return Pet.fromJson(Map<String, dynamic>.from(data as Map));
  }
}

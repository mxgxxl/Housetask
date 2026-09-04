import 'package:uuid/uuid.dart';

import '../datasources/local/auth_local_datasource.dart';
import '../datasources/remote/api_service.dart';
import '../models/household.dart';
import '../models/household_stats.dart';
import '../models/household_governance.dart';
import '../models/member.dart';

/// CRUD for households + local persistence of the active household id.
class HouseholdRepository {
  final ApiService _api;
  final AuthLocalDataSource _local;
  final Uuid _uuid;

  HouseholdRepository(this._api, this._local, {Uuid? uuid})
      : _uuid = uuid ?? const Uuid();

  /// One Idempotency-Key per call, so a 401-refresh retry cannot create a
  /// second household (ADR-007).
  Future<Household> create(String name) async {
    final data = await _api.post(
      '/households',
      body: {'name': name},
      headers: {'Idempotency-Key': _uuid.v4()},
    );
    return Household.fromJson(data as Map<String, dynamic>);
  }

  Future<Household> getById(String id) async {
    final data = await _api.get('/households/$id');
    return Household.fromJson(data as Map<String, dynamic>);
  }

  Future<Household> join(String inviteCode) async {
    final data = await _api.post(
      '/households/join',
      body: {'inviteCode': inviteCode},
      headers: {'Idempotency-Key': _uuid.v4()},
    );
    return Household.fromJson(data as Map<String, dynamic>);
  }

  Future<List<Member>> members(String id) async {
    final data = await _api.get('/households/$id/members');
    return (data as List<dynamic>)
        .map((e) => Member.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Household> removeMember(String householdId, String userId) async {
    final data = await _api.delete('/households/$householdId/members/$userId');
    return Household.fromJson(data as Map<String, dynamic>);
  }

  // ---- Governance (TD-067, PDR-022) ----

  /// Promote a member to admin. Creator only, enforced by the server (D1).
  ///
  /// No Idempotency-Key: these are PATCHes that set a role to a known value,
  /// so a 401-refresh retry lands on the same state rather than creating a
  /// second anything. Hard Rule 13 is about POSTs that create resources.
  Future<Household> promoteMember(String householdId, String userId) async {
    final data = await _api.patch('/households/$householdId/members/$userId/promote');
    return Household.fromJson(data as Map<String, dynamic>);
  }

  /// Demote an admin back to member. Creator only; the creator is never a
  /// valid target (D1).
  Future<Household> demoteMember(String householdId, String userId) async {
    final data = await _api.patch('/households/$householdId/members/$userId/demote');
    return Household.fromJson(data as Map<String, dynamic>);
  }

  /// Hand ownership to another admin (D2). The outgoing creator stays in the
  /// household as an admin.
  Future<Household> transferOwnership(String householdId, String userId) async {
    final data = await _api.post(
      '/households/$householdId/transfer-ownership',
      body: {'userId': userId},
    );
    return Household.fromJson(data as Map<String, dynamic>);
  }

  /// Leave the household (D3).
  ///
  /// Returns what the departure changed, NOT a household: the caller stopped
  /// being entitled to its roster and invite code the moment they left, so
  /// the server does not send them back.
  Future<LeaveOutcome> leave(String householdId) async {
    final data = await _api.post('/households/$householdId/leave');
    return LeaveOutcome.fromJson(data as Map<String, dynamic>);
  }

  /// Start the 24h grace period before deletion. Creator only (D4).
  Future<DestructionStatus> scheduleDestruction(String householdId) async {
    final data = await _api.post(
      '/households/$householdId/schedule-destruction',
      // The one governance call that CREATES a resource (the pending-deletion
      // row), so Hard Rule 13 applies. The server is idempotent on its own —
      // a unique index, not this header — but a retried request must not be
      // able to report a second, later deadline.
      headers: {'Idempotency-Key': _uuid.v4()},
    );
    return DestructionStatus.fromJson(data as Map<String, dynamic>);
  }

  /// Call the deletion off. Creator only (D4).
  Future<void> cancelDestruction(String householdId) async {
    await _api.post('/households/$householdId/cancel-destruction');
  }

  /// Destroy the household once the grace period has expired. Creator only;
  /// the server answers 400 while the deadline is still in the future (D4).
  Future<void> confirmDestruction(String householdId) async {
    await _api.post('/households/$householdId/confirm-destruction');
  }

  /// Whether a deletion is pending. Any member may read it.
  Future<DestructionStatus> destructionStatus(String householdId) async {
    final data = await _api.get('/households/$householdId/destruction-status');
    return DestructionStatus.fromJson(data as Map<String, dynamic>);
  }

  Future<HouseholdStats> stats(String householdId, StatsPeriod period) async {
    final data = await _api.get(
      '/households/$householdId/stats',
      query: {'period': period.queryValue},
    );
    return HouseholdStats.fromJson(data as Map<String, dynamic>);
  }

  Future<String?> currentHouseholdId() => _local.getCurrentHouseholdId();

  Future<void> setCurrentHouseholdId(String? id) =>
      _local.saveCurrentHouseholdId(id);
}

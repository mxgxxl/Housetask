import '../datasources/local/auth_local_datasource.dart';
import '../datasources/remote/api_service.dart';
import '../models/household.dart';
import '../models/member.dart';

/// CRUD for households + local persistence of the active household id.
class HouseholdRepository {
  final ApiService _api;
  final AuthLocalDataSource _local;

  HouseholdRepository(this._api, this._local);

  Future<Household> create(String name) async {
    final data = await _api.post('/households', body: {'name': name});
    return Household.fromJson(data as Map<String, dynamic>);
  }

  Future<Household> getById(String id) async {
    final data = await _api.get('/households/$id');
    return Household.fromJson(data as Map<String, dynamic>);
  }

  Future<Household> join(String inviteCode) async {
    final data = await _api.post('/households/join', body: {'inviteCode': inviteCode});
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

  Future<String?> currentHouseholdId() => _local.getCurrentHouseholdId();

  Future<void> setCurrentHouseholdId(String? id) =>
      _local.saveCurrentHouseholdId(id);
}

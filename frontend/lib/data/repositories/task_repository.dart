import '../datasources/remote/api_service.dart';
import '../models/task.dart';

/// CRUD for household tasks.
class TaskRepository {
  final ApiService _api;

  TaskRepository(this._api);

  Future<List<Task>> list(String householdId, {String? status}) async {
    final data = await _api.get(
      '/households/$householdId/tasks',
      query: status != null ? {'status': status} : null,
    );
    return (data as List<dynamic>)
        .map((e) => Task.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Task> create(String householdId, Map<String, dynamic> payload) async {
    final data = await _api.post('/households/$householdId/tasks', body: payload);
    return Task.fromJson(data as Map<String, dynamic>);
  }

  Future<Task> update(
    String householdId,
    String taskId,
    Map<String, dynamic> payload,
  ) async {
    final data =
        await _api.patch('/households/$householdId/tasks/$taskId', body: payload);
    return Task.fromJson(data as Map<String, dynamic>);
  }

  Future<Task> complete(String householdId, String taskId) async {
    final data =
        await _api.patch('/households/$householdId/tasks/$taskId/complete');
    return Task.fromJson(data as Map<String, dynamic>);
  }

  Future<void> delete(String householdId, String taskId) async {
    await _api.delete('/households/$householdId/tasks/$taskId');
  }
}

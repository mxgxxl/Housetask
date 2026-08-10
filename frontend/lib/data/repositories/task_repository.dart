import 'package:uuid/uuid.dart';

import '../datasources/remote/api_service.dart';
import '../models/paginated_response.dart';
import '../models/task.dart';

/// CRUD for household tasks.
class TaskRepository {
  final ApiService _api;
  final Uuid _uuid;

  TaskRepository(this._api, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// Fetch one page of tasks. Omit [cursor] for the first page.
  Future<PaginatedResponse<Task>> list(
    String householdId, {
    String? status,
    int limit = 50,
    String? cursor,
  }) async {
    final data = await _api.get(
      '/households/$householdId/tasks',
      query: {
        'limit': limit,
        if (status != null) 'status': status,
        if (cursor != null) 'cursor': cursor,
      },
    );
    return PaginatedResponse<Task>.fromJson(
      Map<String, dynamic>.from(data as Map),
      Task.fromJson,
    );
  }

  /// Create a task.
  ///
  /// One `Idempotency-Key` is generated per call and travels in the request
  /// options, so the 401-refresh retry inside [ApiService] replays the same key
  /// and the server returns the original task instead of creating a second one
  /// (backend ADR-007).
  Future<Task> create(String householdId, Map<String, dynamic> payload) async {
    final data = await _api.post(
      '/households/$householdId/tasks',
      body: payload,
      headers: {'Idempotency-Key': _uuid.v4()},
    );
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

  /// Catch-up: ask the server to generate missed recurring occurrences.
  /// Returns `{ generated, tasks }`.
  Future<Map<String, dynamic>> generateRecurringInstances(String householdId) async {
    final data = await _api.post('/households/$householdId/tasks/generate-instances');
    return data as Map<String, dynamic>;
  }
}

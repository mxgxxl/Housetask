import 'package:uuid/uuid.dart';

import '../../core/errors/failures.dart';
import '../../services/cache_service.dart';
import '../../services/connectivity_service.dart';
import '../../services/sentry_service.dart';
import '../datasources/remote/api_service.dart';
import '../models/paginated_response.dart';
import '../models/pending_operation.dart';
import '../models/task.dart';
import '../models/task_adapter.dart';

/// CRUD for household tasks — cache-first reads, offline-queued writes
/// (TD-003).
///
/// [cache] and [connectivity] are injectable (defaulting to the app-wide
/// singletons) so tests can drive offline/online transitions deterministically
/// without touching Hive or a real platform connectivity channel.
class TaskRepository {
  final ApiService _api;
  final Uuid _uuid;
  final CacheService _cache;
  final ConnectivityService _connectivity;

  TaskRepository(
    this._api, {
    Uuid? uuid,
    CacheService? cache,
    ConnectivityService? connectivity,
  })  : _uuid = uuid ?? const Uuid(),
        _cache = cache ?? CacheService(),
        _connectivity = connectivity ?? ConnectivityService();

  /// Whether the most recent [list] call served the cache fallback instead of
  /// a live server response. `list()` absorbs the offline case itself (the
  /// caller always gets a successful page, never a thrown error for it), so
  /// this is how TaskCubit tells "we are offline" apart from "the household
  /// legitimately has zero tasks" — set right before every return from
  /// [list], safe to read immediately after awaiting it.
  bool lastListWasFromCache = false;

  /// Fetch one page of tasks. Omit [cursor] for the first page.
  ///
  /// [from]/[to] (PDR-003 timeline) restrict the page to tasks whose dueDate
  /// falls in that window, plus every undated task (the backend always
  /// includes them — see task.service.ts `dueDateWindowFilter` — so the
  /// timeline's "Sin fecha" bucket never has to be fetched separately).
  /// Serialized via `.toUtc().toIso8601String()` so the instant sent is
  /// unambiguous regardless of the device's timezone: the caller computes
  /// [from]/[to] from its own local calendar boundaries (e.g. "start of
  /// yesterday"), and the server only ever sees an absolute UTC instant, never
  /// a bare date it would have to guess a timezone for.
  ///
  /// Falls back to the cache when the request cannot be answered at all
  /// (offline, timeout, 5xx) — never on an ordinary 4xx, which is a real
  /// answer from the server. A cache fallback always returns everything
  /// cached for the household in one page (Hive has no server-side cursor to
  /// resume from), so a subsequent loadMore() is a correct no-op rather than
  /// re-appending the same rows.
  ///
  /// [includeDeleted] (TD-009) asks the backend to include soft-deleted tasks
  /// in the page instead of excluding them (the default) — used by
  /// [TaskCubit.loadTrashTasks] to walk the full list and keep only the
  /// deleted rows, the same TD-035 pattern [TaskCubit.loadRecurringTasks]
  /// already uses instead of a dedicated endpoint. An offline fallback never
  /// has deleted rows to show (the cache only ever holds active tasks, plus
  /// locally-queued pending deletes — see [_listFromCache]), so it ignores
  /// this flag rather than serving something misleading.
  Future<PaginatedResponse<Task>> list(
    String householdId, {
    String? status,
    int limit = 50,
    String? cursor,
    DateTime? from,
    DateTime? to,
    bool includeDeleted = false,
  }) async {
    try {
      final data = await _api.get(
        '/households/$householdId/tasks',
        query: {
          'limit': limit,
          if (status != null) 'status': status,
          if (cursor != null) 'cursor': cursor,
          if (from != null) 'from': from.toUtc().toIso8601String(),
          if (to != null) 'to': to.toUtc().toIso8601String(),
          if (includeDeleted) 'includeDeleted': 'true',
        },
      );
      final page = PaginatedResponse<Task>.fromJson(
        Map<String, dynamic>.from(data as Map),
        Task.fromJson,
      );
      if (cursor == null && !includeDeleted) {
        // Only the first page of the DEFAULT (active-only) list is a
        // full-enough snapshot to cache as "this household's tasks" — an
        // includeDeleted page mixes in rows that don't belong in the offline
        // active-task cache, and a middle page would make a later offline
        // read show an arbitrary slice instead of the earliest rows.
        //
        // A status-filtered first page (Pendientes/Completadas) is a
        // different case: it's a real slice, not a snapshot, so it merges by
        // id instead of replacing — a full replace here would evict every
        // other status already cached for the household (TD-045).
        if (status == null) {
          await _cacheBestEffort(_cache.saveTasks(householdId, page.items), 'saveTasks');
        } else {
          await _cacheBestEffort(_cache.mergeTasks(page.items), 'mergeTasks');
        }
      }
      lastListWasFromCache = false;
      return page;
    } on Failure catch (f) {
      if (!isOfflineWorthy(f)) rethrow;
      lastListWasFromCache = true;
      return _listFromCache(householdId, status: status);
    }
  }

  PaginatedResponse<Task> _listFromCache(String householdId, {String? status}) {
    var cached = _cache.getTasks(householdId).where((t) => !t.isDeleted).toList();
    if (status != null) {
      cached = cached.where((t) => t.status == status).toList();
    }
    return PaginatedResponse<Task>(
      items: cached,
      nextCursor: null,
      hasMore: false,
      total: cached.length,
    );
  }

  /// Create a task.
  ///
  /// One `Idempotency-Key` is generated per call and reused on every retry —
  /// including a later replay from the pending-operations queue — so the
  /// server (or a 401-refresh retry inside [ApiService]) never creates the
  /// same logical task twice (backend ADR-007).
  ///
  /// Offline (or a network-shaped failure from an online attempt): the task
  /// is assigned a local id, cached with `isSynced: false`, and queued for
  /// replay. The caller always gets a [Task] back — optimistic offline, real
  /// once synced — never a thrown offline error.
  Future<Task> create(String householdId, Map<String, dynamic> payload) async {
    final idempotencyKey = _uuid.v4();

    if (!await _connectivity.checkConnectivity()) {
      return _createOffline(householdId, payload, idempotencyKey);
    }
    try {
      final data = await _api.post(
        '/households/$householdId/tasks',
        body: payload,
        headers: {'Idempotency-Key': idempotencyKey},
      );
      final task = Task.fromJson(data as Map<String, dynamic>);
      await _cacheBestEffort(_cache.saveTask(task), 'saveTask');
      return task;
    } on Failure catch (f) {
      if (!isOfflineWorthy(f)) rethrow;
      return _createOffline(householdId, payload, idempotencyKey);
    }
  }

  Future<Task> _createOffline(
    String householdId,
    Map<String, dynamic> payload,
    String idempotencyKey,
  ) async {
    final localId = 'local-${_uuid.v4()}';
    final task = Task.fromJson({
      ...payload,
      'id': localId,
      'householdId': householdId,
      'isSynced': false,
    });
    await _cache.saveTask(task);
    await _cache.addPendingOperation(PendingOperation(
      id: _uuid.v4(),
      type: PendingOperationType.create,
      entity: PendingOperationEntity.task,
      householdId: householdId,
      entityId: localId,
      payload: payload,
      timestamp: DateTime.now(),
      idempotencyKey: idempotencyKey,
    ));
    return task;
  }

  /// Update a task. Same optimistic-offline pattern as [create]: merges
  /// [payload] over the cached copy, marks it unsynced, and queues the write.
  Future<Task> update(
    String householdId,
    String taskId,
    Map<String, dynamic> payload,
  ) async {
    if (await _connectivity.checkConnectivity()) {
      try {
        final data = await _api.patch(
          '/households/$householdId/tasks/$taskId',
          body: payload,
        );
        final task = Task.fromJson(data as Map<String, dynamic>);
        await _cacheBestEffort(_cache.saveTask(task), 'saveTask');
        return task;
      } on Failure catch (f) {
        if (!isOfflineWorthy(f)) rethrow;
      }
    }
    return _mutateOffline(householdId, taskId, payload);
  }

  /// Mark a task complete. Offline, this is queued as an update whose payload
  /// is exactly `{'status': 'completed'}` — [syncPendingOperations] recognizes
  /// that shape and replays it through the dedicated /complete endpoint
  /// rather than a generic PATCH, because only /complete triggers the next
  /// occurrence of a recurring task server-side.
  Future<Task> complete(String householdId, String taskId) async {
    if (await _connectivity.checkConnectivity()) {
      try {
        final task = await _completeRemote(householdId, taskId);
        await _cacheBestEffort(_cache.saveTask(task), 'saveTask');
        return task;
      } on Failure catch (f) {
        if (!isOfflineWorthy(f)) rethrow;
      }
    }
    return _mutateOffline(householdId, taskId, const {'status': 'completed'});
  }

  Future<Task> _completeRemote(String householdId, String taskId) async {
    final data = await _api.patch('/households/$householdId/tasks/$taskId/complete');
    return Task.fromJson(data as Map<String, dynamic>);
  }

  Future<Task> _mutateOffline(String householdId, String taskId, Map<String, dynamic> payload) async {
    final cached = _cache.getTasks(householdId).where((t) => t.id == taskId).toList();
    final base = cached.isEmpty ? null : cached.first;
    final merged = Task.fromJson({
      if (base != null) ...taskToCacheMap(base),
      ...payload,
      'id': taskId,
      'householdId': householdId,
      'isSynced': false,
    });
    await _cache.saveTask(merged);
    await _cache.addPendingOperation(PendingOperation(
      id: _uuid.v4(),
      type: PendingOperationType.update,
      entity: PendingOperationEntity.task,
      householdId: householdId,
      entityId: taskId,
      payload: payload,
      timestamp: DateTime.now(),
      idempotencyKey: _uuid.v4(),
    ));
    return merged;
  }

  /// Delete a task.
  ///
  /// Online: deletes remotely and from the cache, returns null. Offline: the
  /// row is kept in the cache with `isDeleted: true` (so it renders struck
  /// through instead of vanishing on an action the user cannot yet confirm
  /// happened) and the delete is queued; the caller gets that marked Task
  /// back rather than null, so it knows to keep showing it.
  Future<Task?> delete(String householdId, String taskId) async {
    if (await _connectivity.checkConnectivity()) {
      try {
        await _api.delete('/households/$householdId/tasks/$taskId');
        await _cacheBestEffort(_cache.deleteTaskFromCache(taskId), 'deleteTaskFromCache');
        return null;
      } on Failure catch (f) {
        if (!isOfflineWorthy(f)) rethrow;
      }
    }
    return _deleteOffline(householdId, taskId);
  }

  Future<Task> _deleteOffline(String householdId, String taskId) async {
    final cached = _cache.getTasks(householdId).where((t) => t.id == taskId).toList();
    final marked = (cached.isEmpty ? null : cached.first)?.copyWith(
          isDeleted: true,
          isSynced: false,
        ) ??
        Task(id: taskId, householdId: householdId, title: '', isSynced: false, isDeleted: true);
    await _cache.saveTask(marked);
    await _cache.addPendingOperation(PendingOperation(
      id: _uuid.v4(),
      type: PendingOperationType.delete,
      entity: PendingOperationEntity.task,
      householdId: householdId,
      entityId: taskId,
      payload: const {},
      timestamp: DateTime.now(),
      idempotencyKey: _uuid.v4(),
    ));
    return marked;
  }

  /// Restore a soft-deleted task (TD-009). Online-only, like
  /// [generateRecurringInstances]: undoing a delete from the trash view is a
  /// deliberate, in-the-moment action a user takes while looking at the app,
  /// not something that needs to survive being offline — a failure here is
  /// left to the caller rather than silently queued.
  Future<Task> restore(String householdId, String taskId) async {
    final data = await _api.post('/households/$householdId/tasks/$taskId/restore');
    final task = Task.fromJson(data as Map<String, dynamic>);
    await _cacheBestEffort(_cache.saveTask(task), 'saveTask');
    return task;
  }

  /// Catch-up: ask the server to generate missed recurring occurrences.
  /// Returns `{ generated, tasks }`. Online-only — nothing meaningful to do
  /// offline, so a failure here is left to the caller (catchUpRecurringTasks
  /// in TaskCubit already treats it as best-effort and swallows errors).
  Future<Map<String, dynamic>> generateRecurringInstances(String householdId) async {
    final data = await _api.post('/households/$householdId/tasks/generate-instances');
    return data as Map<String, dynamic>;
  }

  /// Hard-delete trash entries older than 30 days, backend default (TD-048,
  /// follow-up to TD-046's soft delete having no cleanup policy). Admin-only
  /// on the server — a non-admin call surfaces the 403 as a [Failure] to the
  /// caller. Returns how many tasks were purged. Online-only, same reasoning
  /// as [restore]: an explicit, in-the-moment destructive action, not
  /// something to queue for later.
  Future<int> purgeTrash(String householdId) async {
    final data = await _api.post('/households/$householdId/tasks/purge');
    return (data as Map<String, dynamic>)['deleted'] as int;
  }

  /// Replay every queued task operation against the server, in the order
  /// they were made. Returns how many were successfully applied.
  ///
  /// Stops (without discarding anything) at the first operation that still
  /// fails for a network-shaped reason — connectivity flickered back off
  /// mid-sync, or the backend is still down — leaving the rest of the queue
  /// untouched for the next reconnection. An operation the server genuinely
  /// rejects (not a network problem) gets up to 3 retries on later sync
  /// passes before being dropped and reported, so one permanently-invalid
  /// write cannot block everything queued after it forever.
  Future<int> syncPendingOperations() async {
    final ops = _cache
        .getPendingOperations()
        .where((o) => o.entity == PendingOperationEntity.task)
        .toList();

    // Local ids assigned during this repository's lifetime, replaced by the
    // server's real id once their create operation has synced — so a later
    // queued update/delete against the same not-yet-synced task resolves to
    // the id the server actually knows about.
    final idRemap = <String, String>{};
    var processed = 0;

    for (final op in ops) {
      final resolvedEntityId =
          op.entityId == null ? null : (idRemap[op.entityId] ?? op.entityId);

      try {
        switch (op.type) {
          case PendingOperationType.create:
            final data = await _api.post(
              '/households/${op.householdId}/tasks',
              body: op.payload,
              headers: {'Idempotency-Key': op.idempotencyKey},
            );
            final serverTask = Task.fromJson(data as Map<String, dynamic>);
            if (op.entityId != null) {
              idRemap[op.entityId!] = serverTask.id;
              await _cache.deleteTaskFromCache(op.entityId!);
            }
            await _cache.saveTask(serverTask);
            break;

          case PendingOperationType.update:
            final isCompletion =
                op.payload.length == 1 && op.payload['status'] == 'completed';
            final task = isCompletion
                ? await _completeRemote(op.householdId, resolvedEntityId!)
                : Task.fromJson(await _api.patch(
                    '/households/${op.householdId}/tasks/$resolvedEntityId',
                    body: op.payload,
                  ) as Map<String, dynamic>);
            await _cache.saveTask(task);
            break;

          case PendingOperationType.delete:
            await _api.delete('/households/${op.householdId}/tasks/$resolvedEntityId');
            await _cache.deleteTaskFromCache(resolvedEntityId!);
            break;
        }

        await _cache.removePendingOperation(op.id);
        processed++;
      } on Failure catch (f) {
        if (isOfflineWorthy(f)) {
          // Still unreachable — try the rest of this batch again next time.
          break;
        }
        final retried = op.copyWith(retryCount: op.retryCount + 1);
        if (retried.retryCount > 3) {
          await _cache.removePendingOperation(op.id);
          SentryService.captureException(f, context: {
            'pendingOperationId': op.id,
            'type': op.type.name,
            'entity': op.entity.name,
            'retryCount': retried.retryCount,
          });
        } else {
          await _cache.updatePendingOperation(retried);
        }
      } catch (e, stackTrace) {
        // A cache write failed (TD-059) — not a server Failure, so the
        // branches above never see it. The operation is deliberately NOT
        // discarded: replaying it on the next pass is safe because every
        // create carries an Idempotency-Key and the backend returns the
        // original resource with HTTP 200 without re-emitting socket events
        // (Hard Rule 13). Break rather than continue, for the same reason the
        // network branch does: if the disk is refusing writes, the rest of
        // this batch will fail the same way.
        SentryService.captureException(e, stackTrace: stackTrace, context: {
          'pendingOperationId': op.id,
          'type': op.type.name,
          'entity': op.entity.name,
          'policy': 'cache write failed mid-sync, queue preserved — TD-059',
        });
        break;
      }
    }

    return processed;
  }

  /// Await a cache write whose data the server already holds.
  ///
  /// A failed write here loses nothing the user can see: the entity came from
  /// (or was confirmed by) the server, so the next list refresh re-caches it.
  /// Failing the caller's operation because the local cache could not be
  /// updated would be worse than the problem — a user who cannot write to
  /// disk would also stop being able to READ from the network.
  ///
  /// So this is deliberately fire-and-forget, but reported: TD-059's whole
  /// point is that these failures used to be invisible. The write is issued
  /// by the caller (the Future arrives already started), which keeps Hive's
  /// synchronous in-memory visibility intact.
  Future<void> _cacheBestEffort(Future<void> write, String operation) async {
    try {
      await write;
    } catch (e, stackTrace) {
      SentryService.captureException(e, stackTrace: stackTrace, context: {
        'cacheOperation': operation,
        'policy': 'best-effort (server holds the data) — TD-059',
      });
    }
  }

}

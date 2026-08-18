import 'package:uuid/uuid.dart';

import '../../core/errors/failures.dart';
import '../../services/cache_service.dart';
import '../../services/connectivity_service.dart';
import '../../services/sentry_service.dart';
import '../datasources/remote/api_service.dart';
import '../models/paginated_response.dart';
import '../models/pending_operation.dart';
import '../models/shopping_item.dart';
import '../models/shopping_item_adapter.dart';

/// CRUD for household shopping items — cache-first reads, offline-queued
/// writes (TD-003). See TaskRepository for the detailed rationale; the
/// pattern is identical.
class ShoppingRepository {
  final ApiService _api;
  final Uuid _uuid;
  final CacheService _cache;
  final ConnectivityService _connectivity;

  ShoppingRepository(
    this._api, {
    Uuid? uuid,
    CacheService? cache,
    ConnectivityService? connectivity,
  })  : _uuid = uuid ?? const Uuid(),
        _cache = cache ?? CacheService(),
        _connectivity = connectivity ?? ConnectivityService();

  /// Whether the most recent [list] call served the cache fallback instead of
  /// a live server response — see TaskRepository.lastListWasFromCache.
  bool lastListWasFromCache = false;

  /// Fetch one page of items. Omit [cursor] for the first page. Falls back to
  /// the cache on a network-shaped failure (offline, timeout, 5xx) — see
  /// TaskRepository.list for why a cache fallback is always a single,
  /// complete page.
  Future<PaginatedResponse<ShoppingItem>> list(
    String householdId, {
    int limit = 50,
    String? cursor,
  }) async {
    try {
      final data = await _api.get(
        '/households/$householdId/shopping',
        query: {'limit': limit, if (cursor != null) 'cursor': cursor},
      );
      final page = PaginatedResponse<ShoppingItem>.fromJson(
        Map<String, dynamic>.from(data as Map),
        ShoppingItem.fromJson,
      );
      if (cursor == null) {
        await _cacheBestEffort(_cache.saveShopping(householdId, page.items), 'saveShopping');
      }
      lastListWasFromCache = false;
      return page;
    } on Failure catch (f) {
      if (!isOfflineWorthy(f)) rethrow;
      lastListWasFromCache = true;
      final cached = _cache.getShopping(householdId).where((i) => !i.isDeleted).toList();
      return PaginatedResponse<ShoppingItem>(
        items: cached,
        nextCursor: null,
        hasMore: false,
        total: cached.length,
      );
    }
  }

  /// Create an item, carrying one Idempotency-Key per call — reused on every
  /// retry, including a later replay from the queue — so a 401-refresh retry
  /// or a sync replay never adds the same item twice (ADR-007).
  ///
  /// Offline (or a network-shaped failure online): cached locally with
  /// `isSynced: false` and queued, same as TaskRepository.create.
  Future<ShoppingItem> create(
    String householdId,
    Map<String, dynamic> payload,
  ) async {
    final idempotencyKey = _uuid.v4();

    if (!await _connectivity.checkConnectivity()) {
      return _createOffline(householdId, payload, idempotencyKey);
    }
    try {
      final data = await _api.post(
        '/households/$householdId/shopping',
        body: payload,
        headers: {'Idempotency-Key': idempotencyKey},
      );
      final item = ShoppingItem.fromJson(data as Map<String, dynamic>);
      await _cacheBestEffort(_cache.saveShoppingItem(item), 'saveShoppingItem');
      return item;
    } on Failure catch (f) {
      if (!isOfflineWorthy(f)) rethrow;
      return _createOffline(householdId, payload, idempotencyKey);
    }
  }

  Future<ShoppingItem> _createOffline(
    String householdId,
    Map<String, dynamic> payload,
    String idempotencyKey,
  ) async {
    final localId = 'local-${_uuid.v4()}';
    final item = ShoppingItem.fromJson({
      ...payload,
      'id': localId,
      'householdId': householdId,
      'isSynced': false,
    });
    await _cache.saveShoppingItem(item);
    await _queueOfflineWrite(
      PendingOperation(
        id: _uuid.v4(),
        type: PendingOperationType.create,
        entity: PendingOperationEntity.shopping,
        householdId: householdId,
        entityId: localId,
        payload: payload,
        timestamp: DateTime.now(),
        idempotencyKey: idempotencyKey,
      ),
      entityId: localId,
      previous: null,
    );
    return item;
  }

  Future<ShoppingItem> update(
    String householdId,
    String itemId,
    Map<String, dynamic> payload,
  ) async {
    if (await _connectivity.checkConnectivity()) {
      try {
        final data = await _api.patch(
          '/households/$householdId/shopping/$itemId',
          body: payload,
        );
        final item = ShoppingItem.fromJson(data as Map<String, dynamic>);
        await _cacheBestEffort(_cache.saveShoppingItem(item), 'saveShoppingItem');
        return item;
      } on Failure catch (f) {
        if (!isOfflineWorthy(f)) rethrow;
      }
    }
    return _mutateOffline(householdId, itemId, payload);
  }

  /// Mark an item purchased. Offline, queued as an update whose payload is
  /// `{'isPurchased': true}` — unlike a task's completion, replaying that
  /// through the generic update endpoint on sync is equivalent to the
  /// dedicated /purchase endpoint (both set purchasedAt/purchasedBy the same
  /// way, and nothing here has a recurring-generation side effect to miss).
  Future<ShoppingItem> purchase(String householdId, String itemId) async {
    if (await _connectivity.checkConnectivity()) {
      try {
        final data = await _api.patch('/households/$householdId/shopping/$itemId/purchase');
        final item = ShoppingItem.fromJson(data as Map<String, dynamic>);
        await _cacheBestEffort(_cache.saveShoppingItem(item), 'saveShoppingItem');
        return item;
      } on Failure catch (f) {
        if (!isOfflineWorthy(f)) rethrow;
      }
    }
    return _mutateOffline(householdId, itemId, const {'isPurchased': true});
  }

  Future<ShoppingItem> _mutateOffline(
    String householdId,
    String itemId,
    Map<String, dynamic> payload,
  ) async {
    final cached = _cache.getShopping(householdId).where((i) => i.id == itemId).toList();
    final base = cached.isEmpty ? null : cached.first;
    final merged = mergeShoppingItemPayload(
      base: base,
      id: itemId,
      householdId: householdId,
      payload: payload,
      isSynced: false,
    );
    await _cache.saveShoppingItem(merged);
    await _queueOfflineWrite(
      PendingOperation(
        id: _uuid.v4(),
        type: PendingOperationType.update,
        entity: PendingOperationEntity.shopping,
        householdId: householdId,
        entityId: itemId,
        payload: payload,
        timestamp: DateTime.now(),
        idempotencyKey: _uuid.v4(),
      ),
      entityId: itemId,
      previous: base,
    );
    return merged;
  }

  /// Delete an item. Online: deletes remotely and from the cache, returns
  /// null. Offline: kept in the cache with `isDeleted: true` (struck through
  /// in the UI) and queued; the caller gets that marked item back so it knows
  /// to keep showing it rather than remove it optimistically.
  Future<ShoppingItem?> delete(String householdId, String itemId) async {
    if (await _connectivity.checkConnectivity()) {
      try {
        await _api.delete('/households/$householdId/shopping/$itemId');
        await _cacheBestEffort(_cache.deleteShoppingItemFromCache(itemId), 'deleteShoppingItemFromCache');
        return null;
      } on Failure catch (f) {
        if (!isOfflineWorthy(f)) rethrow;
      }
    }
    return _deleteOffline(householdId, itemId);
  }

  Future<ShoppingItem> _deleteOffline(String householdId, String itemId) async {
    final cached = _cache.getShopping(householdId).where((i) => i.id == itemId).toList();
    final previous = cached.isEmpty ? null : cached.first;
    final marked = previous?.copyWith(
          isDeleted: true,
          isSynced: false,
        ) ??
        ShoppingItem(
          id: itemId,
          householdId: householdId,
          name: '',
          isSynced: false,
          isDeleted: true,
        );
    await _cache.saveShoppingItem(marked);
    await _queueOfflineWrite(
      PendingOperation(
        id: _uuid.v4(),
        type: PendingOperationType.delete,
        entity: PendingOperationEntity.shopping,
        householdId: householdId,
        entityId: itemId,
        payload: const {},
        timestamp: DateTime.now(),
        idempotencyKey: _uuid.v4(),
      ),
      entityId: itemId,
      previous: previous,
    );
    return marked;
  }

  /// Replay every queued shopping operation against the server, in order.
  /// Returns how many were successfully applied. See
  /// TaskRepository.syncPendingOperations for the stop/retry/drop rules —
  /// identical here.
  Future<int> syncPendingOperations() async {
    final ops = _cache
        .getPendingOperations()
        .where((o) => o.entity == PendingOperationEntity.shopping)
        .toList();

    final idRemap = <String, String>{};
    var processed = 0;

    for (final op in ops) {
      final resolvedEntityId =
          op.entityId == null ? null : (idRemap[op.entityId] ?? op.entityId);

      try {
        switch (op.type) {
          case PendingOperationType.create:
            final data = await _api.post(
              '/households/${op.householdId}/shopping',
              body: op.payload,
              headers: {'Idempotency-Key': op.idempotencyKey},
            );
            final serverItem = ShoppingItem.fromJson(data as Map<String, dynamic>);
            if (op.entityId != null) {
              // Order matters and IS the fix (TD-057). The rewrite of the
              // queue has to be on disk BEFORE this create is retired,
              // because the create is the only thing that can reproduce the
              // translation. Retiring it first is what used to lose an
              // update/delete whenever the pass ended early — a network
              // break, a cache-write break, or the process simply being
              // killed — since the mapping lived in a local variable.
              //
              // Dying between the POST and this rewrite is safe: the create
              // stays queued and replays, and the Idempotency-Key makes the
              // server return the original resource with HTTP 200 without
              // re-emitting socket events (Hard Rule 13). Dying after it is
              // safe too: the rewrite is idempotent, so the replay finds
              // nothing left to remap.
              await _cache.remapPendingOperationEntityId(
                fromEntityId: op.entityId!,
                toEntityId: serverItem.id,
                entity: PendingOperationEntity.shopping,
              );
              idRemap[op.entityId!] = serverItem.id;
              await _cache.deleteShoppingItemFromCache(op.entityId!);
            }
            await _cache.saveShoppingItem(serverItem);
            break;

          case PendingOperationType.update:
            final data = await _api.patch(
              '/households/${op.householdId}/shopping/$resolvedEntityId',
              body: op.payload,
            );
            await _cache.saveShoppingItem(ShoppingItem.fromJson(data as Map<String, dynamic>));
            break;

          case PendingOperationType.delete:
            await _api.delete('/households/${op.householdId}/shopping/$resolvedEntityId');
            await _cache.deleteShoppingItemFromCache(resolvedEntityId!);
            break;
        }

        await _cache.removePendingOperation(op.id);
        processed++;
      } on Failure catch (f) {
        if (isOfflineWorthy(f)) break;
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
        // Same policy as TaskRepository.syncPendingOperations — see the
        // comment there. A failed cache write preserves the queue and breaks
        // the batch; replay is safe thanks to the Idempotency-Key.
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

  /// Shopping twin of TaskRepository._queueOfflineWrite — see the rationale
  /// there. Both halves of an optimistic offline write must land or neither.
  Future<void> _queueOfflineWrite(
    PendingOperation operation, {
    required String entityId,
    required ShoppingItem? previous,
  }) async {
    try {
      await _cache.addPendingOperation(operation);
    } catch (_) {
      try {
        if (previous != null) {
          await _cache.saveShoppingItem(previous);
        } else {
          await _cache.deleteShoppingItemFromCache(entityId);
        }
      } catch (rollbackError, stackTrace) {
        SentryService.captureException(rollbackError,
            stackTrace: stackTrace,
            context: {
              'entityId': entityId,
              'policy': 'offline-write rollback failed — TD-059',
            });
      }
      rethrow;
    }
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

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
        await _cache.saveShopping(householdId, page.items);
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
      await _cache.saveShoppingItem(item);
      return item;
    } on Failure catch (f) {
      if (!isOfflineWorthy(f)) rethrow;
      return _createOffline(householdId, payload, idempotencyKey);
    }
  }

  ShoppingItem _createOffline(
    String householdId,
    Map<String, dynamic> payload,
    String idempotencyKey,
  ) {
    final localId = 'local-${_uuid.v4()}';
    final item = ShoppingItem.fromJson({
      ...payload,
      'id': localId,
      'householdId': householdId,
      'isSynced': false,
    });
    _cache.saveShoppingItem(item);
    _cache.addPendingOperation(PendingOperation(
      id: _uuid.v4(),
      type: PendingOperationType.create,
      entity: PendingOperationEntity.shopping,
      householdId: householdId,
      entityId: localId,
      payload: payload,
      timestamp: DateTime.now(),
      idempotencyKey: idempotencyKey,
    ));
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
        await _cache.saveShoppingItem(item);
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
        await _cache.saveShoppingItem(item);
        return item;
      } on Failure catch (f) {
        if (!isOfflineWorthy(f)) rethrow;
      }
    }
    return _mutateOffline(householdId, itemId, const {'isPurchased': true});
  }

  ShoppingItem _mutateOffline(
    String householdId,
    String itemId,
    Map<String, dynamic> payload,
  ) {
    final cached = _cache.getShopping(householdId).where((i) => i.id == itemId).toList();
    final base = cached.isEmpty ? null : cached.first;
    final merged = ShoppingItem.fromJson({
      if (base != null) ...shoppingItemToCacheMap(base),
      ...payload,
      'id': itemId,
      'householdId': householdId,
      'isSynced': false,
    });
    _cache.saveShoppingItem(merged);
    _cache.addPendingOperation(PendingOperation(
      id: _uuid.v4(),
      type: PendingOperationType.update,
      entity: PendingOperationEntity.shopping,
      householdId: householdId,
      entityId: itemId,
      payload: payload,
      timestamp: DateTime.now(),
      idempotencyKey: _uuid.v4(),
    ));
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
        await _cache.deleteShoppingItemFromCache(itemId);
        return null;
      } on Failure catch (f) {
        if (!isOfflineWorthy(f)) rethrow;
      }
    }
    return _deleteOffline(householdId, itemId);
  }

  ShoppingItem _deleteOffline(String householdId, String itemId) {
    final cached = _cache.getShopping(householdId).where((i) => i.id == itemId).toList();
    final marked = (cached.isEmpty ? null : cached.first)?.copyWith(
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
    _cache.saveShoppingItem(marked);
    _cache.addPendingOperation(PendingOperation(
      id: _uuid.v4(),
      type: PendingOperationType.delete,
      entity: PendingOperationEntity.shopping,
      householdId: householdId,
      entityId: itemId,
      payload: const {},
      timestamp: DateTime.now(),
      idempotencyKey: _uuid.v4(),
    ));
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
      }
    }

    return processed;
  }
}

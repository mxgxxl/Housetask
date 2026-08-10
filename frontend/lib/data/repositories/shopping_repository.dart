import 'package:uuid/uuid.dart';

import '../datasources/remote/api_service.dart';
import '../models/paginated_response.dart';
import '../models/shopping_item.dart';

/// CRUD for household shopping items.
class ShoppingRepository {
  final ApiService _api;
  final Uuid _uuid;

  ShoppingRepository(this._api, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// Fetch one page of items. Omit [cursor] for the first page.
  Future<PaginatedResponse<ShoppingItem>> list(
    String householdId, {
    int limit = 50,
    String? cursor,
  }) async {
    final data = await _api.get(
      '/households/$householdId/shopping',
      query: {'limit': limit, if (cursor != null) 'cursor': cursor},
    );
    return PaginatedResponse<ShoppingItem>.fromJson(
      Map<String, dynamic>.from(data as Map),
      ShoppingItem.fromJson,
    );
  }

  /// Create an item, carrying one Idempotency-Key per call so a 401-refresh
  /// retry replays the same key instead of adding the item twice (ADR-007).
  Future<ShoppingItem> create(
    String householdId,
    Map<String, dynamic> payload,
  ) async {
    final data = await _api.post(
      '/households/$householdId/shopping',
      body: payload,
      headers: {'Idempotency-Key': _uuid.v4()},
    );
    return ShoppingItem.fromJson(data as Map<String, dynamic>);
  }

  Future<ShoppingItem> update(
    String householdId,
    String itemId,
    Map<String, dynamic> payload,
  ) async {
    final data =
        await _api.patch('/households/$householdId/shopping/$itemId', body: payload);
    return ShoppingItem.fromJson(data as Map<String, dynamic>);
  }

  Future<ShoppingItem> purchase(String householdId, String itemId) async {
    final data =
        await _api.patch('/households/$householdId/shopping/$itemId/purchase');
    return ShoppingItem.fromJson(data as Map<String, dynamic>);
  }

  Future<void> delete(String householdId, String itemId) async {
    await _api.delete('/households/$householdId/shopping/$itemId');
  }
}

import '../datasources/remote/api_service.dart';
import '../models/shopping_item.dart';

/// CRUD for household shopping items.
class ShoppingRepository {
  final ApiService _api;

  ShoppingRepository(this._api);

  Future<List<ShoppingItem>> list(String householdId) async {
    final data = await _api.get('/households/$householdId/shopping');
    return (data as List<dynamic>)
        .map((e) => ShoppingItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ShoppingItem> create(
    String householdId,
    Map<String, dynamic> payload,
  ) async {
    final data = await _api.post('/households/$householdId/shopping', body: payload);
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

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/errors/failures.dart';
import '../../data/models/shopping_item.dart';
import '../../data/repositories/shopping_repository.dart';

enum ShoppingStatusUi { initial, loading, loaded, error }

class ShoppingState extends Equatable {
  final ShoppingStatusUi status;
  final List<ShoppingItem> items;
  final String? error;

  /// Cursor for the next page, or null when the list is fully loaded.
  final String? nextCursor;

  /// Whether the server reported more rows after the last page.
  final bool hasMore;

  /// A page fetch is in flight; guards the scroll listener against re-entry.
  final bool isLoadingMore;

  /// Server-side total, captured from the first page (later pages send null).
  final int? total;

  const ShoppingState({
    this.status = ShoppingStatusUi.initial,
    this.items = const [],
    this.error,
    this.nextCursor,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.total,
  });

  List<ShoppingItem> get pending => items.where((i) => !i.isPurchased).toList();
  List<ShoppingItem> get purchased =>
      items.where((i) => i.isPurchased).toList();

  /// Group items by category for the grouped list UI.
  Map<String, List<ShoppingItem>> get byCategory {
    final map = <String, List<ShoppingItem>>{};
    for (final item in items) {
      map.putIfAbsent(item.category, () => []).add(item);
    }
    return map;
  }

  ShoppingState copyWith({
    ShoppingStatusUi? status,
    List<ShoppingItem>? items,
    String? error,
    String? nextCursor,
    bool? hasMore,
    bool? isLoadingMore,
    int? total,
  }) {
    return ShoppingState(
      status: status ?? this.status,
      items: items ?? this.items,
      error: error,
      // Explicitly nullable: reaching the last page must be able to clear it.
      nextCursor: nextCursor,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      total: total ?? this.total,
    );
  }

  @override
  List<Object?> get props =>
      [status, items, error, nextCursor, hasMore, isLoadingMore, total];
}

/// Manages the shopping list for the active household, including realtime sync.
class ShoppingCubit extends Cubit<ShoppingState> {
  final ShoppingRepository _repo;
  String? _householdId;

  ShoppingCubit(this._repo) : super(const ShoppingState());

  String? get householdId => _householdId;

  /// Load the FIRST page, replacing the list and resetting the cursor.
  Future<void> load(String householdId) async {
    _householdId = householdId;
    emit(state.copyWith(status: ShoppingStatusUi.loading, error: null));
    try {
      final page = await _repo.list(householdId);
      emit(state.copyWith(
        status: ShoppingStatusUi.loaded,
        items: _sorted(page.items),
        nextCursor: page.nextCursor,
        hasMore: page.hasMore,
        isLoadingMore: false,
        total: page.total,
      ));
    } on Failure catch (f) {
      emit(state.copyWith(status: ShoppingStatusUi.error, error: f.message));
    }
  }

  /// Append the next page. No-op when exhausted or already fetching.
  Future<void> loadMore() async {
    if (_householdId == null) return;
    if (!state.hasMore || state.isLoadingMore || state.nextCursor == null) return;

    emit(state.copyWith(
        nextCursor: state.nextCursor, isLoadingMore: true, error: null));
    try {
      final page = await _repo.list(_householdId!, cursor: state.nextCursor);
      emit(state.copyWith(
        status: ShoppingStatusUi.loaded,
        items: _sorted([...state.items, ...page.items]),
        nextCursor: page.nextCursor,
        hasMore: page.hasMore,
        isLoadingMore: false,
      ));
    } on Failure catch (f) {
      emit(state.copyWith(
        nextCursor: state.nextCursor,
        isLoadingMore: false,
        error: f.message,
      ));
    }
  }

  Future<void> refresh() async {
    if (_householdId != null) await load(_householdId!);
  }

  Future<void> createItem(Map<String, dynamic> payload) async {
    if (_householdId == null) return;
    try {
      final item = await _repo.create(_householdId!, payload);
      _upsert(item);
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    }
  }

  Future<void> updateItem(String itemId, Map<String, dynamic> payload) async {
    if (_householdId == null) return;
    try {
      final item = await _repo.update(_householdId!, itemId, payload);
      _upsert(item);
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    }
  }

  Future<void> togglePurchased(ShoppingItem item) async {
    if (_householdId == null) return;
    try {
      final updated = item.isPurchased
          ? await _repo.update(_householdId!, item.id, {'isPurchased': false})
          : await _repo.purchase(_householdId!, item.id);
      _upsert(updated);
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    }
  }

  Future<void> deleteItem(String itemId) async {
    if (_householdId == null) return;
    try {
      await _repo.delete(_householdId!, itemId);
      _remove(itemId);
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    }
  }

  void applyRealtime(String event, dynamic data) {
    if (data is! Map) return;
    final map = Map<String, dynamic>.from(data);

    if (_householdId != null &&
        map['householdId'] != null &&
        map['householdId'].toString() != _householdId) {
      return;
    }

    if (event == 'shopping:deleted') {
      _remove(map['id'].toString());
    } else {
      _upsert(ShoppingItem.fromJson(map));
    }
  }

  /// A total of null means "never fetched"; unknown ± 1 is still unknown, not
  /// 1, so it is left untouched until a real page arrives.
  int? _adjustedTotal({required int delta}) {
    if (state.total == null || delta == 0) return state.total;
    return state.total! + delta;
  }

  void _upsert(ShoppingItem item) {
    final list = List<ShoppingItem>.from(state.items);
    final idx = list.indexWhere((i) => i.id == item.id);
    final existed = idx >= 0;
    if (existed) {
      list[idx] = item;
    } else {
      list.add(item);
    }
    emit(state.copyWith(
      status: ShoppingStatusUi.loaded,
      items: _sorted(list),
      nextCursor: state.nextCursor,
      // Every item belongs to this single, unfiltered list, so a net-new
      // item is always +1; an in-place update (e.g. purchased toggling) never
      // changes membership, so the total is untouched.
      total: _adjustedTotal(delta: existed ? 0 : 1),
    ));
  }

  void _remove(String id) {
    final existed = state.items.any((i) => i.id == id);
    emit(state.copyWith(
      items: state.items.where((i) => i.id != id).toList(),
      nextCursor: state.nextCursor,
      total: _adjustedTotal(delta: existed ? -1 : 0),
    ));
  }

  /// Not-purchased first, then newest-ish (keeps insertion order otherwise).
  List<ShoppingItem> _sorted(List<ShoppingItem> items) {
    final copy = List<ShoppingItem>.from(items);
    copy.sort((a, b) {
      if (a.isPurchased != b.isPurchased) return a.isPurchased ? 1 : -1;
      return 0;
    });
    return copy;
  }
}

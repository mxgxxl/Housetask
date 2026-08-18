import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/errors/failures.dart';
import '../../data/models/shopping_item.dart';
import '../../data/models/shopping_item_adapter.dart';
import '../../data/repositories/shopping_repository.dart';
import '../../services/connectivity_service.dart';

enum ShoppingStatusUi { initial, loading, loaded, error }

/// Shown once (via BlocListener) after a mutation the repository could only
/// perform optimistically, offline (TD-003). Mirrors kOfflineNoticeMessage in
/// task_cubit.dart — kept separate so the two cubits stay independent.
/// See kLocalWriteErrorMessage in task_cubit.dart — same policy, same text.
const kShoppingLocalWriteErrorMessage =
    'No se pudo guardar en este dispositivo. Puede que no quede espacio.';

const kShoppingOfflineNoticeMessage =
    'Guardado offline, se sincronizará cuando haya conexión';

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

  /// True when the most recent [ShoppingCubit.load] fell back to the Hive
  /// cache instead of reaching the server (TD-003). Persists across
  /// mutations — unlike [error] — until the next load resolves either way.
  final bool isOffline;

  /// One-shot "saved offline" notice, mirroring [TaskState.offlineNotice].
  final String? offlineNotice;

  /// True while [ShoppingCubit.syncPending] is replaying the offline queue.
  final bool isSyncing;

  /// Ids with a mutation in flight (TD-007). Twin of TaskState.pendingIds —
  /// see the cross-ref note on the overlay helpers in ShoppingCubit.
  final Set<String> pendingIds;

  const ShoppingState({
    this.status = ShoppingStatusUi.initial,
    this.items = const [],
    this.error,
    this.nextCursor,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.total,
    this.isOffline = false,
    this.offlineNotice,
    this.isSyncing = false,
    this.pendingIds = const {},
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
    bool? isOffline,
    String? offlineNotice,
    bool? isSyncing,
    Set<String>? pendingIds,
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
      isOffline: isOffline ?? this.isOffline,
      offlineNotice: offlineNotice,
      isSyncing: isSyncing ?? this.isSyncing,
      pendingIds: pendingIds ?? this.pendingIds,
    );
  }

  @override
  List<Object?> get props => [
        status,
        items,
        error,
        nextCursor,
        hasMore,
        isLoadingMore,
        total,
        isOffline,
        offlineNotice,
        isSyncing,
        pendingIds,
      ];
}

/// Manages the shopping list for the active household, including realtime sync.
class ShoppingCubit extends Cubit<ShoppingState> {
  final ShoppingRepository _repo;
  final ConnectivityService _connectivity;
  String? _householdId;
  StreamSubscription<bool>? _connectivitySub;

  /// Last connectivity value seen, so the subscription can detect a
  /// false→true edge rather than firing on every emission.
  bool _wasOnline = true;

  ShoppingCubit(this._repo, {ConnectivityService? connectivity})
      : _connectivity = connectivity ?? ConnectivityService(),
        super(const ShoppingState()) {
    _connectivitySub = _connectivity.isOnline.listen((online) {
      if (online && !_wasOnline) {
        syncPending();
      }
      _wasOnline = online;
    });
  }

  @override
  Future<void> close() {
    _connectivitySub?.cancel();
    return super.close();
  }

  String? get householdId => _householdId;

  /// Drop every item and the active household — called on logout/session-
  /// expiry (TD-058), mirroring [TaskCubit.reset]. The connectivity
  /// subscription is left running (cubit-lifetime, torn down in [close]).
  void reset() {
    _householdId = null;
    emit(const ShoppingState());
  }

  /// Replay the queued offline operations, then refresh from the server if
  /// anything was actually applied — called automatically on reconnection.
  Future<void> syncPending() async {
    emit(state.copyWith(isSyncing: true));
    try {
      final processed = await _repo.syncPendingOperations();
      if (processed > 0 && _householdId != null) {
        await load(_householdId!);
      }
    } finally {
      emit(state.copyWith(isSyncing: false));
    }
  }

  /// Consume the one-shot [ShoppingState.offlineNotice] without disturbing
  /// [ShoppingState.error].
  void clearOfflineNotice() {
    emit(state.copyWith(error: state.error));
  }

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
        isOffline: _repo.lastListWasFromCache,
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
      _upsert(item, offlineNotice: item.isSynced ? null : kShoppingOfflineNoticeMessage);
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    } catch (_) {
      // Not a Failure: the repository could not persist the write
      // locally (TD-059). Caught here or it would escape the cubit
      // entirely and leave the UI with no feedback at all.
      emit(state.copyWith(error: kShoppingLocalWriteErrorMessage));
    }
  }

  Future<void> updateItem(String itemId, Map<String, dynamic> payload) async {
    if (_householdId == null) return;

    final previous = _findById(itemId);
    if (previous != null) {
      _applyOptimistic(
        mergeShoppingItemPayload(
          base: previous,
          id: itemId,
          householdId: _householdId!,
          payload: payload,
          isSynced: previous.isSynced,
        ),
        previous: previous,
      );
    }

    try {
      final item = await _repo.update(_householdId!, itemId, payload);
      _confirmOptimistic(itemId, item,
          offlineNotice: item.isSynced ? null : kShoppingOfflineNoticeMessage);
    } on Failure catch (f) {
      _rollbackOptimistic(itemId, errorMessage: f.message);
    } catch (_) {
      // Not a Failure: the repository could not persist the write
      // locally (TD-059). Caught here or it would escape the cubit
      // entirely and leave the UI with no feedback at all.
      _rollbackOptimistic(itemId, errorMessage: kShoppingLocalWriteErrorMessage);
    }
  }

  /// Toggle purchased, applied to the UI immediately (TD-007). This is the
  /// central gesture of the shopping list, so it is the one where waiting on
  /// a round trip is most noticeable.
  Future<void> togglePurchased(ShoppingItem item) async {
    if (_householdId == null) return;
    final target = !item.isPurchased;

    final previous = _findById(item.id);
    if (previous != null) {
      _applyOptimistic(
        mergeShoppingItemPayload(
          base: previous,
          id: item.id,
          householdId: _householdId!,
          payload: {'isPurchased': target},
          isSynced: previous.isSynced,
        ),
        previous: previous,
      );
    }

    try {
      final updated = target
          ? await _repo.purchase(_householdId!, item.id)
          : await _repo.update(_householdId!, item.id, {'isPurchased': false});
      _confirmOptimistic(item.id, updated,
          offlineNotice:
              updated.isSynced ? null : kShoppingOfflineNoticeMessage);
    } on Failure catch (f) {
      _rollbackOptimistic(item.id, errorMessage: f.message);
    } catch (_) {
      // Not a Failure: the repository could not persist the write
      // locally (TD-059). Caught here or it would escape the cubit
      // entirely and leave the UI with no feedback at all.
      _rollbackOptimistic(item.id,
          errorMessage: kShoppingLocalWriteErrorMessage);
    }
  }

  /// Online, the repository deletes for real and returns null — remove the
  /// row. Offline, it returns the item marked `isDeleted: true` — keep it
  /// upserted (struck through by the tile) instead of removing it.
  Future<void> deleteItem(String itemId) async {
    if (_householdId == null) return;
    try {
      final marked = await _repo.delete(_householdId!, itemId);
      if (marked != null) {
        _upsert(marked, offlineNotice: kShoppingOfflineNoticeMessage);
      } else {
        _remove(itemId);
      }
    } on Failure catch (f) {
      emit(state.copyWith(error: f.message));
    } catch (_) {
      // Not a Failure: the repository could not persist the write
      // locally (TD-059). Caught here or it would escape the cubit
      // entirely and leave the UI with no feedback at all.
      emit(state.copyWith(error: kShoppingLocalWriteErrorMessage));
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

  // ---- Optimistic mutation overlay (TD-007) ----
  //
  // Deliberate duplicate of TaskCubit's overlay: the two cubits share no base
  // class and their states differ in ways that matter here (see the emit-order
  // note below). KEEP BOTH COPIES IN SYNC — a change to one almost certainly
  // belongs in the other. See docs/TD-007-DESIGN.md; extracting a generic
  // mixin is filed as a pending improvement in IMPROVEMENTS.md.

  final Map<String, ShoppingItem?> _rollbackSnapshots = {};
  final Map<String, ShoppingItem> _optimisticApplied = {};

  void _applyOptimistic(ShoppingItem optimistic,
      {required ShoppingItem? previous}) {
    _rollbackSnapshots[optimistic.id] = previous;
    _optimisticApplied[optimistic.id] = optimistic;
    emit(state.copyWith(pendingIds: {...state.pendingIds, optimistic.id}));
    _upsert(optimistic);
  }

  /// NOTE on emit order — this differs from TaskCubit and the difference is
  /// load-bearing. ShoppingState.copyWith assigns `error` unconditionally
  /// (every emit clears it), while TaskState.copyWith preserves it. So here
  /// the error must be emitted LAST, whereas offlineNotice — cleared by both
  /// (TD-056) — must come from the final _upsert. Hence: confirm ends with
  /// _upsert, rollback ends with the error emit.
  void _confirmOptimistic(String id, ShoppingItem confirmed,
      {String? offlineNotice}) {
    _rollbackSnapshots.remove(id);
    _optimisticApplied.remove(id);
    emit(state.copyWith(pendingIds: state.pendingIds.difference({id})));
    _upsert(confirmed, offlineNotice: offlineNotice);
  }

  /// True when something replaced the entity since we applied it — another
  /// mutation, a socket event, a refresh. Rolling back over a newer value
  /// destroys work the user did, so a superseded mutation reports its error
  /// without undoing anything.
  bool _isSuperseded(String id) {
    final applied = _optimisticApplied[id];
    if (applied == null) return true;
    return _findById(id) != applied;
  }

  void _rollbackOptimistic(String id, {required String errorMessage}) {
    final superseded = _isSuperseded(id);
    final previous = _rollbackSnapshots.remove(id);
    _optimisticApplied.remove(id);

    if (!superseded) {
      if (previous != null) {
        _upsert(previous);
      } else {
        _remove(id);
      }
    }
    emit(state.copyWith(
      error: errorMessage,
      pendingIds: state.pendingIds.difference({id}),
    ));
  }

  ShoppingItem? _findById(String id) {
    for (final i in state.items) {
      if (i.id == id) return i;
    }
    return null;
  }

  void _upsert(ShoppingItem item, {String? offlineNotice}) {
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
      offlineNotice: offlineNotice,
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

import 'package:hive_flutter/hive_flutter.dart';

import '../data/models/household.dart';
import '../data/models/household_adapter.dart';
import '../data/models/pending_operation.dart';
import '../data/models/shopping_item.dart';
import '../data/models/shopping_item_adapter.dart';
import '../data/models/task.dart';
import '../data/models/task_adapter.dart';

/// Local persistence for offline-first reads and the pending-write queue
/// (TD-003).
///
/// All reads are synchronous: Hive keeps an open box's contents in memory, so
/// once [init] has run there is no `await` between "app wants cached tasks"
/// and "cached tasks are on screen" — this is what makes a cache-first
/// repository able to fall back instantly instead of showing a second
/// loading spinner.
class CacheService {
  CacheService._internal();
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;

  static const _tasksBoxName = 'tasks';
  static const _shoppingBoxName = 'shopping';
  static const _householdsBoxName = 'households';
  static const _pendingOperationsBoxName = 'pending_operations';

  Box<Task>? _tasksBox;
  Box<ShoppingItem>? _shoppingBox;
  Box<Household>? _householdsBox;
  Box<PendingOperation>? _pendingOperationsBox;

  bool _initialized = false;

  /// Register adapters and open every box. Safe to call more than once (a
  /// second call is a no-op) since main() and tests may both want to ensure
  /// it has run.
  ///
  /// [testDirectory] lets tests point Hive at a temp directory via
  /// `Hive.init()` instead of `Hive.initFlutter()`, which resolves the app
  /// documents directory through `path_provider` — a platform channel that
  /// is not available in a plain `flutter test` run. Production never passes
  /// it, so it always uses the real, platform-appropriate storage location.
  Future<void> init({String? testDirectory}) async {
    if (_initialized) return;

    if (testDirectory != null) {
      Hive.init(testDirectory);
    } else {
      await Hive.initFlutter();
    }

    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(TaskAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(ShoppingItemAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(HouseholdAdapter());
    if (!Hive.isAdapterRegistered(3)) Hive.registerAdapter(PendingOperationAdapter());

    _tasksBox = await Hive.openBox<Task>(_tasksBoxName);
    _shoppingBox = await Hive.openBox<ShoppingItem>(_shoppingBoxName);
    _householdsBox = await Hive.openBox<Household>(_householdsBoxName);
    _pendingOperationsBox =
        await Hive.openBox<PendingOperation>(_pendingOperationsBoxName);

    _initialized = true;
  }

  Box<Task> get _tasks {
    final box = _tasksBox;
    if (box == null) throw StateError('CacheService.init() has not run yet.');
    return box;
  }

  Box<ShoppingItem> get _shopping {
    final box = _shoppingBox;
    if (box == null) throw StateError('CacheService.init() has not run yet.');
    return box;
  }

  Box<Household> get _households {
    final box = _householdsBox;
    if (box == null) throw StateError('CacheService.init() has not run yet.');
    return box;
  }

  Box<PendingOperation> get _pendingOperations {
    final box = _pendingOperationsBox;
    if (box == null) throw StateError('CacheService.init() has not run yet.');
    return box;
  }

  // ---- Tasks ----

  /// Replace this household's cached tasks with [tasks], keyed by id.
  ///
  /// Only synced entries are cleared first: an unsynced task is a local
  /// write the server does not know about yet, so a fresh server list — which
  /// by definition cannot include it — must never be treated as authority to
  /// delete it from the cache. It is superseded normally once its own
  /// pending operation syncs and a later list refresh includes it for real.
  void saveTasks(String householdId, List<Task> tasks) {
    final staleKeys = _tasks.keys.where((k) {
      final cached = _tasks.get(k);
      return cached != null && cached.householdId == householdId && cached.isSynced;
    }).toList();
    for (final key in staleKeys) {
      _tasks.delete(key);
    }
    for (final task in tasks) {
      _tasks.put(task.id, task);
    }
  }

  List<Task> getTasks(String householdId) =>
      _tasks.values.where((t) => t.householdId == householdId).toList();

  /// Cache (or update) a single task, e.g. after an optimistic offline write.
  void saveTask(Task task) => _tasks.put(task.id, task);

  void deleteTaskFromCache(String id) => _tasks.delete(id);

  // ---- Shopping ----

  /// Same unsynced-preserving rule as [saveTasks].
  void saveShopping(String householdId, List<ShoppingItem> items) {
    final staleKeys = _shopping.keys.where((k) {
      final cached = _shopping.get(k);
      return cached != null && cached.householdId == householdId && cached.isSynced;
    }).toList();
    for (final key in staleKeys) {
      _shopping.delete(key);
    }
    for (final item in items) {
      _shopping.put(item.id, item);
    }
  }

  List<ShoppingItem> getShopping(String householdId) =>
      _shopping.values.where((i) => i.householdId == householdId).toList();

  void saveShoppingItem(ShoppingItem item) => _shopping.put(item.id, item);

  void deleteShoppingItemFromCache(String id) => _shopping.delete(id);

  // ---- Households ----

  void saveHousehold(Household household) => _households.put(household.id, household);

  List<Household> getHouseholds() => _households.values.toList();

  // ---- Pending operations queue ----

  void addPendingOperation(PendingOperation operation) =>
      _pendingOperations.put(operation.id, operation);

  /// Queued operations in the order they were made — replay must be FIFO so
  /// that, e.g., an update queued after its own create is applied to a
  /// resource that already exists once the create has gone through.
  List<PendingOperation> getPendingOperations() {
    final ops = _pendingOperations.values.toList();
    ops.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return ops;
  }

  void removePendingOperation(String id) => _pendingOperations.delete(id);

  void updatePendingOperation(PendingOperation operation) =>
      _pendingOperations.put(operation.id, operation);

  int get pendingOperationsCount => _pendingOperations.length;

  // ---- Logout ----

  /// Wipe every box. Called on logout so a subsequent login on the same
  /// device never surfaces the previous account's tasks, shopping items or
  /// queued writes.
  Future<void> clearAll() async {
    await Future.wait([
      _tasks.clear(),
      _shopping.clear(),
      _households.clear(),
      _pendingOperations.clear(),
    ]);
  }
}

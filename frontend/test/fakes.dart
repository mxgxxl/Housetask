import 'dart:async';

import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/shopping_item.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/repositories/shopping_repository.dart';
import 'package:homesync/data/repositories/task_repository.dart';
import 'package:homesync/services/cache_service.dart';
import 'package:homesync/services/connectivity_service.dart';
import 'package:homesync/services/notification_service.dart';

/// Hand-written fakes: the repositories are concrete classes with a single
/// collaborator, so implementing them directly is clearer than a mocking
/// framework and keeps the dependency list short.

Task buildTask(
  String id, {
  String title = 'Tarea',
  bool completed = false,
  DateTime? dueDate,
}) {
  return Task.fromJson({
    'id': id,
    'householdId': 'h1',
    'title': title,
    'status': completed ? 'completed' : 'pending',
    'priority': 'medium',
    'category': 'other',
    'assignedTo': const <dynamic>[],
    'isRecurring': false,
    if (dueDate != null) 'dueDate': dueDate.toIso8601String(),
  });
}

ShoppingItem buildItem(String id, {String name = 'Producto', bool purchased = false}) {
  return ShoppingItem.fromJson({
    'id': id,
    'householdId': 'h1',
    'name': name,
    'quantity': 1,
    'unit': 'uds',
    'category': 'other',
    'isPurchased': purchased,
    'isRecurring': false,
  });
}

/// A repository that replays a scripted sequence of pages and records calls.
class FakeTaskRepository implements TaskRepository {
  final List<PaginatedResponse<Task>> pages;
  final Failure? failListWith;
  final Failure? failCreateWith;

  /// Cursors received by [list], in order — lets a test assert paging.
  final List<String?> receivedCursors = [];

  /// `status` query params received by [list], in order — lets a test assert
  /// that each tab queries the server instead of filtering locally.
  final List<String?> receivedStatuses = [];

  /// Pages keyed by status param, for tests that drive several tabs. Falls
  /// back to [pages] when a status has no scripted queue.
  final Map<String?, List<PaginatedResponse<Task>>> pagesByStatus;

  final Map<String?, int> _callsByStatus = {};

  int listCalls = 0;

  /// Completed manually when non-null, so a test can hold a request open and
  /// fire a second loadMore() while the first is still in flight.
  final Future<void>? gate;

  /// Settable so a test can simulate "this load came from the offline
  /// cache" without actually going offline.
  @override
  bool lastListWasFromCache = false;

  FakeTaskRepository({
    this.pages = const [],
    this.pagesByStatus = const {},
    this.failListWith,
    this.failCreateWith,
    this.gate,
    this.offlineDeleteReturns,
    this.returnsUnsynced = false,
  });

  @override
  Future<PaginatedResponse<Task>> list(
    String householdId, {
    String? status,
    int limit = 50,
    String? cursor,
  }) async {
    receivedCursors.add(cursor);
    receivedStatuses.add(status);
    final index = listCalls;
    listCalls++;

    final scripted = pagesByStatus[status];
    if (scripted != null) {
      final n = _callsByStatus[status] ?? 0;
      _callsByStatus[status] = n + 1;
      if (gate != null) await gate;
      if (failListWith != null) throw failListWith!;
      return n < scripted.length ? scripted[n] : const PaginatedResponse.empty();
    }

    if (gate != null) await gate;
    if (failListWith != null) throw failListWith!;
    return index < pages.length ? pages[index] : const PaginatedResponse.empty();
  }

  /// When true, create/update return a task with isSynced: false — the shape
  /// the real repository returns for an optimistic offline write, which is
  /// what triggers the cubit's "saved offline" notice.
  final bool returnsUnsynced;

  @override
  Future<Task> create(String householdId, Map<String, dynamic> payload) async {
    if (failCreateWith != null) throw failCreateWith!;
    return buildTask('created', title: payload['title'] as String? ?? 'Tarea')
        .copyWith(isSynced: !returnsUnsynced);
  }

  @override
  Future<Task> update(String householdId, String taskId, Map<String, dynamic> payload) async =>
      buildTask(taskId).copyWith(isSynced: !returnsUnsynced);

  @override
  Future<Task> complete(String householdId, String taskId) async =>
      buildTask(taskId, completed: true);

  /// Non-null in a test that wants to assert the cubit's offline-delete
  /// handling (keep the row, struck through) instead of the online path
  /// (remove it outright).
  final Task? offlineDeleteReturns;

  @override
  Future<Task?> delete(String householdId, String taskId) async => offlineDeleteReturns;

  @override
  Future<Map<String, dynamic>> generateRecurringInstances(String householdId) async =>
      {'generated': 0, 'tasks': <dynamic>[]};

  /// How many times syncPendingOperations() was called — lets a test assert
  /// the cubit actually triggers a sync rather than merely holding the count.
  int syncCalls = 0;

  /// Operations "processed" by the next syncPendingOperations() call.
  int syncPendingOperationsResult = 0;

  @override
  Future<int> syncPendingOperations() async {
    syncCalls++;
    return syncPendingOperationsResult;
  }
}

class FakeShoppingRepository implements ShoppingRepository {
  final List<PaginatedResponse<ShoppingItem>> pages;
  final Failure? failListWith;
  final Failure? failCreateWith;

  final List<String?> receivedCursors = [];
  int listCalls = 0;
  final Future<void>? gate;

  final ShoppingItem? offlineDeleteReturns;
  final bool returnsUnsynced;

  @override
  bool lastListWasFromCache = false;

  FakeShoppingRepository({
    this.pages = const [],
    this.failListWith,
    this.failCreateWith,
    this.gate,
    this.offlineDeleteReturns,
    this.returnsUnsynced = false,
  });

  @override
  Future<PaginatedResponse<ShoppingItem>> list(
    String householdId, {
    int limit = 50,
    String? cursor,
  }) async {
    receivedCursors.add(cursor);
    final index = listCalls;
    listCalls++;
    if (gate != null) await gate;
    if (failListWith != null) throw failListWith!;
    return index < pages.length ? pages[index] : const PaginatedResponse.empty();
  }

  @override
  Future<ShoppingItem> create(String householdId, Map<String, dynamic> payload) async {
    if (failCreateWith != null) throw failCreateWith!;
    return buildItem('created', name: payload['name'] as String? ?? 'Producto')
        .copyWith(isSynced: !returnsUnsynced);
  }

  @override
  Future<ShoppingItem> update(
    String householdId,
    String itemId,
    Map<String, dynamic> payload,
  ) async =>
      buildItem(itemId, purchased: payload['isPurchased'] as bool? ?? false)
          .copyWith(isSynced: !returnsUnsynced);

  @override
  Future<ShoppingItem> purchase(String householdId, String itemId) async =>
      buildItem(itemId, purchased: true).copyWith(isSynced: !returnsUnsynced);

  @override
  Future<ShoppingItem?> delete(String householdId, String itemId) async =>
      offlineDeleteReturns;

  int syncCalls = 0;
  int syncPendingOperationsResult = 0;

  @override
  Future<int> syncPendingOperations() async {
    syncCalls++;
    return syncPendingOperationsResult;
  }
}

/// Controllable connectivity signal for cubit tests: no platform channel, no
/// timing surprises — the test drives transitions explicitly by adding to
/// [controller].
class FakeConnectivityService implements ConnectivityService {
  final StreamController<bool> controller = StreamController<bool>.broadcast();
  bool online = true;

  @override
  Stream<bool> get isOnline => controller.stream;

  @override
  Future<bool> checkConnectivity() async => online;
}

/// Notifications are a side effect the cubit tests do not care about.
class FakeNotificationService implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// Records whether logout wiped the offline cache (TD-003), without touching
/// Hive.
class FakeCacheService implements CacheService {
  int clearAllCalls = 0;

  @override
  Future<void> clearAll() async {
    clearAllCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

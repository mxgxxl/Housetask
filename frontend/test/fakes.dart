import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/shopping_item.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/repositories/shopping_repository.dart';
import 'package:homesync/data/repositories/task_repository.dart';
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
  int listCalls = 0;

  /// Completed manually when non-null, so a test can hold a request open and
  /// fire a second loadMore() while the first is still in flight.
  final Future<void>? gate;

  FakeTaskRepository({
    this.pages = const [],
    this.failListWith,
    this.failCreateWith,
    this.gate,
  });

  @override
  Future<PaginatedResponse<Task>> list(
    String householdId, {
    String? status,
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
  Future<Task> create(String householdId, Map<String, dynamic> payload) async {
    if (failCreateWith != null) throw failCreateWith!;
    return buildTask('created', title: payload['title'] as String? ?? 'Tarea');
  }

  @override
  Future<Task> update(String householdId, String taskId, Map<String, dynamic> payload) async =>
      buildTask(taskId);

  @override
  Future<Task> complete(String householdId, String taskId) async =>
      buildTask(taskId, completed: true);

  @override
  Future<void> delete(String householdId, String taskId) async {}

  @override
  Future<Map<String, dynamic>> generateRecurringInstances(String householdId) async =>
      {'generated': 0, 'tasks': <dynamic>[]};
}

class FakeShoppingRepository implements ShoppingRepository {
  final List<PaginatedResponse<ShoppingItem>> pages;
  final Failure? failListWith;
  final Failure? failCreateWith;

  final List<String?> receivedCursors = [];
  int listCalls = 0;
  final Future<void>? gate;

  FakeShoppingRepository({
    this.pages = const [],
    this.failListWith,
    this.failCreateWith,
    this.gate,
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
    return buildItem('created', name: payload['name'] as String? ?? 'Producto');
  }

  @override
  Future<ShoppingItem> update(
    String householdId,
    String itemId,
    Map<String, dynamic> payload,
  ) async =>
      buildItem(itemId, purchased: payload['isPurchased'] as bool? ?? false);

  @override
  Future<ShoppingItem> purchase(String householdId, String itemId) async =>
      buildItem(itemId, purchased: true);

  @override
  Future<void> delete(String householdId, String itemId) async {}
}

/// Notifications are a side effect the cubit tests do not care about.
class FakeNotificationService implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

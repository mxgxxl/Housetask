import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:hive_flutter/hive_flutter.dart';
import 'package:homesync/config/pet_config.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/economy.dart';
import 'package:homesync/data/models/economy_p1/economy_p1.dart';
import 'package:homesync/data/models/household.dart';
import 'package:homesync/data/models/household_stats.dart';
import 'package:homesync/data/models/member.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/pet.dart';
import 'package:homesync/data/models/shopping_item.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/models/user.dart';
import 'package:homesync/data/repositories/auth_repository.dart';
import 'package:homesync/data/repositories/economy_p1_repository.dart';
import 'package:homesync/data/repositories/household_repository.dart';
import 'package:homesync/data/repositories/pet_repository.dart';
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
  DateTime? startsAt,
  DateTime? endsAt,
  Map<String, dynamic>? completedBy,
  bool isRecurring = false,
  Map<String, dynamic>? recurrenceRule,
  List<Map<String, dynamic>>? assignedTo,
  String? parentTaskId,
  bool isDeleted = false,
  DateTime? deletedAt,
}) {
  return Task.fromJson({
    'id': id,
    'householdId': 'h1',
    'title': title,
    'status': completed ? 'completed' : 'pending',
    'priority': 'medium',
    'category': 'other',
    'assignedTo': assignedTo ?? const <dynamic>[],
    'isRecurring': isRecurring,
    if (recurrenceRule != null) 'recurrenceRule': recurrenceRule,
    if (parentTaskId != null) 'parentTaskId': parentTaskId,
    if (dueDate != null) 'dueDate': dueDate.toIso8601String(),
    if (startsAt != null) 'startsAt': startsAt.toIso8601String(),
    if (endsAt != null) 'endsAt': endsAt.toIso8601String(),
    if (completedBy != null) 'completedBy': completedBy,
    'isDeleted': isDeleted,
    if (deletedAt != null) 'deletedAt': deletedAt.toIso8601String(),
  });
}

/// Parses an ISO string payload value, or null if absent — used by
/// [FakeTaskRepository.create]/[update] to echo startsAt/endsAt back in the
/// returned Task, so a test can assert on what the cubit does with it (e.g.
/// scheduling a start reminder, PDR-004).
DateTime? _parseDate(dynamic value) => value == null ? null : DateTime.parse(value as String);

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

  /// Non-[Failure] error thrown by [create] — used to exercise the TD-059
  /// local-persistence branch, which is deliberately not a Failure.
  Object? throwOnCreate;

  /// Held open by a test that wants to observe the optimistic row before the
  /// server answers (TD-060).
  Future<void>? createGate;

  /// Cursors received by [list], in order — lets a test assert paging.
  final List<String?> receivedCursors = [];

  /// `status` query params received by [list], in order — lets a test assert
  /// that each tab queries the server instead of filtering locally.
  final List<String?> receivedStatuses = [];

  /// `from`/`to` received by [list], in order — lets a test assert the
  /// timeline window sent on each call (PDR-003).
  final List<DateTime?> receivedFrom = [];
  final List<DateTime?> receivedTo = [];

  /// Pages keyed by status param, for tests that drive several tabs. Falls
  /// back to [pages] when a status has no scripted queue.
  final Map<String?, List<PaginatedResponse<Task>>> pagesByStatus;

  /// Pages replayed in order for timeline calls (any call with `from` and/or
  /// `to` set) — kept separate from [pagesByStatus] so scripting the
  /// TaskFilter.all bucket's page(s) never gets consumed by loadTimeline(),
  /// and vice versa: the two are distinguishable by whether from/to are set,
  /// exactly like the real endpoint.
  final List<PaginatedResponse<Task>> timelinePages;

  int timelineListCalls = 0;

  /// TD-064: pages replayed for the dedicated `timeline`/`undated` endpoints,
  /// kept separate from [timelinePages] (which scripts the legacy
  /// `list(from:, to:)` walk) so a test can drive the old and the new path
  /// independently while both exist.
  final List<PaginatedResponse<Task>> keysetTimelinePages;
  final List<PaginatedResponse<Task>> undatedPages;

  /// Cursors and `from` received by [timeline]/[undatedTasks], in order.
  final List<String?> receivedTimelineCursors = [];
  final List<DateTime> receivedTimelineFrom = [];
  final List<String?> receivedUndatedCursors = [];

  int timelineCalls = 0;
  int undatedCalls = 0;

  /// Thrown by [timeline] once [timelineCalls] reaches this, so a test can let
  /// the first page succeed and fail a later one — the shape that matters for
  /// "a failed prefetch keeps the cursor and the content".
  Failure? failTimelineFrom;
  int failTimelineFromCall = 0;

  /// Mutable counterpart of [gate] for the keyset endpoints: a test needs to
  /// arm it AFTER the first page has landed, which a final field cannot do.
  Future<void>? timelineGate;

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
    this.timelinePages = const [],
    this.failListWith,
    this.failCreateWith,
    this.gate,
    this.offlineDeleteReturns,
    this.returnsUnsynced = false,
    this.syncGate,
    this.failRestoreWith,
    this.failPurgeWith,
    this.purgeResult = 0,
    this.keysetTimelinePages = const [],
    this.undatedPages = const [],
  });

  /// `includeDeleted` received by [list], in order — lets a test assert the
  /// trash view (TD-009) asks for deleted rows instead of relying on the
  /// default (excluded) list.
  final List<bool> receivedIncludeDeleted = [];

  @override
  Future<PaginatedResponse<Task>> timeline(
    String householdId, {
    required DateTime from,
    String? cursor,
    int limit = 50,
  }) async {
    receivedTimelineFrom.add(from);
    receivedTimelineCursors.add(cursor);
    final n = timelineCalls;
    timelineCalls++;
    if (gate != null) await gate;
    if (timelineGate != null) await timelineGate;
    if (failListWith != null) throw failListWith!;
    if (failTimelineFrom != null && n >= failTimelineFromCall) {
      throw failTimelineFrom!;
    }
    return n < keysetTimelinePages.length
        ? keysetTimelinePages[n]
        : const PaginatedResponse.empty();
  }

  @override
  Future<PaginatedResponse<Task>> undatedTasks(
    String householdId, {
    String? cursor,
    int limit = 50,
  }) async {
    receivedUndatedCursors.add(cursor);
    final n = undatedCalls;
    undatedCalls++;
    if (gate != null) await gate;
    if (timelineGate != null) await timelineGate;
    if (failListWith != null) throw failListWith!;
    return n < undatedPages.length ? undatedPages[n] : const PaginatedResponse.empty();
  }

  @override
  Future<PaginatedResponse<Task>> list(
    String householdId, {
    String? status,
    int limit = 50,
    String? cursor,
    DateTime? from,
    DateTime? to,
    bool includeDeleted = false,
  }) async {
    receivedCursors.add(cursor);
    receivedStatuses.add(status);
    receivedFrom.add(from);
    receivedTo.add(to);
    receivedIncludeDeleted.add(includeDeleted);

    if (from != null || to != null) {
      final n = timelineListCalls;
      timelineListCalls++;
      if (gate != null) await gate;
      if (failListWith != null) throw failListWith!;
      return n < timelinePages.length ? timelinePages[n] : const PaginatedResponse.empty();
    }

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

  /// Payloads received by [create]/[update], in order — lets a test assert
  /// exactly what TaskFormPage sent (e.g. startsAt/endsAt, PDR-004).
  final List<Map<String, dynamic>> receivedCreatePayloads = [];
  final List<Map<String, dynamic>> receivedUpdatePayloads = [];

  @override
  Future<Task> create(String householdId, Map<String, dynamic> payload) async {
    receivedCreatePayloads.add(payload);
    if (createGate != null) await createGate;
    if (throwOnCreate != null) throw throwOnCreate!;
    if (failCreateWith != null) throw failCreateWith!;
    return buildTask(
      'created',
      title: payload['title'] as String? ?? 'Tarea',
      // Echoes dueDate only when the payload actually sent one, same as
      // startsAt/endsAt below — a plain {'title': ...} payload (most existing
      // tests) still returns an undated task, e.g. task_cubit_test.dart's
      // "lands in Sin fecha" assertion.
      dueDate: _parseDate(payload['dueDate']),
      startsAt: _parseDate(payload['startsAt']),
      endsAt: _parseDate(payload['endsAt']),
    ).copyWith(isSynced: !returnsUnsynced);
  }

  @override
  Future<Task> update(String householdId, String taskId, Map<String, dynamic> payload) async {
    receivedUpdatePayloads.add(payload);
    return buildTask(
      taskId,
      startsAt: _parseDate(payload['startsAt']),
      endsAt: _parseDate(payload['endsAt']),
    ).copyWith(isSynced: !returnsUnsynced);
  }

  /// Held open by a test that wants to observe the optimistic state before
  /// the server answers (TD-007).
  Future<void>? completeGate;

  /// Thrown by [complete] — a Failure models a server rejection, any other
  /// object models the TD-059 local-persistence branch.
  Object? failCompleteWith;

  /// Returned by [complete] instead of the default, so a test can script the
  /// server's answer (e.g. isSynced:false for the fell-back-to-offline case).
  Task? completeReturns;

  @override
  Future<Task> complete(String householdId, String taskId) async {
    if (completeGate != null) await completeGate;
    if (failCompleteWith != null) throw failCompleteWith!;
    return completeReturns ?? buildTask(taskId, completed: true);
  }

  /// Non-null in a test that wants to assert the cubit's offline-delete
  /// handling (keep the row, struck through) instead of the online path
  /// (remove it outright).
  final Task? offlineDeleteReturns;

  /// Thrown by [delete] — Failure models a server rejection (TD-007).
  Object? failDeleteWith;

  @override
  Future<Task?> delete(String householdId, String taskId) async {
    if (failDeleteWith != null) throw failDeleteWith!;
    return offlineDeleteReturns;
  }

  /// Task ids passed to [restore], in order — lets a test assert exactly
  /// which row's "Restaurar" button was tapped.
  final List<String> restoreCalls = [];
  final Failure? failRestoreWith;

  @override
  Future<Task> restore(String householdId, String taskId) async {
    restoreCalls.add(taskId);
    if (failRestoreWith != null) throw failRestoreWith!;
    return buildTask(taskId, title: 'Restaurada');
  }

  @override
  Future<Map<String, dynamic>> generateRecurringInstances(String householdId) async =>
      {'generated': 0, 'tasks': <dynamic>[]};

  /// Household ids passed to [purgeTrash], in order — lets a test assert the
  /// "Vaciar papelera" button called the right household (TD-048).
  final List<String> purgeCalls = [];
  final Failure? failPurgeWith;

  /// Value [purgeTrash] returns when it doesn't throw.
  final int purgeResult;

  @override
  Future<int> purgeTrash(String householdId) async {
    purgeCalls.add(householdId);
    if (failPurgeWith != null) throw failPurgeWith!;
    return purgeResult;
  }

  /// How many times syncPendingOperations() was called — lets a test assert
  /// the cubit actually triggers a sync rather than merely holding the count.
  int syncCalls = 0;

  /// Operations "processed" by the next syncPendingOperations() call.
  int syncPendingOperationsResult = 0;

  /// Completed manually when non-null, so a test can observe the cubit's
  /// isSyncing:true window before letting the sync actually finish.
  final Future<void>? syncGate;

  @override
  Future<int> syncPendingOperations() async {
    syncCalls++;
    if (syncGate != null) await syncGate;
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
    this.syncGate,
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
    if (createGate != null) await createGate;
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

  /// Held open by a test that wants to observe the optimistic state before
  /// the server answers (TD-007).
  Future<void>? purchaseGate;

  /// Thrown by [purchase] — a Failure models a server rejection, any other
  /// object models the TD-059 local-persistence branch.
  Object? failPurchaseWith;

  /// Scripted answer, e.g. isSynced:false for the fell-back-to-offline case.
  ShoppingItem? purchaseReturns;

  @override
  Future<ShoppingItem> purchase(String householdId, String itemId) async {
    if (purchaseGate != null) await purchaseGate;
    if (failPurchaseWith != null) throw failPurchaseWith!;
    return purchaseReturns ??
        buildItem(itemId, purchased: true).copyWith(isSynced: !returnsUnsynced);
  }

  /// Held open by a test that wants to observe the optimistic row before the
  /// server answers (TD-060).
  Future<void>? createGate;

  /// Thrown by [delete] — Failure models a server rejection (TD-007).
  Object? failDeleteWith;

  @override
  Future<ShoppingItem?> delete(String householdId, String itemId) async {
    if (failDeleteWith != null) throw failDeleteWith!;
    return offlineDeleteReturns;
  }

  int syncCalls = 0;
  int syncPendingOperationsResult = 0;
  final Future<void>? syncGate;

  @override
  Future<int> syncPendingOperations() async {
    syncCalls++;
    if (syncGate != null) await syncGate;
    return syncPendingOperationsResult;
  }
}

/// Stands in for HouseholdRepository wherever a HouseholdCubit needs one to
/// construct but the test only cares about state it sets directly via
/// emit() — none of these methods are expected to be called.
class FakeHouseholdRepository implements HouseholdRepository {
  /// Stats keyed by period, configured by the test. [stats] throws
  /// [Failure] when the requested period has no entry.
  final Map<StatsPeriod, HouseholdStats> statsByPeriod;

  /// Every period requested via [stats], in call order — lets a test assert
  /// the period toggle actually refetches.
  final List<StatsPeriod> statsCalls = [];

  FakeHouseholdRepository({this.statsByPeriod = const {}});

  @override
  Future<Household> create(String name) async => throw UnimplementedError();

  @override
  Future<Household> getById(String id) async => throw UnimplementedError();

  @override
  Future<Household> join(String inviteCode) async => throw UnimplementedError();

  @override
  Future<List<Member>> members(String id) async => throw UnimplementedError();

  @override
  Future<Household> removeMember(String householdId, String userId) async =>
      throw UnimplementedError();

  @override
  Future<HouseholdStats> stats(String householdId, StatsPeriod period) async {
    statsCalls.add(period);
    final result = statsByPeriod[period];
    if (result == null) {
      throw const ServerFailure('No stats configured for this period');
    }
    return result;
  }

  @override
  Future<String?> currentHouseholdId() async => null;

  @override
  Future<void> setCurrentHouseholdId(String? id) async {}
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

/// Records start-reminder scheduling/cancellation (PDR-004) so a test can
/// assert exactly what TaskCubit asked for — unlike [FakeNotificationService],
/// whose blanket no-op via noSuchMethod cannot make that assertion.
class RecordingNotificationService implements NotificationService {
  final List<Task> scheduledStartReminders = [];
  final List<String> canceledStartReminderIds = [];

  @override
  Future<void> scheduleTaskStartReminder(Task task) async {
    scheduledStartReminders.add(task);
  }

  @override
  Future<void> cancelTaskStartReminder(String taskId) async {
    canceledStartReminderIds.add(taskId);
  }

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

Pet buildPet(
  String id, {
  String species = 'cat',
  String name = 'Michi',
  num hunger = 80,
  num mood = 80,
  DateTime? lastFedAt,
  DateTime? lastPlayedAt,
  List<String> cosmetics = const [],
  String? activeCosmetic,
}) {
  return Pet(
    id: id,
    householdId: 'h1',
    species: species,
    name: name,
    hunger: hunger,
    mood: mood,
    lastFedAt: lastFedAt,
    lastPlayedAt: lastPlayedAt,
    cosmetics: cosmetics,
    activeCosmetic: activeCosmetic,
  );
}

AdoptionRequest buildAdoptionRequest(
  String id, {
  String species = 'dog',
  String name = 'Firulais',
  String requestedBy = 'other-user',
}) {
  return AdoptionRequest(
    id: id,
    householdId: 'h1',
    species: species,
    name: name,
    requestedBy: requestedBy,
  );
}

/// Scriptable PetRepository (PDR-001 A3) — same hand-written-fake rationale
/// as FakeShoppingRepository/FakeTaskRepository: a single-collaborator
/// concrete class is clearer to implement directly than to mock.
class FakePetRepository implements PetRepository {
  Pet? pet;
  AdoptionRequest? pendingRequest;
  Economy economy;
  final Failure? failFeedWith;
  final Failure? failPlayWith;
  final Failure? failGetPetWith;

  int getPetCalls = 0;
  int getPendingAdoptionCalls = 0;
  int getEconomyCalls = 0;
  int feedCalls = 0;
  int playCalls = 0;
  int confirmCalls = 0;
  int cancelCalls = 0;
  final List<Map<String, String>> adoptCalls = [];
  final List<String> boughtCosmeticIds = [];
  final List<String> activeCosmeticCalls = [];

  FakePetRepository({
    this.pet,
    this.pendingRequest,
    this.economy = const Economy(),
    this.failFeedWith,
    this.failPlayWith,
    this.failGetPetWith,
  });

  @override
  Future<Pet?> getPet(String householdId) async {
    getPetCalls++;
    if (failGetPetWith != null) throw failGetPetWith!;
    return pet;
  }

  @override
  Future<AdoptionRequest?> getPendingAdoption(String householdId) async {
    getPendingAdoptionCalls++;
    return pendingRequest;
  }

  @override
  Future<Economy> getEconomy(String householdId) async {
    getEconomyCalls++;
    return economy;
  }

  @override
  Future<AdoptionRequest> adopt(
    String householdId, {
    required String species,
    required String name,
  }) async {
    adoptCalls.add({'species': species, 'name': name});
    final request = buildAdoptionRequest('req1', species: species, name: name, requestedBy: 'me');
    pendingRequest = request;
    return request;
  }

  @override
  Future<Pet> confirmAdopt(String householdId) async {
    confirmCalls++;
    final created = pet ??
        buildPet('pet1',
            species: pendingRequest?.species ?? 'cat', name: pendingRequest?.name ?? 'Mascota');
    pet = created;
    pendingRequest = null;
    return created;
  }

  @override
  Future<void> cancelAdopt(String householdId) async {
    cancelCalls++;
    pendingRequest = null;
  }

  @override
  Future<Pet> feed(String householdId) async {
    feedCalls++;
    if (failFeedWith != null) throw failFeedWith!;
    final fed = pet!.copyWith(hunger: 100, lastFedAt: DateTime.now());
    pet = fed;
    return fed;
  }

  @override
  Future<Pet> play(String householdId) async {
    playCalls++;
    if (failPlayWith != null) throw failPlayWith!;
    final played = pet!.copyWith(mood: 100, lastPlayedAt: DateTime.now());
    pet = played;
    return played;
  }

  @override
  Future<Pet> buyCosmetic(String householdId, String cosmeticId) async {
    boughtCosmeticIds.add(cosmeticId);
    // Mirrors the real backend deducting the price from the balance, so a
    // widget test asserting "buying decreases the shown balance" observes
    // the same effect it would against the real API.
    final price = kCosmeticsCatalog.firstWhere((c) => c.id == cosmeticId).price;
    economy = Economy(
      balance: economy.balance - price,
      dailyEarned: economy.dailyEarned,
      recentTransactions: economy.recentTransactions,
    );
    final updated = pet!.copyWith(cosmetics: [...pet!.cosmetics, cosmeticId]);
    pet = updated;
    return updated;
  }

  @override
  Future<Pet> setActiveCosmetic(String householdId, String cosmeticId) async {
    activeCosmeticCalls.add(cosmeticId);
    final updated = pet!.copyWith(activeCosmetic: cosmeticId);
    pet = updated;
    return updated;
  }
}

/// In-memory [Box] double that can be told to fail its writes (TD-059).
///
/// Reads are served from a plain map so a test can assert what survived a
/// failed write; `put`/`delete` either apply to that map (mirroring Hive's
/// synchronous in-memory keystore) or reject with [failure], depending on
/// [failWrites]. Everything the production code does not call falls through
/// to `noSuchMethod`.
class FakeBox<E> implements Box<E> {
  FakeBox({this.failWrites = false});

  /// Flip mid-test to make only *some* writes fail — e.g. let the entity
  /// write succeed and fail the pending-operation write, which is the
  /// rollback scenario.
  bool failWrites;

  /// Thrown (as a rejected Future) by every write while [failWrites] is set.
  Object failure = const FileSystemException('no space left on device');

  final Map<dynamic, E> entries = <dynamic, E>{};
  final StreamController<BoxEvent> _events = StreamController<BoxEvent>.broadcast();

  Future<void> _write(void Function() apply) {
    if (failWrites) return Future<void>.error(failure);
    apply();
    return Future<void>.value();
  }

  @override
  Future<void> put(dynamic key, E value) => _write(() {
        entries[key] = value;
        _events.add(BoxEvent(key, value, false));
      });

  @override
  Future<void> delete(dynamic key) => _write(() {
        entries.remove(key);
        _events.add(BoxEvent(key, null, true));
      });

  @override
  Future<int> clear() async {
    final removed = entries.length;
    entries.clear();
    return removed;
  }

  @override
  E? get(dynamic key, {E? defaultValue}) => entries[key] ?? defaultValue;

  @override
  Iterable<dynamic> get keys => entries.keys;

  @override
  Iterable<E> get values => entries.values;

  @override
  int get length => entries.length;

  @override
  Stream<BoxEvent> watch({dynamic key}) => _events.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Auth repository double for the cache-ownership tests (TD-062).
///
/// Every entry into an authenticated session resolves to the same [userId],
/// which is the only thing those tests care about: whether the cache belongs
/// to the user who is signing in.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({required this.userId, this.hasSessionResult = false});

  final String userId;
  final bool hasSessionResult;

  User get _user => User(
        id: userId,
        email: '$userId@test.com',
        name: userId,
        households: const [],
      );

  @override
  Future<User> login({required String email, required String password}) async => _user;

  @override
  Future<User> register({
    required String name,
    required String email,
    required String password,
  }) async =>
      _user;

  @override
  Future<User> getMe() async => _user;

  @override
  Future<User?> cachedUser() async => hasSessionResult ? _user : null;

  @override
  Future<bool> hasSession() async => hasSessionResult;

  @override
  Future<User> updateProfile({String? name, String? avatarUrl}) async => _user;

  @override
  Future<void> logout() async {}
}


// ── P1 economy (TD-066 F2) ────────────────────────────────────────────────

/// Builds a `PersonalEconomy` without spelling out every nested default.
///
/// [enabled] defaults to true because a fake that was off by default would
/// make most tests assert on a hidden section by accident.
PersonalEconomy buildPersonalEconomy({
  bool enabled = true,
  int balance = 0,
  int dailyReleased = 0,
  int remaining = 0,
  int level = 1,
  int xp = 0,
  int xpIntoLevel = 0,
  int xpForNextLevel = 0,
  int tasksCompleted = 0,
  List<String> unlocks = const [],
  int streakCurrent = 0,
  int streakLongest = 0,
  int iceReserve = 0,
  String weekKey = '2026-W35',
  int weeklyCap = 0,
  List<BudgetAllocation> allocations = const [],
}) {
  return PersonalEconomy(
    enabled: enabled,
    wallet: WalletPersonal(
      balance: balance,
      dailyReleased: dailyReleased,
      remaining: remaining,
    ),
    personalProgress: ProgressP1(
      xp: xp,
      level: level,
      unlocks: unlocks,
      tasksCompleted: tasksCompleted,
      xpIntoLevel: xpIntoLevel,
      xpForNextLevel: xpForNextLevel,
      xpToNextLevel: xpForNextLevel - xpIntoLevel,
    ),
    streak: PersonalStreak(
      current: streakCurrent,
      longest: streakLongest,
      iceReserve: iceReserve,
    ),
    weeklyBudget: PersonalBudget(
      weekKey: weekKey,
      weeklyCap: weeklyCap,
      allocations: allocations,
    ),
  );
}

/// Builds a `HouseholdEconomy` — the shared half (TD-066 F3).
///
/// [members] takes plain records so a test can spell a roster out inline; the
/// list is passed through in the order given, because JOIN ORDER is the thing
/// most of these tests are about (UX-P1-SPEC §0 rules out a leaderboard, and
/// re-sorting this list is all it would take to build one).
HouseholdEconomy buildHouseholdEconomy({
  bool enabled = true,
  int level = 1,
  int xp = 0,
  int xpIntoLevel = 0,
  int xpForNextLevel = 0,
  int tasksCompleted = 0,
  List<String> unlocks = const [],
  List<HouseholdMemberProgress> members = const [],
  SavingsGoal? activeSavingsGoal,
}) {
  return HouseholdEconomy(
    enabled: enabled,
    householdProgress: ProgressP1(
      xp: xp,
      level: level,
      unlocks: unlocks,
      tasksCompleted: tasksCompleted,
      xpIntoLevel: xpIntoLevel,
      xpForNextLevel: xpForNextLevel,
      xpToNextLevel: xpForNextLevel - xpIntoLevel,
    ),
    members: members,
    activeSavingsGoal: activeSavingsGoal,
  );
}

/// One roster row, in the shape the household endpoint sends.
HouseholdMemberProgress buildMemberProgress(
  String userId, {
  String name = '',
  int level = 1,
  int xp = 0,
  String? avatarUrl,
}) =>
    HouseholdMemberProgress(
      userId: userId,
      name: name.isEmpty ? userId : name,
      level: level,
      xp: xp,
      avatarUrl: avatarUrl,
    );

/// Both halves. `household.enabled` mirrors [enabled] because
/// `EconomyP1.enabled` requires BOTH, and a fake that left the household half
/// off would hide the section in every test for a reason the test never
/// mentioned.
EconomyP1 buildEconomyP1({
  bool enabled = true,
  PersonalEconomy? personal,
  HouseholdEconomy? household,
  DateTime? refreshedAt,
}) {
  return EconomyP1(
    personal: personal ?? buildPersonalEconomy(enabled: enabled),
    household: household ?? buildHouseholdEconomy(enabled: enabled),
    refreshedAt: refreshedAt ?? DateTime.utc(2026, 8, 30, 12),
  );
}

/// Only the members the F2 cubit actually calls are implemented; the savings
/// surface (F4) falls through to [noSuchMethod], which is enough to satisfy
/// the interface without pretending to model behaviour no test exercises.
class FakeEconomyP1Repository implements EconomyP1Repository {
  EconomyP1? economy;
  EconomyP1? cachedEconomy;

  /// Thrown by [load] when set — an offline read, or a server refusal.
  Object? loadError;

  /// Thrown by [buyIce] when set.
  Object? buyIceError;

  Map<String, dynamic> buyIceResult = const {};

  /// When set, [load] waits on it before answering — lets a test hold a
  /// response in flight while something else happens (a logout, a household
  /// switch) and assert the late answer is dropped.
  Completer<void>? loadGate;

  final List<String> loadedTimeZones = [];
  final List<String> buyIceOperationIds = [];
  int loadCalls = 0;

  @override
  bool lastLoadWasFromCache = false;

  FakeEconomyP1Repository({this.economy, this.cachedEconomy, this.loadError});

  @override
  Future<EconomyP1> load(String householdId, {required String timeZone}) async {
    loadCalls++;
    loadedTimeZones.add(timeZone);
    final gate = loadGate;
    if (gate != null) await gate.future;

    final error = loadError;
    if (error != null) {
      // Mirrors the real repository: a failed fetch falls back to the cache
      // and only rethrows when there is nothing cached to show.
      final fallback = cachedEconomy;
      if (fallback == null) throw error;
      lastLoadWasFromCache = true;
      return fallback;
    }

    lastLoadWasFromCache = false;
    return economy ?? buildEconomyP1();
  }

  @override
  EconomyP1? cached(String householdId) => cachedEconomy;

  @override
  Future<Map<String, dynamic>> buyIce(
    String householdId, {
    required String operationId,
  }) async {
    buyIceOperationIds.add(operationId);
    final error = buyIceError;
    if (error != null) throw error;
    return buyIceResult;
  }

  @override
  Future<void> clearCache(String householdId) async {}

  // The savings surface belongs to F4. Implemented explicitly rather than via
  // noSuchMethod so a test that reaches one by accident fails by name.

  @override
  Future<PersonalBudget> adjustBudget(
    String householdId, {
    required String timeZone,
    required String mode,
    String? weekKey,
    List<BudgetAllocation> allocations = const [],
  }) async =>
      throw UnimplementedError('adjustBudget is F4 surface');

  @override
  Future<SavingsGoal> createSavingsGoal(
    String householdId, {
    required String itemType,
    required String itemId,
    String? operationId,
  }) async =>
      throw UnimplementedError('createSavingsGoal is F4 surface');

  @override
  Future<SavingsGoal> contribute(
    String householdId,
    String goalId, {
    required int amount,
    required String operationId,
  }) async =>
      throw UnimplementedError('contribute is F4 surface');

  @override
  Future<SavingsGoal> cancelSavingsGoal(
    String householdId,
    String goalId, {
    required String operationId,
  }) async =>
      throw UnimplementedError('cancelSavingsGoal is F4 surface');
}

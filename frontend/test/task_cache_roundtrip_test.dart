import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:homesync/data/models/household.dart';
import 'package:homesync/data/models/household_adapter.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/models/task_adapter.dart';

import 'fakes.dart';

/// Reproduction of the blank-screen startup crash.
///
/// `Hive.openBox<Task>` deserializes every stored row through [TaskAdapter],
/// and Hive returns nested maps as `_Map<dynamic, dynamic>` at EVERY level.
/// `taskFromCacheMap` only fixes the top level (`Map<String, dynamic>.from`),
/// so anything nested inside a cached task is still untyped when
/// `Task.fromJson` reaches it:
///
///   - `recurrenceRule` is a HARD CAST (`as Map<String, dynamic>`), so it
///     throws. The throw escapes `CacheService.init()`, `runApp` is never
///     reached, and — because `SentryService.captureException` is a silent
///     no-op without a DSN — the app shows a blank screen with no output.
///     It is also permanent: the bad row stays on disk, so every relaunch
///     fails identically. That is why hot reload and hot restart do not help.
///   - `assignedTo` / `createdBy` / `completedBy` go through `User.fromRef`,
///     whose `value is Map<String, dynamic>` test is FALSE for the same
///     reason. It does not throw; it silently builds a User whose id is a
///     stringified map. Cheaper to spot, worse to trust.
///
/// The tests below round-trip through a CLOSED and REOPENED box on purpose:
/// Hive serves values from memory once written, so a same-session read never
/// touches the adapter and would pass while production crashes.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('homesync_cache_roundtrip');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(TaskAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(HouseholdAdapter());
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Write [task], then close and reopen Hive so the value comes back off disk
  /// through the adapter — the exact path `CacheService.init()` takes.
  Future<Task> roundTrip(Task task) async {
    final box = await Hive.openBox<Task>('tasks');
    await box.put(task.id, task);
    await Hive.close();

    Hive.init(tempDir.path);
    final reopened = await Hive.openBox<Task>('tasks');
    return reopened.get(task.id)!;
  }

  test('a task with no nested data round-trips (the case that always worked)',
      () async {
    final restored = await roundTrip(buildTask('plain', title: 'Sacar basura'));

    expect(restored.id, 'plain');
    expect(restored.title, 'Sacar basura');
  });

  test('a RECURRING task round-trips — this is the startup crash', () async {
    // Any household that ever cached a recurring task poisons its own box:
    // from then on `Hive.openBox<Task>` throws before the UI can start.
    final recurring = buildTask(
      'recurrente',
      isRecurring: true,
      recurrenceRule: const {'type': 'weekly', 'interval': 1, 'daysOfWeek': [1, 3]},
    );

    final restored = await roundTrip(recurring);

    expect(restored.isRecurring, isTrue);
    expect(restored.recurrenceRule, isNotNull);
    expect(restored.recurrenceRule!.type, 'weekly');
  });

  test('a household with MEMBERS round-trips — the same crash, one box later',
      () async {
    // Fixing only Task would have moved the blank screen rather than removed
    // it: CacheService.init() opens the households box right after the tasks
    // box, and every household has members, so this fired on any device that
    // had ever cached one.
    final household = Household.fromJson(const {
      'id': 'h1',
      'name': 'Casa',
      'inviteCode': 'ABCD1234',
      'createdBy': 'u1',
      'members': [
        {
          'user': {'id': 'u1', 'name': 'Ana', 'email': 'ana@test.com'},
          'role': 'admin',
        },
      ],
    });

    final box = await Hive.openBox<Household>('households');
    await box.put(household.id, household);
    await Hive.close();

    Hive.init(tempDir.path);
    final reopened = await Hive.openBox<Household>('households');
    final restored = reopened.get('h1')!;

    expect(restored.members, hasLength(1));
    expect(restored.members.single.role, 'admin');
    expect(restored.members.single.user.name, 'Ana');
  });

  test('an ASSIGNED task keeps its assignee instead of a stringified map',
      () async {
    // The silent half: no throw, but the User comes back with the whole map
    // rendered into its id, so avatars and the "Ex-miembro" check (Hard Rule
    // 16) are reading garbage offline.
    final assigned = buildTask(
      'asignada',
      assignedTo: [
        {'id': 'u1', 'name': 'Ana', 'email': 'ana@test.com'},
      ],
    );

    final restored = await roundTrip(assigned);

    expect(restored.assignedTo, hasLength(1));
    expect(restored.assignedTo.single.id, 'u1');
    expect(restored.assignedTo.single.name, 'Ana');
  });
}

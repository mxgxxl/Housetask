import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/pending_operation.dart';
import 'package:homesync/presentation/cubit/shopping_cubit.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';
import 'package:homesync/presentation/pages/main_scaffold.dart';
import 'package:homesync/services/cache_service.dart';

import '../fakes.dart';

/// Pumps just [OfflineBanner] with the two cubits it reads — the widget under
/// test is a StatelessWidget with no dependency on MainScaffold's own state
/// (household, tab index, the five pages), so there is no reason to stand
/// all of that up to exercise it.
Widget _host(
    {required TaskCubit taskCubit, required ShoppingCubit shoppingCubit}) {
  return MaterialApp(
    home: Scaffold(
      body: MultiBlocProvider(
        providers: [
          BlocProvider<TaskCubit>.value(value: taskCubit),
          BlocProvider<ShoppingCubit>.value(value: shoppingCubit),
        ],
        child: const OfflineBanner(),
      ),
    ),
  );
}

void main() {
  late Directory tempDir;

  // OfflineBanner reads CacheService().pendingOperationsCount, which throws
  // until init() has run — same temp-directory pattern as
  // cache_service_test.dart, so the queue-size assertions exercise the real
  // Hive box rather than a mock.
  setUpAll(() async {
    tempDir =
        await Directory.systemTemp.createTemp('homesync_offline_banner_test');
    await CacheService().init(testDirectory: tempDir.path);
  });

  tearDown(() async {
    await CacheService().clearAll();
  });

  tearDownAll(() async {
    // Deliberately no Hive.close() here: this file is the only one that
    // leaves a live box.watch() subscriber behind (via OfflineBanner's
    // StreamBuilder), and pairing that with Hive.close() reproducibly
    // deadlocked the test runner — close() appears to wait on the watch
    // stream's listener count reaching zero, which races against
    // StreamBuilder's own async disposal. Deleting the temp directory is
    // enough cleanup; the process exits shortly after this test file anyway.
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  PendingOperation pendingOp(String id) => PendingOperation(
        id: id,
        type: PendingOperationType.create,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        payload: const {'title': 'x'},
        timestamp: DateTime.utc(2026, 1, 1),
        idempotencyKey: 'key-$id',
      );

  testWidgets(
      'shows the yellow offline banner when TaskCubit.isOffline is true',
      (tester) async {
    final taskCubit = TaskCubit(
      FakeTaskRepository()..lastListWasFromCache = true,
      FakeNotificationService(),
    );
    await taskCubit.load('h1');
    final shoppingCubit = ShoppingCubit(FakeShoppingRepository());

    await tester
        .pumpWidget(_host(taskCubit: taskCubit, shoppingCubit: shoppingCubit));
    await tester.pump();

    expect(find.text('Sin conexión — cambios guardados localmente'),
        findsOneWidget);
  });

  testWidgets('no banner at all when neither cubit is offline', (tester) async {
    final taskCubit =
        TaskCubit(FakeTaskRepository(), FakeNotificationService());
    await taskCubit.load('h1');
    final shoppingCubit = ShoppingCubit(FakeShoppingRepository());

    await tester
        .pumpWidget(_host(taskCubit: taskCubit, shoppingCubit: shoppingCubit));
    await tester.pump();

    expect(
        find.text('Sin conexión — cambios guardados localmente'), findsNothing);
  });

  testWidgets('shows no pending-count badge when the queue is empty',
      (tester) async {
    final taskCubit = TaskCubit(
      FakeTaskRepository()..lastListWasFromCache = true,
      FakeNotificationService(),
    );
    await taskCubit.load('h1');
    final shoppingCubit = ShoppingCubit(FakeShoppingRepository());

    await tester
        .pumpWidget(_host(taskCubit: taskCubit, shoppingCubit: shoppingCubit));
    await tester.pump();

    // The banner itself is up (sanity check the precondition), but nothing
    // in it looks like a queue-count badge.
    expect(find.text('Sin conexión — cambios guardados localmente'),
        findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets(
      'shows a badge with the exact pending-count when the queue is non-empty',
      (tester) async {
    CacheService().addPendingOperation(pendingOp('a'));
    CacheService().addPendingOperation(pendingOp('b'));
    CacheService().addPendingOperation(pendingOp('c'));

    final taskCubit = TaskCubit(
      FakeTaskRepository()..lastListWasFromCache = true,
      FakeNotificationService(),
    );
    await taskCubit.load('h1');
    final shoppingCubit = ShoppingCubit(FakeShoppingRepository());

    await tester
        .pumpWidget(_host(taskCubit: taskCubit, shoppingCubit: shoppingCubit));
    await tester.pump();

    expect(find.text('3'), findsOneWidget);
  });

  testWidgets(
      'shows the syncing spinner while TaskCubit.syncPending is in flight',
      (tester) async {
    final gate = Completer<void>();
    final taskRepo = FakeTaskRepository(syncGate: gate.future)
      ..lastListWasFromCache = true;
    final taskCubit = TaskCubit(taskRepo, FakeNotificationService());
    await taskCubit.load('h1');
    final shoppingCubit = ShoppingCubit(FakeShoppingRepository());

    await tester
        .pumpWidget(_host(taskCubit: taskCubit, shoppingCubit: shoppingCubit));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // syncPending() sets TaskCubit.state.isSyncing synchronously before
    // awaiting the repository (checked directly since that part needs no
    // pump at all), but BlocProvider's own notification to `context.watch`
    // is delivered a microtask later, and OfflineBanner's rebuild is a
    // frame after that — two pumps to actually see it mid-flight in the
    // widget tree.
    final syncFuture = taskCubit.syncPending();
    expect(taskCubit.state.isSyncing, isTrue);
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await syncFuture;
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
      'renders exactly one banner when TaskCubit and ShoppingCubit are offline simultaneously',
      (tester) async {
    final taskCubit = TaskCubit(
      FakeTaskRepository()..lastListWasFromCache = true,
      FakeNotificationService(),
    );
    await taskCubit.load('h1');
    final shoppingCubit =
        ShoppingCubit(FakeShoppingRepository()..lastListWasFromCache = true);
    await shoppingCubit.load('h1');

    await tester
        .pumpWidget(_host(taskCubit: taskCubit, shoppingCubit: shoppingCubit));
    await tester.pump();

    // Both cubits report offline; the banner combines them with || rather
    // than rendering one per cubit, so exactly one must appear, not two.
    expect(find.text('Sin conexión — cambios guardados localmente'),
        findsOneWidget);
  });
}

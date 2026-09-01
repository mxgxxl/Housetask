import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/presentation/cubit/household_economy_cubit.dart';
import 'package:homesync/services/device_timezone_service.dart';

import '../fakes.dart';
import '../savings_goal_writes_test.dart' show buildGoal, readyHousehold;
import 'savings_goal_actions_test.dart' show household, personal, pumpSection;

/// «Cancelar meta» (TD-066 F4, PDR-018).
///
/// The only action in P1 that moves OTHER people's money, which is what every
/// assertion below is really about:
///
///  * It is offered to the goal's creator or a household admin and to nobody
///    else — the same rule the backend enforces with a 403.
///  * It confirms first, and the confirmation says what will happen to the
///    coins (UX-P1-SPEC §4: «la confirmación de cancelación avisa del
///    reembolso»).
///  * Offline it is refused with an explanation, never queued: a cancel
///    writes a refund per contributor, and replaying that under
///    last-write-wins would pay everyone twice (TD-066-DESIGN §7).

void main() {
  // Any `load()` these tests trigger consults DeviceTimeZoneService. Left
  // unmocked, that platform-channel round trip runs inside `testWidgets`'
  // fake-async zone and deadlocks the test — the same shape as TD-040.
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(DeviceTimeZoneService.channelName),
      (call) async => 'Europe/Madrid',
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(DeviceTimeZoneService.channelName),
      null,
    );
  });

  group('who is offered the button', () {
    testWidgets('the goal creator is', (tester) async {
      final cubits = await pumpSection(
        tester,
        // currentUserId is 'u1' and so is the goal's createdBy.
        householdState: household(goal: buildGoal(createdBy: 'u1')),
        personalState: personal(),
      );

      expect(find.text('Cancelar meta'), findsOneWidget);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('an admin who did not create it is', (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal(createdBy: 'someone-else'))
            .copyWith(currentUserIsAdmin: true),
        personalState: personal(),
      );

      expect(find.text('Cancelar meta'), findsOneWidget);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('an ordinary member who did not create it is NOT',
        (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal(createdBy: 'someone-else')),
        personalState: personal(),
      );

      // Absent, not greyed. The money in the goal belongs to everyone who put
      // some in, and a disabled control they never asked about is noise.
      expect(find.text('Cancelar meta'), findsNothing);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('nobody is, once the goal is unlocked', (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState:
            household(goal: buildGoal(createdBy: 'u1', status: 'unlocked')),
        personalState: personal(),
      );

      // There is nothing left to dissolve: the item is bought.
      expect(find.text('Cancelar meta'), findsNothing);
      await cubits.house.close();
      await cubits.wallet.close();
    });
  });

  group('the confirmation', () {
    testWidgets('warns about the refund before anything happens',
        (tester) async {
      final repo = FakeEconomyP1Repository();
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal(createdBy: 'u1')),
        personalState: personal(),
        repo: repo,
      );

      await tester.tap(find.text('Cancelar meta'));
      await tester.pumpAndSettle();

      expect(find.text('¿Cancelar la meta?'), findsOneWidget);
      // UX-P1-SPEC §4: the confirmation warns of the refund.
      expect(
        find.textContaining('reembolsará a todos los que aportaron'),
        findsOneWidget,
      );
      // Nothing has been sent yet.
      expect(repo.cancelledGoalIds, isEmpty);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('«Volver» cancels nothing', (tester) async {
      final repo = FakeEconomyP1Repository();
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal(createdBy: 'u1')),
        personalState: personal(),
        repo: repo,
      );
      await cubits.house.load('h1');
      cubits.house.emit(household(goal: buildGoal(createdBy: 'u1')));
      await tester.pump();

      await tester.tap(find.text('Cancelar meta'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Volver'));
      await tester.pumpAndSettle();

      expect(repo.cancelledGoalIds, isEmpty);
      expect(cubits.house.state.activeSavingsGoal, isNotNull);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('confirming cancels the goal and clears it', (tester) async {
      final repo = FakeEconomyP1Repository();
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal(id: 'g7', createdBy: 'u1')),
        personalState: personal(),
        repo: repo,
      );
      await cubits.house.load('h1');
      cubits.house.emit(household(goal: buildGoal(id: 'g7', createdBy: 'u1')));
      await tester.pump();

      await tester.tap(find.text('Cancelar meta'));
      await tester.pumpAndSettle();
      // Scoped to the dialog: the section's own button carries the same text.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Cancelar meta'),
        ),
      );
      await tester.pumpAndSettle();

      expect(repo.cancelledGoalIds, ['g7']);
      expect(repo.cancelOperationIds.single, isNotEmpty);
      expect(cubits.house.state.activeSavingsGoal, isNull);
      // Back to the empty state, CTA and all.
      expect(find.text('Elegid algo para los dos'), findsOneWidget);
      await cubits.house.close();
      await cubits.wallet.close();
    });
  });

  group('offline', () {
    testWidgets('disables the button and says why', (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState:
            household(goal: buildGoal(createdBy: 'u1'), isOnline: false),
        personalState: personal(),
      );

      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Cancelar meta'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(find.text('Sin conexión: no se puede cancelar ahora'), findsOneWidget);
      await cubits.house.close();
      await cubits.wallet.close();
    });
  });

  group('cubit rules', () {
    HouseholdEconomyCubit cubitWith(FakeEconomyP1Repository repo,
            {FakeConnectivityService? connectivity}) =>
        HouseholdEconomyCubit(
          repo,
          connectivity: connectivity ?? FakeConnectivityService(),
        );

    test('cancelGoalReason says why, in order', () {
      final goal = buildGoal(createdBy: 'u1');
      expect(
        readyHousehold(goal: goal, enabled: false).cancelGoalReason,
        GoalCancelUnavailableReason.flagOff,
      );
      expect(
        readyHousehold(goal: goal).copyWith(isCancellingGoal: true).cancelGoalReason,
        GoalCancelUnavailableReason.inFlight,
      );
      expect(
        readyHousehold().cancelGoalReason,
        GoalCancelUnavailableReason.noGoal,
      );
      expect(
        readyHousehold(goal: buildGoal(createdBy: 'u1', status: 'unlocked'))
            .cancelGoalReason,
        GoalCancelUnavailableReason.goalInactive,
      );
      expect(
        readyHousehold(goal: buildGoal(createdBy: 'other')).cancelGoalReason,
        GoalCancelUnavailableReason.notAllowed,
      );
      expect(
        readyHousehold(goal: goal, isOnline: false).cancelGoalReason,
        GoalCancelUnavailableReason.offline,
      );
      expect(readyHousehold(goal: goal).cancelGoalReason,
          GoalCancelUnavailableReason.none);
    });

    test('an admin may cancel a goal they did not create', () {
      expect(
        readyHousehold(goal: buildGoal(createdBy: 'other'), isAdmin: true)
            .cancelGoalReason,
        GoalCancelUnavailableReason.none,
      );
    });

    test('refuses offline instead of queueing the refunds', () async {
      // A cancel writes a refund entry per contributor; replaying that under
      // last-write-wins would pay everyone twice (TD-066-DESIGN §7).
      final repo = FakeEconomyP1Repository();
      final connectivity = FakeConnectivityService()..online = false;
      final cubit = cubitWith(repo, connectivity: connectivity);
      await cubit.load('h1');
      cubit.emit(readyHousehold(goal: buildGoal(createdBy: 'u1')));

      await cubit.cancelGoal();

      expect(repo.cancelledGoalIds, isEmpty);
      expect(cubit.state.activeSavingsGoal, isNotNull);
      expect(cubit.state.actionError, contains('Sin conexión'));
      await cubit.close();
    });

    test('does nothing for a member who may not cancel', () async {
      final repo = FakeEconomyP1Repository();
      final cubit = cubitWith(repo);
      await cubit.load('h1');
      cubit.emit(readyHousehold(goal: buildGoal(createdBy: 'someone-else')));

      await cubit.cancelGoal();

      expect(repo.cancelledGoalIds, isEmpty);
      await cubit.close();
    });

    test('translates a 403 into Spanish rather than passing it through',
        () async {
      final repo = FakeEconomyP1Repository();
      repo.cancelGoalError = const ServerFailure(
        'Only the goal creator or a household admin can cancel it',
        statusCode: 403,
      );
      final cubit = cubitWith(repo);
      await cubit.load('h1');
      cubit.emit(readyHousehold(goal: buildGoal(createdBy: 'u1')));

      await cubit.cancelGoal();

      expect(
        cubit.state.actionError,
        'Solo quien creó la meta o un admin puede cancelarla.',
      );
      // The goal stays: nothing was cancelled.
      expect(cubit.state.activeSavingsGoal, isNotNull);
      await cubit.close();
    });

    test('a 409 means someone got there first, and refetches', () async {
      final repo = FakeEconomyP1Repository(
        economy: buildEconomyP1(household: buildHouseholdEconomy()),
      );
      repo.cancelGoalError = const ConflictFailure('Operation already in progress');
      final cubit = cubitWith(repo);
      await cubit.load('h1');
      cubit.emit(readyHousehold(goal: buildGoal(createdBy: 'u1')));

      await cubit.cancelGoal();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(cubit.state.actionError, 'Esta meta ya no está activa.');
      // The read is what settles whether it was unlocked or already cancelled.
      expect(cubit.state.activeSavingsGoal, isNull);
      await cubit.close();
    });

    test('carries one operation id per logical cancel', () async {
      final repo = FakeEconomyP1Repository();
      final cubit = cubitWith(repo);
      await cubit.load('h1');
      cubit.emit(readyHousehold(goal: buildGoal(createdBy: 'u1')));

      await cubit.cancelGoal();

      // A cancel is a resource-creating POST under Hard Rule 13: it writes a
      // refund entry per contributor.
      expect(repo.cancelOperationIds, hasLength(1));
      expect(repo.cancelOperationIds.single, isNotEmpty);
      await cubit.close();
    });
  });
}

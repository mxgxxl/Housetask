import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/economy_p1/economy_p1.dart';
import 'package:homesync/presentation/cubit/economy_p1_cubit.dart';
import 'package:homesync/presentation/cubit/household_economy_cubit.dart';
import 'package:homesync/services/device_timezone_service.dart';

import 'fakes.dart';

/// The joint savings goal's WRITES (TD-066 F4, PDR-018).
///
/// The properties worth pinning here are the ones where being wrong costs
/// somebody coins:
///
///  * The price never leaves the client. A goal saves toward a catalog item
///    and the server prices it; if `targetCoins` were client-supplied, a
///    household would unlock a 40 🪙 cosmetic by asking for a target of 1.
///  * «Never overspend», against a LIVE balance. The cap is the lower of the
///    wallet and what the goal still needs, re-applied at write time — the
///    slider that produced the amount was built from a balance a socket event
///    may have moved since.
///  * Nothing is queued offline. A debit replayed under last-write-wins pays
///    twice for one tap (TD-066-DESIGN §7), so offline is a refusal with an
///    explanation, never a pending operation.

void _mockTimeZone(String? id) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel(DeviceTimeZoneService.channelName),
    (call) async => call.method == DeviceTimeZoneService.methodName ? id : null,
  );
}

void _clearTimeZoneMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel(DeviceTimeZoneService.channelName),
    null,
  );
}

SavingsGoal buildGoal({
  String id = 'g1',
  int targetCoins = 100,
  int contributedCoins = 60,
  String status = 'active',
  String createdBy = 'u1',
  List<SavingsContributor> contributions = const [],
}) =>
    SavingsGoal(
      id: id,
      itemType: 'cosmetic',
      itemId: 'glasses',
      targetCoins: targetCoins,
      contributedCoins: contributedCoins,
      status: status,
      createdBy: createdBy,
      contributions: contributions,
    );

EconomyP1State readyPersonal({
  int balance = 100,
  bool isOnline = true,
  bool isContributing = false,
}) =>
    EconomyP1State(
      status: EconomyP1Status.ready,
      enabled: true,
      isOnline: isOnline,
      isContributing: isContributing,
      wallet: WalletPersonal(balance: balance, dailyReleased: 10, remaining: 30),
    );

HouseholdEconomyState readyHousehold({
  SavingsGoal? goal,
  bool isOnline = true,
  bool isAdmin = false,
  String? currentUserId = 'u1',
  bool enabled = true,
}) =>
    HouseholdEconomyState(
      status: HouseholdEconomyStatus.ready,
      enabled: enabled,
      isOnline: isOnline,
      currentUserId: currentUserId,
      currentUserIsAdmin: isAdmin,
      activeSavingsGoal: goal,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => _mockTimeZone('Europe/Madrid'));
  tearDown(_clearTimeZoneMock);

  EconomyP1Cubit personalCubit(
    FakeEconomyP1Repository repo, {
    FakeConnectivityService? connectivity,
  }) =>
      EconomyP1Cubit(
        repo,
        timeZone: DeviceTimeZoneService(),
        connectivity: connectivity ?? FakeConnectivityService(),
      );

  HouseholdEconomyCubit householdCubit(
    FakeEconomyP1Repository repo, {
    FakeConnectivityService? connectivity,
  }) =>
      HouseholdEconomyCubit(
        repo,
        timeZone: DeviceTimeZoneService(),
        connectivity: connectivity ?? FakeConnectivityService(),
      );

  group('maxContributionFor', () {
    test('is capped by the wallet — never overspend', () {
      final state = readyPersonal(balance: 15);
      expect(
        state.maxContributionFor(buildGoal(targetCoins: 100, contributedCoins: 0)),
        15,
      );
    });

    test('is capped by what the goal still needs — never overshoot', () {
      // PDR-018 refunds a CANCELLED goal, not an overshoot on one that
      // unlocks: coins put in beyond the price are simply gone.
      final state = readyPersonal(balance: 100);
      expect(
        state.maxContributionFor(buildGoal(targetCoins: 100, contributedCoins: 96)),
        4,
      );
    });

    test('floors at zero for a fully funded goal', () {
      final state = readyPersonal(balance: 100);
      expect(
        state.maxContributionFor(buildGoal(targetCoins: 100, contributedCoins: 100)),
        0,
      );
    });
  });

  group('contributeReasonFor', () {
    final goal = buildGoal();

    test('says why, in the order the member can act on', () {
      expect(
        readyPersonal().copyWith(enabled: false).contributeReasonFor(goal),
        ContributeUnavailableReason.flagOff,
      );
      expect(
        readyPersonal(isContributing: true).contributeReasonFor(goal),
        ContributeUnavailableReason.inFlight,
      );
      expect(
        readyPersonal().contributeReasonFor(null),
        ContributeUnavailableReason.noGoal,
      );
      // An unlocked goal says so rather than complaining about coins.
      expect(
        readyPersonal(balance: 0).contributeReasonFor(buildGoal(status: 'unlocked')),
        ContributeUnavailableReason.goalInactive,
      );
      expect(
        readyPersonal(balance: 0).contributeReasonFor(goal),
        ContributeUnavailableReason.insufficientCoins,
      );
      expect(
        readyPersonal(isOnline: false).contributeReasonFor(goal),
        ContributeUnavailableReason.offline,
      );
      expect(
        readyPersonal().contributeReasonFor(goal),
        ContributeUnavailableReason.none,
      );
    });
  });

  group('contributeToGoal', () {
    test('debits the wallet and hands the goal to the household cubit',
        () async {
      final repo = FakeEconomyP1Repository();
      repo.goalResult = buildGoal(contributedCoins: 85);
      final cubit = personalCubit(repo);
      SavingsGoal? handedOn;
      cubit.onGoalChanged = (goal) => handedOn = goal;

      await cubit.load('h1');
      cubit.emit(readyPersonal(balance: 100));
      await cubit.contributeToGoal(buildGoal(contributedCoins: 60), 25);

      expect(repo.contributedAmounts, [25]);
      expect(cubit.state.wallet.balance, 75);
      expect(cubit.state.isContributing, isFalse);
      // The write happened on the personal cubit because it owns the wallet;
      // what it produced is household state, handed over rather than held.
      expect(handedOn?.contributedCoins, 85);
      await cubit.close();
    });

    test('re-clamps the amount against the live balance', () async {
      // The slider was built from a balance a socket event has since moved —
      // a completion crediting coins, or another device spending them. The
      // last word belongs where the truth lives.
      final repo = FakeEconomyP1Repository();
      final cubit = personalCubit(repo);
      await cubit.load('h1');
      cubit.emit(readyPersonal(balance: 12));

      await cubit.contributeToGoal(buildGoal(targetCoins: 100, contributedCoins: 0), 40);

      expect(repo.contributedAmounts, [12]);
      expect(cubit.state.wallet.balance, 0);
      await cubit.close();
    });

    test('re-clamps against what the goal still needs', () async {
      final repo = FakeEconomyP1Repository();
      final cubit = personalCubit(repo);
      await cubit.load('h1');
      cubit.emit(readyPersonal(balance: 100));

      await cubit.contributeToGoal(buildGoal(targetCoins: 100, contributedCoins: 97), 50);

      expect(repo.contributedAmounts, [3]);
      await cubit.close();
    });

    test('carries one operation id per logical contribution', () async {
      final repo = FakeEconomyP1Repository();
      final cubit = personalCubit(repo);
      await cubit.load('h1');
      cubit.emit(readyPersonal(balance: 100));

      await cubit.contributeToGoal(buildGoal(), 5);
      cubit.emit(readyPersonal(balance: 95));
      await cubit.contributeToGoal(buildGoal(), 5);

      // Distinct per tap — a shared id would make the second contribution
      // replay the first's stored response instead of moving any coins.
      expect(repo.contributeOperationIds, hasLength(2));
      expect(repo.contributeOperationIds.toSet(), hasLength(2));
      expect(repo.contributeOperationIds.first, isNotEmpty);
      await cubit.close();
    });

    test('refuses offline instead of queueing the debit', () async {
      // TD-066-DESIGN §7: a debit replayed under last-write-wins pays twice
      // for one tap, so nothing is queued until that is designed.
      final repo = FakeEconomyP1Repository();
      final connectivity = FakeConnectivityService()..online = false;
      final cubit = personalCubit(repo, connectivity: connectivity);
      await cubit.load('h1');
      // isOnline still true in state: the stream can lag a transition, which
      // is exactly why the write re-checks on the hot path.
      cubit.emit(readyPersonal(balance: 100));

      await cubit.contributeToGoal(buildGoal(), 10);

      expect(repo.contributedAmounts, isEmpty);
      expect(cubit.state.wallet.balance, 100);
      expect(cubit.state.actionError, contains('Sin conexión'));
      await cubit.close();
    });

    test('does nothing when the goal no longer accepts contributions',
        () async {
      final repo = FakeEconomyP1Repository();
      final cubit = personalCubit(repo);
      await cubit.load('h1');
      cubit.emit(readyPersonal(balance: 100));

      await cubit.contributeToGoal(buildGoal(status: 'unlocked'), 10);

      expect(repo.contributedAmounts, isEmpty);
      await cubit.close();
    });

    test('translates a 409 into what actually happened', () async {
      // ApiService flattens every 409 into "operation already in progress",
      // which for a contribution is actively wrong: what happened is that
      // someone else's coins reached the price a moment earlier.
      final repo = FakeEconomyP1Repository();
      repo.contributeError = const ConflictFailure('Operation already in progress');
      final cubit = personalCubit(repo);
      await cubit.load('h1');
      cubit.emit(readyPersonal(balance: 100));

      await cubit.contributeToGoal(buildGoal(), 10);

      expect(cubit.state.actionError, 'Esta meta ya no acepta aportaciones.');
      expect(cubit.state.isContributing, isFalse);
      // The wallet is untouched: nothing was spent.
      expect(cubit.state.wallet.balance, 100);
      await cubit.close();
    });

    test('translates a 403 into a coins message, in Spanish', () async {
      // The backend says «Not enough coins: your balance is 12» — English, in
      // a Spanish app.
      final repo = FakeEconomyP1Repository();
      repo.contributeError =
          const ServerFailure('Not enough coins: your balance is 12', statusCode: 403);
      final cubit = personalCubit(repo);
      await cubit.load('h1');
      cubit.emit(readyPersonal(balance: 100));

      await cubit.contributeToGoal(buildGoal(), 10);

      expect(cubit.state.actionError, 'No tienes monedas suficientes para esa aportación.');
      await cubit.close();
    });
  });

  group('createGoalReason', () {
    test('says why', () {
      expect(
        readyHousehold(enabled: false).createGoalReason,
        GoalCreateUnavailableReason.flagOff,
      );
      expect(
        readyHousehold().copyWith(isCreatingGoal: true).createGoalReason,
        GoalCreateUnavailableReason.inFlight,
      );
      // PDR-018: one active goal at a time.
      expect(
        readyHousehold(goal: buildGoal()).createGoalReason,
        GoalCreateUnavailableReason.goalExists,
      );
      // An UNLOCKED goal is not an active one, and does not block a new goal
      // server-side either — the partial unique index only covers `active`.
      expect(
        readyHousehold(goal: buildGoal(status: 'unlocked')).createGoalReason,
        GoalCreateUnavailableReason.none,
      );
      expect(
        readyHousehold(isOnline: false).createGoalReason,
        GoalCreateUnavailableReason.offline,
      );
      expect(readyHousehold().createGoalReason, GoalCreateUnavailableReason.none);
    });
  });

  group('createGoal', () {
    test('sends the item and never a price', () async {
      final repo = FakeEconomyP1Repository();
      repo.goalResult = buildGoal(targetCoins: 40, contributedCoins: 0);
      final cubit = householdCubit(repo);
      await cubit.load('h1');
      cubit.emit(readyHousehold());

      await cubit.createGoal(itemType: 'cosmetic', itemId: 'glasses');

      // itemType/itemId only. The repository's signature has no room for a
      // target, which is the point: the server prices the item.
      expect(repo.createGoalCalls, [
        {'itemType': 'cosmetic', 'itemId': 'glasses'}
      ]);
      expect(cubit.state.activeSavingsGoal?.targetCoins, 40);
      expect(cubit.state.isCreatingGoal, isFalse);
      await cubit.close();
    });

    test('refuses offline instead of queueing', () async {
      final repo = FakeEconomyP1Repository();
      final connectivity = FakeConnectivityService()..online = false;
      final cubit = householdCubit(repo, connectivity: connectivity);
      await cubit.load('h1');
      cubit.emit(readyHousehold());

      await cubit.createGoal(itemType: 'cosmetic', itemId: 'glasses');

      expect(repo.createGoalCalls, isEmpty);
      expect(cubit.state.actionError, contains('Sin conexión'));
      await cubit.close();
    });

    test('does nothing while a goal is already active', () async {
      final repo = FakeEconomyP1Repository();
      final cubit = householdCubit(repo);
      await cubit.load('h1');
      cubit.emit(readyHousehold(goal: buildGoal()));

      await cubit.createGoal(itemType: 'cosmetic', itemId: 'hat');

      expect(repo.createGoalCalls, isEmpty);
      await cubit.close();
    });

    test('a 400 for an unknown item explains itself instead of crashing',
        () async {
      // Reachable in practice: the client's catalog is a hand-kept mirror of
      // the server's (pet_config.dart), so the two can drift.
      final repo = FakeEconomyP1Repository();
      repo.createGoalError =
          const ServerFailure('Unknown cosmetic: dragon_skin', statusCode: 400);
      final cubit = householdCubit(repo);
      await cubit.load('h1');
      cubit.emit(readyHousehold());

      await cubit.createGoal(itemType: 'cosmetic', itemId: 'dragon_skin');

      expect(cubit.state.actionError, contains('ya no está disponible'));
      expect(cubit.state.isCreatingGoal, isFalse);
      expect(cubit.state.activeSavingsGoal, isNull);
      await cubit.close();
    });

    test('a 409 says a housemate got there first, and refetches', () async {
      final repo = FakeEconomyP1Repository(
        economy: buildEconomyP1(
          household: buildHouseholdEconomy(activeSavingsGoal: buildGoal(id: 'theirs')),
        ),
      );
      repo.createGoalError = const ConflictFailure('Operation already in progress');
      final cubit = householdCubit(repo);
      await cubit.load('h1');
      cubit.emit(readyHousehold());

      await cubit.createGoal(itemType: 'cosmetic', itemId: 'hat');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(cubit.state.actionError, 'Vuestro hogar ya tiene una meta activa.');
      // Refetched, so the section shows THEIR goal rather than leaving the
      // create button up over a household that already has one.
      expect(cubit.state.activeSavingsGoal?.id, 'theirs');
      await cubit.close();
    });
  });

  group('applyGoal', () {
    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'adopts a goal produced by the personal cubit',
      build: () => householdCubit(FakeEconomyP1Repository()),
      seed: () => readyHousehold(goal: buildGoal(contributedCoins: 60)),
      act: (cubit) => cubit.applyGoal(buildGoal(contributedCoins: 85)),
      verify: (cubit) =>
          expect(cubit.state.activeSavingsGoal?.contributedCoins, 85),
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'is idempotent, so the HTTP result and the socket echo agree',
      build: () => householdCubit(FakeEconomyP1Repository()),
      seed: () => readyHousehold(goal: buildGoal(contributedCoins: 60)),
      act: (cubit) {
        cubit.applyGoal(buildGoal(contributedCoins: 85));
        cubit.applyGoal(buildGoal(contributedCoins: 85));
      },
      verify: (cubit) =>
          expect(cubit.state.activeSavingsGoal?.contributedCoins, 85),
      // A goal is replaced wholesale rather than added to, so the second
      // application lands on an identical state and Equatable suppresses it.
      expect: () => [isA<HouseholdEconomyState>()],
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'clears a cancelled goal rather than displaying it',
      build: () => householdCubit(FakeEconomyP1Repository()),
      seed: () => readyHousehold(goal: buildGoal()),
      act: (cubit) => cubit.applyGoal(buildGoal(status: 'cancelled')),
      verify: (cubit) => expect(cubit.state.activeSavingsGoal, isNull),
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'keeps an unlocked goal so the section can say so',
      build: () => householdCubit(FakeEconomyP1Repository()),
      seed: () => readyHousehold(goal: buildGoal()),
      act: (cubit) => cubit.applyGoal(buildGoal(status: 'unlocked')),
      verify: (cubit) =>
          expect(cubit.state.activeSavingsGoal?.isUnlocked, isTrue),
    );
  });
}

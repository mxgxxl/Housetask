import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/config/pet_config.dart';
import 'package:homesync/data/models/economy_p1/economy_p1.dart';
import 'package:homesync/presentation/cubit/economy_p1_cubit.dart';
import 'package:homesync/presentation/cubit/household_economy_cubit.dart';
import 'package:homesync/presentation/widgets/household_economy_section.dart';
import 'package:homesync/services/device_timezone_service.dart';

import '../fakes.dart';
import '../savings_goal_writes_test.dart' show buildGoal;

/// The joint savings goal's write UI (TD-066 F4), from the «Hogar» section.
///
/// What these pin is what a wrong answer would cost somebody coins for:
///
///  * The picker sends an ITEM, never a price. A client that could name its
///    own `targetCoins` would unlock a 40 🪙 cosmetic by asking for 1, and
///    the economy's ceiling would be decorative.
///  * The contribute slider cannot exceed the wallet — «never overspend» —
///    and cannot exceed what the goal still needs, because coins put in
///    beyond the price are not refunded (PDR-018 refunds a CANCELLED goal).
///  * Offline is a disabled button WITH a reason, never a queued debit
///    (TD-066-DESIGN §7).

EconomyP1State personal({
  int balance = 100,
  bool isOnline = true,
  bool enabled = true,
  bool isContributing = false,
}) =>
    EconomyP1State(
      status: EconomyP1Status.ready,
      enabled: enabled,
      isOnline: isOnline,
      isContributing: isContributing,
      wallet: WalletPersonal(balance: balance, dailyReleased: 10, remaining: 30),
    );

HouseholdEconomyState household({
  SavingsGoal? goal,
  bool isOnline = true,
  bool enabled = true,
  bool isCreatingGoal = false,
}) =>
    HouseholdEconomyState(
      status: HouseholdEconomyStatus.ready,
      enabled: enabled,
      isOnline: isOnline,
      isCreatingGoal: isCreatingGoal,
      currentUserId: 'u1',
      householdProgress: const ProgressP1(level: 3, xpForNextLevel: 100),
      members: [buildMemberProgress('u1', name: 'Ana')],
      activeSavingsGoal: goal,
    );

/// Mounts the «Hogar» section over both real cubits — their getters are
/// exactly what the buttons render, so faking them would test the fake.
Future<({HouseholdEconomyCubit house, EconomyP1Cubit wallet})> pumpSection(
  WidgetTester tester, {
  required HouseholdEconomyState householdState,
  required EconomyP1State personalState,
  FakeEconomyP1Repository? repo,
  FakeConnectivityService? connectivity,
}) async {
  final sharedRepo = repo ?? FakeEconomyP1Repository();
  final house = HouseholdEconomyCubit(
    sharedRepo,
    connectivity: connectivity ?? FakeConnectivityService(),
  )..emit(householdState);
  final wallet = EconomyP1Cubit(
    sharedRepo,
    connectivity: connectivity ?? FakeConnectivityService(),
  )..emit(personalState);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MultiBlocProvider(
          providers: [
            BlocProvider<HouseholdEconomyCubit>.value(value: house),
            BlocProvider<EconomyP1Cubit>.value(value: wallet),
          ],
          child: const SingleChildScrollView(child: HouseholdEconomySection()),
        ),
      ),
    ),
  );
  await tester.pump();
  return (house: house, wallet: wallet);
}

/// The section's own «Aportar» button — the one whose `onPressed` carries
/// the whole of the disabled-state contract.
ElevatedButton _contributeButton(WidgetTester tester) => tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Aportar'),
        matching: find.byType(ElevatedButton),
      ),
    );

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

  group('create — the empty state CTA', () {
    testWidgets('offers «Elegid algo para los dos» when there is no goal',
        (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState: household(),
        personalState: personal(),
      );

      expect(find.text('Elegid algo para los dos'), findsOneWidget);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('hides the CTA while a goal is already active', (tester) async {
      // PDR-018: one active goal at a time, enforced server-side by a partial
      // unique index. This is the client saying it early, not enforcing it.
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal()),
        personalState: personal(),
      );

      expect(find.text('Elegid algo para los dos'), findsNothing);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('disables the CTA offline and says why', (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState: household(isOnline: false),
        personalState: personal(),
      );

      final button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Elegid algo para los dos'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(
        find.text('Sin conexión: podréis elegir una meta al recuperarla'),
        findsOneWidget,
      );
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('the picker lists the catalog with its prices', (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState: household(),
        personalState: personal(),
      );

      await tester.tap(find.text('Elegid algo para los dos'));
      await tester.pumpAndSettle();

      for (final cosmetic in kCosmeticsCatalog) {
        expect(find.text(cosmetic.name), findsOneWidget);
        // The price is a PREVIEW, mirrored from the backend's catalog — it is
        // never sent, and the next test is what proves that.
        expect(find.text('${cosmetic.price} 🪙'), findsOneWidget);
      }
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('picking an item sends the item and never a price',
        (tester) async {
      final repo = FakeEconomyP1Repository();
      final cubits = await pumpSection(
        tester,
        householdState: household(),
        personalState: personal(),
        repo: repo,
      );
      // The cubit needs a household before it will write.
      await cubits.house.load('h1');
      cubits.house.emit(household());
      await tester.pump();

      await tester.tap(find.text('Elegid algo para los dos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gafas'));
      await tester.pumpAndSettle();

      expect(repo.createGoalCalls, [
        {'itemType': 'cosmetic', 'itemId': 'glasses'}
      ]);
      await cubits.house.close();
      await cubits.wallet.close();
    });
  });

  group('contribute — the button', () {
    testWidgets('offers «Aportar» on an active goal', (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal()),
        personalState: personal(balance: 100),
      );

      expect(_contributeButton(tester).onPressed, isNotNull);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('disables with no coins and says so', (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal()),
        personalState: personal(balance: 0),
      );

      expect(find.text('No te quedan monedas que aportar'), findsOneWidget);
      // Disabled, not merely labelled: a tappable button here would send a
      // debit the server answers with a 403.
      expect(_contributeButton(tester).onPressed, isNull);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('disables offline and says so', (tester) async {
      // A debit is never queued (TD-066-DESIGN §7), so disabling is more
      // honest than accepting a tap that would be lost.
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal()),
        personalState: personal(isOnline: false),
      );

      expect(find.text('Sin conexión: no se puede aportar ahora'), findsOneWidget);
      expect(_contributeButton(tester).onPressed, isNull);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('disables on an unlocked goal and says so, not "no coins"',
        (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal(status: 'unlocked')),
        personalState: personal(balance: 0),
      );

      // The reason the member cannot act on comes first: with zero coins AND
      // an unlocked goal, complaining about coins would be misleading.
      expect(find.text('Esta meta ya no acepta aportaciones'), findsOneWidget);
      expect(find.text('No te quedan monedas que aportar'), findsNothing);
      expect(_contributeButton(tester).onPressed, isNull);
      await cubits.house.close();
      await cubits.wallet.close();
    });
  });

  group('contribute — the dialog', () {
    testWidgets('caps the slider at the wallet balance', (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal(targetCoins: 100, contributedCoins: 0)),
        personalState: personal(balance: 15),
      );

      await tester.tap(find.text('Aportar'));
      await tester.pumpAndSettle();

      expect(find.text('Puedes aportar hasta 15 🪙.'), findsOneWidget);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.max, 15.0);
      // It opens on "everything I can give" — always a legal value.
      expect(find.text('15 🪙'), findsOneWidget);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('caps the slider at what the goal still needs', (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal(targetCoins: 100, contributedCoins: 96)),
        personalState: personal(balance: 500),
      );

      await tester.tap(find.text('Aportar'));
      await tester.pumpAndSettle();

      // Coins beyond the price are gone, not refunded — PDR-018 refunds a
      // CANCELLED goal, not an overshoot on one that unlocks.
      expect(find.text('Puedes aportar hasta 4 🪙.'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).max, 4.0);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('contributes the chosen amount', (tester) async {
      final repo = FakeEconomyP1Repository();
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal(targetCoins: 100, contributedCoins: 0)),
        personalState: personal(balance: 20),
        repo: repo,
      );
      await cubits.wallet.load('h1');
      cubits.wallet.emit(personal(balance: 20));
      await tester.pump();

      await tester.tap(find.text('Aportar'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Slider), const Offset(-1000, 0));
      await tester.pumpAndSettle();
      // Scoped to the dialog: the section's own «Aportar» button is still in
      // the tree behind it, and an unscoped finder matches both.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(ElevatedButton, 'Aportar'),
        ),
      );
      await tester.pumpAndSettle();

      expect(repo.contributedAmounts, hasLength(1));
      // Dragged to the far left: the minimum, never zero or negative.
      expect(repo.contributedAmounts.single, 1);
      await cubits.house.close();
      await cubits.wallet.close();
    });

    testWidgets('cancelling the dialog contributes nothing', (tester) async {
      final repo = FakeEconomyP1Repository();
      final cubits = await pumpSection(
        tester,
        householdState: household(goal: buildGoal()),
        personalState: personal(balance: 20),
        repo: repo,
      );
      await cubits.wallet.load('h1');
      cubits.wallet.emit(personal(balance: 20));
      await tester.pump();

      await tester.tap(find.text('Aportar'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await tester.pumpAndSettle();

      expect(repo.contributedAmounts, isEmpty);
      await cubits.house.close();
      await cubits.wallet.close();
    });
  });

  group('failed writes', () {
    testWidgets('a refused create surfaces as a snackbar', (tester) async {
      final cubits = await pumpSection(
        tester,
        householdState: household(),
        personalState: personal(),
      );

      cubits.house.emit(
        household().copyWith(actionError: 'Vuestro hogar ya tiene una meta activa.'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Vuestro hogar ya tiene una meta activa.'), findsOneWidget);
      // Cleared after showing, so the next rebuild does not raise it again.
      expect(cubits.house.state.actionError, isNull);
      await cubits.house.close();
      await cubits.wallet.close();
    });
  });
}

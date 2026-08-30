import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/economy_p1/economy_p1.dart';
import 'package:homesync/presentation/cubit/economy_p1_cubit.dart';
import 'package:homesync/presentation/widgets/economy_p1_celebration.dart';
import 'package:homesync/presentation/widgets/economy_p1_progress_section.dart';
import 'package:homesync/services/device_timezone_service.dart';

import '../fakes.dart';

/// "Mi progreso" (TD-066 F2), the UI half.
///
/// What these pin is what a wrong answer would make *invisible* rather than
/// loud:
///
///  * `enabled: false` must render NOTHING. The backend answers a zeroed
///    structure rather than a 404 while the flag is off — which is every
///    household today — so a section that trusted the numbers would show a
///    real-looking 0 🪙 wallet and a dead streak to someone whose economy was
///    never switched on.
///  * Sunday is the case no amount of `remaining` can express on its own: it
///    releases nothing yet still carries the week's remainder (PDR-013).
///  * A disabled ice button must say WHY. Three of its four reasons are
///    things the member can act on, and the fourth (offline) is a promise
///    that the tap was not silently swallowed — a debit is never queued
///    (TD-066-DESIGN §7).

EconomyP1State _ready({
  int balance = 100,
  int dailyReleased = 10,
  int remaining = 30,
  int level = 3,
  int xpIntoLevel = 50,
  int xpForNextLevel = 100,
  List<String> unlocks = const [],
  int streakCurrent = 5,
  int iceReserve = 1,
  bool isOnline = true,
  bool enabled = true,
  bool isStale = false,
  bool isBuyingIce = false,
  List<BudgetAllocation> allocations = const [],
  EconomyP1Notice? notice,
}) =>
    EconomyP1State(
      status: EconomyP1Status.ready,
      enabled: enabled,
      isOnline: isOnline,
      isStale: isStale,
      isBuyingIce: isBuyingIce,
      notice: notice,
      wallet: WalletPersonal(
        balance: balance,
        dailyReleased: dailyReleased,
        remaining: remaining,
      ),
      personalProgress: ProgressP1(
        level: level,
        unlocks: unlocks,
        xpIntoLevel: xpIntoLevel,
        xpForNextLevel: xpForNextLevel,
        xpToNextLevel: xpForNextLevel - xpIntoLevel,
      ),
      streak: PersonalStreak(current: streakCurrent, iceReserve: iceReserve),
      weeklyBudget: PersonalBudget(
        weekKey: '2026-W35',
        weeklyCap: 200,
        allocations: allocations,
      ),
    );

/// Mounts the section over a cubit seeded with [state].
///
/// The cubit is real rather than mocked — its getters (`todayLineKind`,
/// `iceUnavailableReason`) are exactly what the widget renders, so faking
/// them would test the fake.
Future<EconomyP1Cubit> _pump(
  WidgetTester tester,
  EconomyP1State state, {
  FakeEconomyP1Repository? repo,
  FakeConnectivityService? connectivity,
}) async {
  final cubit = EconomyP1Cubit(
    repo ?? FakeEconomyP1Repository(),
    connectivity: connectivity ?? FakeConnectivityService(),
  );
  cubit.emit(state);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BlocProvider<EconomyP1Cubit>.value(
          value: cubit,
          child: const EconomyP1ProgressSection(),
        ),
      ),
    ),
  );
  await tester.pump();
  return cubit;
}

void main() {
  // Nothing here should reach a real platform channel: DeviceTimeZoneService
  // is consulted by any load() these tests trigger.
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

  group('visibility', () {
    testWidgets('renders nothing at all while P1 is off', (tester) async {
      final cubit = await _pump(tester, _ready(enabled: false, balance: 0));

      // Not "renders zeroes" — renders NOTHING. A 0 🪙 wallet here would be
      // indistinguishable from having earned nothing.
      expect(find.text('Mi progreso'), findsNothing);
      expect(find.textContaining('🪙'), findsNothing);
      expect(find.byType(SizedBox), findsWidgets);
      await cubit.close();
    });

    testWidgets('renders nothing before the first load', (tester) async {
      final cubit = await _pump(tester, const EconomyP1State());
      expect(find.text('Mi progreso'), findsNothing);
      await cubit.close();
    });

    testWidgets('renders the section once P1 is on', (tester) async {
      final cubit = await _pump(tester, _ready());
      expect(find.text('Mi progreso'), findsOneWidget);
      await cubit.close();
    });
  });

  group('header', () {
    testWidgets('shows the flame with the current streak', (tester) async {
      // Semantics are off by default in widget tests, so the labels a screen
      // reader would announce need the tree switched on explicitly.
      final handle = tester.ensureSemantics();
      final cubit = await _pump(tester, _ready(streakCurrent: 7));

      expect(find.text('🔥'), findsOneWidget);
      expect(find.bySemanticsLabel('Racha: 7 días'), findsOneWidget);
      await cubit.close();
      handle.dispose();
    });

    testWidgets('shows the wallet balance and the ice reserve', (tester) async {
      final handle = tester.ensureSemantics();
      final cubit = await _pump(tester, _ready(balance: 142, iceReserve: 2));

      expect(find.bySemanticsLabel('Saldo: 142 monedas'), findsOneWidget);
      expect(find.bySemanticsLabel('Hielos: 2'), findsOneWidget);
      await cubit.close();
      handle.dispose();
    });

    testWidgets('flags stale content served from cache', (tester) async {
      final cubit = await _pump(tester, _ready(isStale: true));

      // Stale content is shown, not hidden — but it has to say so.
      expect(find.text('Sin conexión'), findsOneWidget);
      expect(find.text('Mi progreso'), findsOneWidget);
      await cubit.close();
    });
  });

  group('línea de hoy (UX-P1-SPEC §4)', () {
    testWidgets('normal day shows remaining over released', (tester) async {
      final cubit = await _pump(tester, _ready(dailyReleased: 34, remaining: 24));

      expect(find.text('Hoy: 24/34 🪙 disponibles'), findsOneWidget);
      await cubit.close();
    });

    testWidgets('carry-over names the coins from earlier days', (tester) async {
      final cubit = await _pump(tester, _ready(dailyReleased: 34, remaining: 58));

      expect(
        find.text('Hoy: 58 🪙 (incluye 24 de días anteriores)'),
        findsOneWidget,
      );
      await cubit.close();
    });

    testWidgets('Sunday shows the rest-day line, not a zero (PDR-013)', (tester) async {
      // The case that cannot be derived from `remaining` alone: Sunday
      // releases nothing of its own, yet the week's remainder is still
      // claimable — so the honest line is "the coins are resting", not "you
      // have none".
      final cubit = await _pump(tester, _ready(dailyReleased: 0, remaining: 24));

      expect(
        find.text('Día de descanso: tu progreso cuenta, las monedas descansan'),
        findsOneWidget,
      );
      expect(find.textContaining('0 🪙 disponibles'), findsNothing);
      await cubit.close();
    });

    testWidgets('a spent-out Sunday is not sold as a rest day', (tester) async {
      // Nothing left AND nothing released. Saying "las monedas descansan"
      // here would imply coins are waiting when there are none.
      final cubit = await _pump(tester, _ready(dailyReleased: 0, remaining: 0));

      expect(
        find.text('Completaste tu recompensa de hoy; el progreso sigue contando'),
        findsOneWidget,
      );
      await cubit.close();
    });
  });

  group('nivel personal', () {
    testWidgets('shows the level and its XP progress', (tester) async {
      final cubit = await _pump(
        tester,
        _ready(level: 4, xpIntoLevel: 30, xpForNextLevel: 120),
      );

      expect(find.text('Nivel 4'), findsOneWidget);
      expect(find.text('30/120 XP'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator).first,
      );
      expect(bar.value, closeTo(0.25, 0.001));
      await cubit.close();
    });

    testWidgets('renders unlocks from the read, humanised', (tester) async {
      final cubit = await _pump(
        tester,
        _ready(unlocks: const ['title:constante', 'badge:primer_paso']),
      );

      expect(find.text('Constante'), findsOneWidget);
      expect(find.text('Primer paso'), findsOneWidget);
      await cubit.close();
    });
  });

  group('plan semanal (solo lectura, D3)', () {
    testWidgets('lists allocations with no way to edit them', (tester) async {
      final cubit = await _pump(
        tester,
        _ready(
          allocations: const [
            BudgetAllocation(allocationKey: 'common:unassigned', coinAmount: 12),
            BudgetAllocation(
              allocationKey: 'Fregar',
              coinAmount: 4,
              mode: 'manual',
            ),
          ],
        ),
      );

      expect(find.text('Plan semanal'), findsOneWidget);
      expect(find.text('Tareas sin asignar'), findsOneWidget);
      expect(find.text('12 🪙'), findsOneWidget);
      expect(find.text('ajustado'), findsOneWidget);
      // D3: the B8 PATCH gets no UI this round, so nothing here is editable.
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(Slider), findsNothing);
      await cubit.close();
    });

    testWidgets('omits the plan entirely when there are no allocations', (tester) async {
      final cubit = await _pump(tester, _ready());
      expect(find.text('Plan semanal'), findsNothing);
      await cubit.close();
    });
  });

  group('botón de comprar hielo — sus cuatro estados', () {
    Future<void> expectDisabled(WidgetTester tester, String reason) async {
      final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
      expect(button.onPressed, isNull, reason: 'the button must be disabled');
      expect(find.text(reason), findsOneWidget);
    }

    testWidgets('enabled when there is room, coins and a connection', (tester) async {
      final cubit = await _pump(
        tester,
        _ready(balance: kIcePriceCoins, iceReserve: 0),
      );

      final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
      expect(button.onPressed, isNotNull);
      await cubit.close();
    });

    testWidgets('disabled with the reserve full', (tester) async {
      final cubit = await _pump(
        tester,
        _ready(balance: 500, iceReserve: kMaxIceReserve),
      );

      await expectDisabled(tester, 'Ya tienes el máximo de hielos ($kMaxIceReserve)');
      await cubit.close();
    });

    testWidgets('disabled without enough coins', (tester) async {
      final cubit = await _pump(
        tester,
        _ready(balance: kIcePriceCoins - 1, iceReserve: 0),
      );

      await expectDisabled(tester, 'Te faltan monedas (cuesta $kIcePriceCoins 🪙)');
      await cubit.close();
    });

    testWidgets('disabled offline, and says the debit was not queued', (tester) async {
      final cubit = await _pump(
        tester,
        _ready(balance: 500, iceReserve: 0, isOnline: false),
      );

      await expectDisabled(tester, 'Sin conexión: no se puede comprar ahora');
      await cubit.close();
    });

    testWidgets('tapping it asks the cubit to buy', (tester) async {
      final repo = FakeEconomyP1Repository()
        ..buyIceResult = {'iceReserve': 1, 'spent': kIcePriceCoins, 'balance': 80};
      final cubit = await _pump(
        tester,
        _ready(balance: 100, iceReserve: 0),
        repo: repo,
      );
      // buyIce needs the household id only a real load sets, and `load` does
      // real async work (a platform channel for the IANA zone, then the
      // repository). Running that inside testWidgets' fake-async zone is the
      // TD-040 deadlock — the clock stops being pumped and the future never
      // completes — so it goes through runAsync, which is the escape hatch
      // that fix established.
      await tester.runAsync(() => cubit.load('h1'));
      cubit.emit(_ready(balance: 100, iceReserve: 0));
      await tester.pump();

      await tester.tap(find.byType(OutlinedButton));
      await tester.pump();
      await tester.pump();

      expect(repo.buyIceOperationIds, hasLength(1));
      await cubit.close();
    });
  });

  group('avisos y celebraciones', () {
    testWidgets('shows the ice-consumed banner with the spec copy', (tester) async {
      final cubit = await _pump(
        tester,
        _ready(
          notice: const EconomyP1Notice(
            kind: EconomyP1NoticeKind.iceConsumed,
            message: 'Ayer fue un día complicado. Un hielo cubrió tu racha 🔥 12',
            sequence: 1,
          ),
        ),
      );

      expect(
        find.text('Ayer fue un día complicado. Un hielo cubrió tu racha 🔥 12'),
        findsOneWidget,
      );
      await cubit.close();
    });

    testWidgets('a level-up raises the celebration overlay', (tester) async {
      final cubit = await _pump(tester, _ready(level: 3));

      cubit.applyRealtime('economy:level_up', {
        'track': 'personal',
        'level': 4,
        'xp': 300,
        'unlocks': ['title:constante'],
      });
      await tester.pumpAndSettle();

      expect(find.byType(EconomyCelebrationDialog), findsOneWidget);
      expect(find.text('¡Subiste de nivel!'), findsOneWidget);
      expect(find.text('title:constante'), findsOneWidget);

      await tester.tap(find.text('Genial'));
      await tester.pumpAndSettle();
      expect(find.byType(EconomyCelebrationDialog), findsNothing);
      await cubit.close();
    });

    testWidgets('a milestone raises the celebration overlay', (tester) async {
      final cubit = await _pump(tester, _ready());

      cubit.applyRealtime('economy:milestone', {
        'kind': 'tasks_completed',
        'value': 10,
        'total': 10,
      });
      await tester.pumpAndSettle();

      expect(find.byType(EconomyCelebrationDialog), findsOneWidget);
      expect(find.text('¡Hito conseguido!'), findsOneWidget);
      await cubit.close();
    });

    testWidgets('no celebration while P1 is off', (tester) async {
      final cubit = await _pump(tester, _ready(enabled: false));

      cubit.applyRealtime('economy:level_up', {'track': 'personal', 'level': 4});
      await tester.pumpAndSettle();

      expect(find.byType(EconomyCelebrationDialog), findsNothing);
      await cubit.close();
    });
  });
}

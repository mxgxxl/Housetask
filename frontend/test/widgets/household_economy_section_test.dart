import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:homesync/data/models/economy_p1/economy_p1.dart';
import 'package:homesync/presentation/cubit/economy_p1_cubit.dart';
import 'package:homesync/presentation/cubit/household_economy_cubit.dart';
import 'package:homesync/presentation/widgets/celebration_dialog.dart';
import 'package:homesync/presentation/widgets/household_economy_section.dart';

import '../fakes.dart';

/// «Hogar» (TD-066 F3), the UI half.
///
/// What these pin is what a wrong answer would make *invisible* rather than
/// loud:
///
///  * `enabled: false` must render NOTHING. The household read answers a
///    zeroed structure rather than a 404 while the flag is off — which is
///    every household today — AND it still returns a real roster, because
///    membership is not economy data. A section that trusted the numbers
///    beside those names would show a home of eternal level 1s.
///  * The roster renders in JOIN order with no ranking affordances. Sorting
///    it, numbering it or decorating the top row is each one step towards the
///    leaderboard UX-P1-SPEC §0 rules out — and none of them would look like
///    a bug.
///  * The savings breakdown keeps that order too, and says «Tú» for the
///    reader rather than their own name (UX-P1-SPEC §4).

/// Ana joined first with LESS XP than Bea, so a list in join order is
/// distinguishable from a ranked one at a glance.
List<HouseholdMemberProgress> _roster() => [
      buildMemberProgress('u1', name: 'Ana', level: 2, xp: 120),
      buildMemberProgress('u2', name: 'Bea', level: 4, xp: 900),
    ];

HouseholdEconomyState _ready({
  bool enabled = true,
  int level = 5,
  int xpIntoLevel = 200,
  int xpForNextLevel = 500,
  List<String> unlocks = const [],
  List<HouseholdMemberProgress>? members,
  SavingsGoal? goal,
  String? currentUserId = 'u1',
  bool isStale = false,
}) =>
    HouseholdEconomyState(
      status: HouseholdEconomyStatus.ready,
      enabled: enabled,
      isStale: isStale,
      currentUserId: currentUserId,
      householdProgress: ProgressP1(
        level: level,
        unlocks: unlocks,
        xpIntoLevel: xpIntoLevel,
        xpForNextLevel: xpForNextLevel,
        xpToNextLevel: xpForNextLevel - xpIntoLevel,
      ),
      members: members ?? _roster(),
      activeSavingsGoal: goal,
    );

/// The cubit is real rather than mocked: its getters are exactly what the
/// widget renders, so faking them would test the fake.
///
/// TD-066 F4 gave the section a second cubit to read: «Aportar» is enabled or
/// not by the PERSONAL wallet, which never reaches the household room. It is
/// seeded with a comfortable balance here — these tests are about what the
/// section displays, and the contribution rules have their own file.
late EconomyP1Cubit _wallet;

Future<HouseholdEconomyCubit> _pump(
  WidgetTester tester,
  HouseholdEconomyState state,
) async {
  final repo = FakeEconomyP1Repository();
  final cubit = HouseholdEconomyCubit(repo, connectivity: FakeConnectivityService());
  cubit.emit(state);
  _wallet = EconomyP1Cubit(repo, connectivity: FakeConnectivityService())
    ..emit(const EconomyP1State(
      status: EconomyP1Status.ready,
      enabled: true,
      wallet: WalletPersonal(balance: 100, dailyReleased: 10, remaining: 30),
    ));

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MultiBlocProvider(
          providers: [
            BlocProvider<HouseholdEconomyCubit>.value(value: cubit),
            BlocProvider<EconomyP1Cubit>.value(value: _wallet),
          ],
          child: const SingleChildScrollView(child: HouseholdEconomySection()),
        ),
      ),
    ),
  );
  await tester.pump();
  return cubit;
}

void main() {
  group('visibility', () {
    testWidgets('renders nothing at all while P1 is off', (tester) async {
      final cubit = await _pump(tester, _ready(enabled: false));

      // Not "renders zeroes" — renders NOTHING. The roster is real even with
      // the flag off, so a rendered section would show two members at a
      // level they never earned.
      expect(find.text('Hogar'), findsNothing);
      expect(find.text('Ana'), findsNothing);
      expect(find.text('Bea'), findsNothing);
      expect(find.textContaining('Nivel de hogar'), findsNothing);
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('renders nothing before the first load', (tester) async {
      final cubit = await _pump(tester, const HouseholdEconomyState());
      expect(find.text('Hogar'), findsNothing);
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('renders the section once P1 is on', (tester) async {
      final cubit = await _pump(tester, _ready());
      expect(find.text('Hogar'), findsOneWidget);
      // UX-P1-SPEC §4's line for the household card, verbatim.
      expect(
        find.text('Tu nivel viaja contigo. El nivel de hogar es de los dos.'),
        findsOneWidget,
      );
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('marks stale content without hiding it', (tester) async {
      final cubit = await _pump(tester, _ready(isStale: true));
      expect(find.text('Sin conexión'), findsOneWidget);
      expect(find.text('Ana (tú)'), findsOneWidget);
      await cubit.close();
      await _wallet.close();
    });
  });

  group('shared level', () {
    testWidgets('shows the level and the distance to the next one',
        (tester) async {
      final cubit = await _pump(
        tester,
        _ready(level: 5, xpIntoLevel: 300, xpForNextLevel: 500),
      );

      expect(find.text('Nivel de hogar 5'), findsOneWidget);
      // UX-P1-SPEC §4's own phrasing: the distance left, not the fraction.
      expect(find.text('200 XP para nivel 6'), findsOneWidget);
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('renders shared unlocks as readable names', (tester) async {
      final cubit = await _pump(
        tester,
        _ready(unlocks: const ['cosmetic:dragon_skin']),
      );

      // Not the raw id: the server sends namespaced ids and no display names.
      expect(find.text('Dragon skin'), findsOneWidget);
      await cubit.close();
      await _wallet.close();
    });
  });

  group('roster', () {
    testWidgets('lists members in join order, never by XP', (tester) async {
      final cubit = await _pump(tester, _ready());

      final ana = tester.getTopLeft(find.text('Ana (tú)'));
      final bea = tester.getTopLeft(find.text('Bea'));
      // Bea has 900 XP to Ana's 120. Ranked, she would be on top; she is not,
      // because she joined second — the leaderboard UX-P1-SPEC §0 rules out
      // is exactly one `sort` away and would look like nothing was wrong.
      expect(ana.dy, lessThan(bea.dy));
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('shows each member level and XP, and no wallet or streak',
        (tester) async {
      final cubit = await _pump(tester, _ready());

      expect(find.text('Nivel 2 · 120 XP'), findsOneWidget);
      expect(find.text('Nivel 4 · 900 XP'), findsOneWidget);
      // PDR-012 keeps these personal, and the household room never carries
      // them — a coin or a flame here would mean a real leak upstream.
      expect(find.textContaining('🪙 '), findsNothing);
      expect(find.textContaining('🔥'), findsNothing);
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('carries no ranking decoration of any kind', (tester) async {
      final cubit = await _pump(tester, _ready());

      // No positions, no podium, no crowns. Each of these would read as
      // harmless polish and each turns a roster into a scoreboard.
      for (final marker in ['1.', '2.', '#1', '🥇', '🏆', '👑']) {
        expect(find.textContaining(marker), findsNothing,
            reason: 'found ranking marker "$marker"');
      }
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('marks the reader without moving them', (tester) async {
      // Bea is the reader here, and she still renders second.
      final cubit = await _pump(tester, _ready(currentUserId: 'u2'));

      expect(find.text('Bea (tú)'), findsOneWidget);
      expect(find.text('Ana'), findsOneWidget);
      final ana = tester.getTopLeft(find.text('Ana'));
      final bea = tester.getTopLeft(find.text('Bea (tú)'));
      expect(ana.dy, lessThan(bea.dy));
      await cubit.close();
      await _wallet.close();
    });
  });

  group('joint savings goal', () {
    SavingsGoal goal({
      int contributedCoins = 68,
      String status = 'active',
      List<SavingsContributor> contributions = const [
        SavingsContributor(userId: 'u1', name: 'Ana', amount: 40),
        SavingsContributor(userId: 'u2', name: 'Bea', amount: 28),
      ],
    }) =>
        SavingsGoal(
          id: 'g1',
          itemType: 'cosmetic',
          itemId: 'dragon_skin',
          targetCoins: 100,
          contributedCoins: contributedCoins,
          status: status,
          createdBy: 'u1',
          contributions: contributions,
        );

    testWidgets('renders the breakdown as «Tú: 40 · Bea: 28»', (tester) async {
      final cubit = await _pump(tester, _ready(goal: goal()));

      expect(find.text('Meta conjunta'), findsOneWidget);
      expect(find.text('68/100 🪙'), findsOneWidget);
      // UX-P1-SPEC §4 verbatim: one figure per person, the reader as «Tú»,
      // in the order the cubit holds — never sorted by amount.
      expect(find.text('Tú: 40 · Bea: 28'), findsOneWidget);
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('keeps the breakdown order when the reader is behind',
        (tester) async {
      final cubit = await _pump(
        tester,
        _ready(
          goal: goal(
            contributedCoins: 90,
            contributions: const [
              SavingsContributor(userId: 'u1', name: 'Ana', amount: 20),
              SavingsContributor(userId: 'u2', name: 'Bea', amount: 70),
            ],
          ),
        ),
      );

      // Bea has contributed more than three times as much. The line still
      // reads in contribution order, because it is a record of who chipped
      // in, not a ranking of who chipped in most.
      expect(find.text('Tú: 20 · Bea: 70'), findsOneWidget);
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('says so when the goal is unlocked', (tester) async {
      final cubit = await _pump(
        tester,
        _ready(goal: goal(contributedCoins: 100, status: 'unlocked')),
      );

      expect(find.text('Meta desbloqueada'), findsOneWidget);
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('states the empty case with the spec\'s live CTA', (tester) async {
      final cubit = await _pump(tester, _ready());

      expect(find.text('Todavía no tenéis una meta conjunta.'), findsOneWidget);
      // UX-P1-SPEC §4's CTA, verbatim. It was a plain sentence in F3 because
      // `POST /savings-goals` had no caller yet; F4 gave it one, so the
      // button is real rather than decorative — see
      // savings_goal_actions_test.dart for what it sends.
      expect(find.text('Elegid algo para los dos'), findsOneWidget);
      await cubit.close();
      await _wallet.close();
    });
  });

  group('celebrations', () {
    testWidgets('a household level-up opens a shared overlay', (tester) async {
      final cubit = await _pump(tester, _ready(level: 5));

      cubit.applyRealtime('household:level_up', {
        'track': 'household',
        'level': 6,
        'previousLevel': 5,
        'xp': 1500,
        'unlocks': ['cosmetic:dragon_skin'],
      });
      await tester.pumpAndSettle();

      expect(find.byType(CelebrationDialog), findsOneWidget);
      expect(find.text('¡Nivel de hogar 6!'), findsOneWidget);
      // UX-P1-SPEC §3: the shared modal never names a member.
      expect(
        find.textContaining('Lo habéis conseguido juntos'),
        findsOneWidget,
      );
      expect(find.text('Habéis desbloqueado'), findsOneWidget);
      expect(find.text('Dragon skin'), findsWidgets);

      await tester.tap(find.text('Genial'));
      await tester.pumpAndSettle();
      expect(find.byType(CelebrationDialog), findsNothing);
      // Transient by construction: dismissing clears it, and it is not
      // re-raised on the next rebuild.
      expect(cubit.state.celebration, isNull);
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('an unlocked goal celebrates cooperatively', (tester) async {
      final cubit = await _pump(tester, _ready());

      cubit.applyRealtime('household:savings_goal_unlocked', {
        'id': 'g1',
        'itemType': 'cosmetic',
        'itemId': 'dragon_skin',
        'targetCoins': 100,
        'contributedCoins': 100,
        'status': 'unlocked',
        'createdBy': 'u1',
      });
      await tester.pumpAndSettle();

      expect(find.text('¡Meta desbloqueada!'), findsOneWidget);
      expect(
        find.textContaining('Lo habéis conseguido juntos'),
        findsOneWidget,
      );
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('a milestone is a toast, not a modal', (tester) async {
      final cubit = await _pump(tester, _ready());

      cubit.applyRealtime('household:milestone', {
        'kind': 'tasks_completed',
        'value': 100,
        'total': 100,
      });
      // Two frames: the listener fires on the first, the SnackBar animates
      // in on the second.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // UX-P1-SPEC §3's hierarchy: intensity is inverse to frequency, and a
      // milestone happens far more often than a shared level.
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(CelebrationDialog), findsNothing);
      expect(
        find.textContaining('100 tareas completadas entre todos'),
        findsOneWidget,
      );
      await cubit.close();
      await _wallet.close();
    });

    testWidgets('a cancelled goal says nothing shared', (tester) async {
      const goal = SavingsGoal(
        id: 'g1',
        targetCoins: 100,
        contributedCoins: 68,
        contributions: [
          SavingsContributor(userId: 'u1', name: 'Ana', amount: 40),
        ],
      );
      final cubit = await _pump(tester, _ready(goal: goal));
      expect(find.text('Meta conjunta'), findsOneWidget);

      cubit.applyRealtime('household:savings_goal_cancelled', {
        'goal': {'id': 'g1', 'status': 'cancelled'},
        'refunds': [
          {'userId': 'u1', 'amount': 40},
        ],
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Todavía no tenéis una meta conjunta.'), findsOneWidget);
      // The refund figure reaches each member privately as
      // `economy:savings_refunded`; announcing it here would tell the whole
      // household what everyone had put in.
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(CelebrationDialog), findsNothing);
      await cubit.close();
      await _wallet.close();
    });
  });
}

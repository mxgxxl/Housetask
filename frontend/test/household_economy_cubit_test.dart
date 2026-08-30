import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/economy_p1/economy_p1.dart';
import 'package:homesync/presentation/cubit/household_economy_cubit.dart';
import 'package:homesync/services/device_timezone_service.dart';
import 'package:homesync/services/socket_service.dart';

import 'fakes.dart';

/// «Hogar» — the cooperative half of the P1 economy (TD-066 F3).
///
/// The properties worth pinning here are the ones a wrong answer would make
/// invisible rather than loud:
///
///  * `enabled: false` must render NOTHING. The backend answers a zeroed
///    structure instead of a 404, so a cubit that trusted the numbers would
///    show a household of members all sitting at level 1 and 0 XP to a
///    household whose economy was simply never switched on.
///  * The roster arrives in JOIN order and must stay in it. UX-P1-SPEC §0
///    rules out leaderboards, and re-ordering this list by XP is the whole of
///    what building one would take.
///  * The savings breakdown survives an unlock. `household:savings_goal_
///    unlocked` carries the goal DOCUMENT, which has no `contributions` array
///    — that is assembled by the read endpoint from another collection — so
///    applying it verbatim would blank «Tú: 40 · Ana: 28» at the exact moment
///    the household is celebrating it.
///  * A cancelled goal says nothing shared about who got what back. That
///    figure is personal and travels on the personal room.

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

HouseholdEconomyCubit _cubit(FakeEconomyP1Repository repo) =>
    HouseholdEconomyCubit(repo, timeZone: DeviceTimeZoneService());

/// The roster every test below starts from: Ana joined first, Bea second,
/// and Bea has more XP — so a list sorted by XP is distinguishable from one
/// in join order at a glance.
List<HouseholdMemberProgress> _roster() => [
      buildMemberProgress('u1', name: 'Ana', level: 2, xp: 120),
      buildMemberProgress('u2', name: 'Bea', level: 4, xp: 900),
    ];

SavingsGoal _goal({
  String id = 'g1',
  int targetCoins = 100,
  int contributedCoins = 68,
  String status = 'active',
  List<SavingsContributor> contributions = const [
    SavingsContributor(userId: 'u1', name: 'Ana', amount: 40),
    SavingsContributor(userId: 'u2', name: 'Bea', amount: 28),
  ],
}) =>
    SavingsGoal(
      id: id,
      itemType: 'cosmetic',
      itemId: 'dragon_skin',
      targetCoins: targetCoins,
      contributedCoins: contributedCoins,
      status: status,
      createdBy: 'u1',
      contributions: contributions,
    );

/// A loaded, P1-enabled starting point — what every socket event assumes.
///
/// `applyRealtime` deliberately refuses to apply a payload onto a state that
/// is not ready, so a seed is how these tests say "the household is loaded".
HouseholdEconomyState _ready({
  int level = 5,
  int xp = 1000,
  int xpIntoLevel = 200,
  int xpForNextLevel = 500,
  int tasksCompleted = 24,
  List<String> unlocks = const ['cosmetic:hat'],
  List<HouseholdMemberProgress>? members,
  SavingsGoal? goal,
  String? currentUserId = 'u1',
}) =>
    HouseholdEconomyState(
      status: HouseholdEconomyStatus.ready,
      enabled: true,
      currentUserId: currentUserId,
      householdProgress: ProgressP1(
        xp: xp,
        level: level,
        unlocks: unlocks,
        tasksCompleted: tasksCompleted,
        xpIntoLevel: xpIntoLevel,
        xpForNextLevel: xpForNextLevel,
        xpToNextLevel: xpForNextLevel - xpIntoLevel,
      ),
      members: members ?? _roster(),
      activeSavingsGoal: goal,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => _mockTimeZone('Europe/Madrid'));
  tearDown(_clearTimeZoneMock);

  group('load', () {
    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'applies the household half of the snapshot',
      build: () => _cubit(
        FakeEconomyP1Repository(
          economy: buildEconomyP1(
            household: buildHouseholdEconomy(
              level: 5,
              xp: 1000,
              xpIntoLevel: 200,
              xpForNextLevel: 500,
              tasksCompleted: 24,
              unlocks: const ['cosmetic:hat'],
              members: _roster(),
              activeSavingsGoal: _goal(),
            ),
          ),
        ),
      ),
      act: (cubit) => cubit.load('h1', currentUserId: 'u1'),
      verify: (cubit) {
        final state = cubit.state;
        expect(state.status, HouseholdEconomyStatus.ready);
        expect(state.enabled, isTrue);
        expect(state.isVisible, isTrue);
        expect(state.householdProgress.level, 5);
        expect(state.xpToNextLevel, 300);
        expect(state.unlocks, ['cosmetic:hat']);
        expect(state.currentUserId, 'u1');
        expect(state.activeSavingsGoal!.contributedCoins, 68);
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'keeps the roster in the order the server sent it, never sorted by XP',
      build: () => _cubit(
        FakeEconomyP1Repository(
          economy: buildEconomyP1(
            household: buildHouseholdEconomy(members: _roster()),
          ),
        ),
      ),
      act: (cubit) => cubit.load('h1'),
      verify: (cubit) {
        // Ana joined first with LESS XP than Bea. A cubit that ranked the
        // roster would put Bea first, which is the leaderboard UX-P1-SPEC §0
        // rules out.
        expect(cubit.state.members.map((m) => m.name), ['Ana', 'Bea']);
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'stays invisible while P1 is off, even with a real roster',
      build: () => _cubit(
        FakeEconomyP1Repository(
          economy: buildEconomyP1(
            enabled: false,
            household: buildHouseholdEconomy(enabled: false, members: _roster()),
          ),
        ),
      ),
      act: (cubit) => cubit.load('h1'),
      verify: (cubit) {
        // The roster IS real with the flag off — it is not economy data — but
        // the levels beside it are placeholders, so the section renders
        // nothing at all rather than a household of eternal level 1s.
        expect(cubit.state.enabled, isFalse);
        expect(cubit.state.isVisible, isFalse);
        expect(cubit.state.members, hasLength(2));
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'paints the cached snapshot as stale before the network answers',
      build: () => _cubit(
        FakeEconomyP1Repository(
          cachedEconomy: buildEconomyP1(
            household: buildHouseholdEconomy(level: 3, members: _roster()),
          ),
          economy: buildEconomyP1(
            household: buildHouseholdEconomy(level: 4, members: _roster()),
          ),
        ),
      ),
      act: (cubit) => cubit.load('h1'),
      verify: (cubit) {
        expect(cubit.state.householdProgress.level, 4);
        expect(cubit.state.isStale, isFalse);
      },
      expect: () => [
        // The cache lands first so the tab opens on content, marked stale.
        isA<HouseholdEconomyState>()
            .having((s) => s.householdProgress.level, 'level', 3)
            .having((s) => s.isStale, 'isStale', isTrue),
        isA<HouseholdEconomyState>()
            .having((s) => s.householdProgress.level, 'level', 4)
            .having((s) => s.isStale, 'isStale', isFalse),
      ],
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'a failed first load with nothing cached is fatal to the section',
      build: () => _cubit(
        FakeEconomyP1Repository(loadError: const ServerFailure('boom')),
      ),
      act: (cubit) => cubit.load('h1'),
      verify: (cubit) {
        expect(cubit.state.status, HouseholdEconomyStatus.failure);
        expect(cubit.state.error, 'boom');
      },
    );

    test('a failed refresh over existing content keeps the content', () async {
      final repo = FakeEconomyP1Repository(
        economy: buildEconomyP1(
          household: buildHouseholdEconomy(level: 7, members: _roster()),
        ),
      );
      final cubit = _cubit(repo);
      await cubit.load('h1');
      expect(cubit.state.householdProgress.level, 7);

      repo.loadError = const ServerFailure('offline');
      await cubit.refresh();

      expect(cubit.state.status, HouseholdEconomyStatus.ready);
      expect(cubit.state.householdProgress.level, 7);
      expect(cubit.state.isStale, isTrue);
      expect(cubit.state.error, isNull);
      await cubit.close();
    });

    test('switching households drops the previous one before reloading', () async {
      final repo = FakeEconomyP1Repository(
        economy: buildEconomyP1(
          household: buildHouseholdEconomy(level: 6, members: _roster()),
        ),
      );
      final cubit = _cubit(repo);
      await cubit.load('h1');
      expect(cubit.state.members, hasLength(2));

      repo.economy = buildEconomyP1(
        household: buildHouseholdEconomy(
          level: 1,
          members: [buildMemberProgress('u9', name: 'Caro')],
        ),
      );
      await cubit.load('h2');

      expect(cubit.state.members.map((m) => m.name), ['Caro']);
      await cubit.close();
    });

    test('a response for the previous household never lands', () async {
      final repo = FakeEconomyP1Repository(
        economy: buildEconomyP1(
          household: buildHouseholdEconomy(
            level: 9,
            members: [buildMemberProgress('u1', name: 'Ana')],
          ),
        ),
      );
      repo.loadGate = Completer<void>();
      final cubit = _cubit(repo);

      final pending = cubit.load('h1');
      cubit.reset(); // a logout while the read is in flight
      repo.loadGate!.complete();
      await pending;

      expect(cubit.state, const HouseholdEconomyState());
      await cubit.close();
    });

    test('reset clears the roster and the goal', () async {
      final cubit = _cubit(
        FakeEconomyP1Repository(
          economy: buildEconomyP1(
            household: buildHouseholdEconomy(
              members: _roster(),
              activeSavingsGoal: _goal(),
            ),
          ),
        ),
      );
      await cubit.load('h1', currentUserId: 'u1');
      expect(cubit.state.members, isNotEmpty);

      cubit.reset();

      expect(cubit.state, const HouseholdEconomyState());
      expect(cubit.state.activeSavingsGoal, isNull);
      expect(cubit.state.currentUserId, isNull);
      await cubit.close();
    });
  });

  group('realtime — shared progress', () {
    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'household:xp_updated advances the bar without refetching',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(xp: 1000, xpIntoLevel: 200, xpForNextLevel: 500),
      act: (cubit) => cubit.applyRealtime(
        'household:xp_updated',
        {'householdXp': 1030, 'level': 5},
      ),
      verify: (cubit) {
        final progress = cubit.state.householdProgress;
        expect(progress.xp, 1030);
        expect(progress.level, 5);
        // The delta, not the total: the payload carries no per-level figure.
        expect(progress.xpIntoLevel, 230);
        expect(progress.xpToNextLevel, 270);
        // The pooled task counter moves with it, corrected later by the
        // milestone event's authoritative `total`.
        expect(progress.tasksCompleted, 25);
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'household:xp_updated restarts the bar when the level also moved',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(xp: 1000, level: 5, xpIntoLevel: 480, xpForNextLevel: 500),
      act: (cubit) => cubit.applyRealtime(
        'household:xp_updated',
        {'householdXp': 1030, 'level': 6},
      ),
      verify: (cubit) {
        // The level-up event follows immediately with the unlocks; both agree
        // on the reset, so the bar never renders the old level's fill against
        // the new level.
        expect(cubit.state.householdProgress.level, 6);
        expect(cubit.state.householdProgress.xpIntoLevel, 0);
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'household:level_up celebrates it as shared',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(level: 5, unlocks: const ['cosmetic:hat']),
      act: (cubit) => cubit.applyRealtime('household:level_up', {
        'track': 'household',
        'level': 6,
        'previousLevel': 5,
        'xp': 1500,
        'unlocks': ['cosmetic:hat', 'cosmetic:scarf'],
      }),
      verify: (cubit) {
        final state = cubit.state;
        expect(state.householdProgress.level, 6);
        expect(state.unlocks, ['cosmetic:hat', 'cosmetic:scarf']);
        expect(state.celebration!.kind, HouseholdNoticeKind.levelUp);
        expect(state.celebration!.level, 6);
        // UX-P1-SPEC §3: the shared modal is «lo habéis conseguido juntos».
        expect(state.celebration!.message, contains('Lo habéis conseguido juntos'));
        // A shared level-up is modal-class, never a toast.
        expect(state.notice, isNull);
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'ignores a level_up carrying the personal track',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(level: 5),
      act: (cubit) => cubit.applyRealtime('household:level_up', {
        'track': 'personal',
        'level': 9,
        'unlocks': ['title:constante'],
      }),
      verify: (cubit) {
        // A personal level must never move the shared bar, whatever room it
        // arrived on.
        expect(cubit.state.householdProgress.level, 5);
        expect(cubit.state.celebration, isNull);
      },
      expect: () => const <HouseholdEconomyState>[],
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'household:milestone is a toast and corrects the pooled count',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(tasksCompleted: 97),
      act: (cubit) => cubit.applyRealtime('household:milestone', {
        'kind': 'tasks_completed',
        'value': 100,
        'total': 100,
      }),
      verify: (cubit) {
        expect(cubit.state.householdProgress.tasksCompleted, 100);
        expect(cubit.state.notice!.kind, HouseholdNoticeKind.milestone);
        expect(cubit.state.notice!.value, 100);
        expect(cubit.state.notice!.message, contains('100 tareas'));
        // Toast-class, not modal-class (UX-P1-SPEC §3).
        expect(cubit.state.celebration, isNull);
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'two identical milestones in a row both reach the UI',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(tasksCompleted: 97),
      act: (cubit) {
        const payload = {'kind': 'tasks_completed', 'value': 100, 'total': 100};
        cubit.applyRealtime('household:milestone', payload);
        cubit.applyRealtime('household:milestone', payload);
      },
      verify: (cubit) {
        // Equatable would swallow the second without the sequence counter.
        expect(cubit.state.notice!.sequence, 2);
      },
    );
  });

  group('realtime — joint savings', () {
    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'household:savings_goal_created opens the goal',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(),
      act: (cubit) => cubit.applyRealtime('household:savings_goal_created', {
        'id': 'g1',
        'itemType': 'cosmetic',
        'itemId': 'dragon_skin',
        'targetCoins': 100,
        'contributedCoins': 0,
        'status': 'active',
        'createdBy': 'u1',
      }),
      verify: (cubit) {
        final goal = cubit.state.activeSavingsGoal!;
        expect(goal.id, 'g1');
        expect(goal.targetCoins, 100);
        // A brand-new goal has no contributions yet, so nothing is lost by
        // taking the document verbatim.
        expect(goal.contributions, isEmpty);
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'household:savings_contribution increments only the contributor line',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(goal: _goal()),
      act: (cubit) => cubit.applyRealtime('household:savings_contribution', {
        'goalId': 'g1',
        'userId': 'u2',
        'amount': 30,
        'contributedCoins': 98,
        'targetCoins': 100,
      }),
      verify: (cubit) {
        final goal = cubit.state.activeSavingsGoal!;
        expect(goal.contributedCoins, 98);
        // «Ana: 40 · Bea: 58» — Bea has just OVERTAKEN Ana, and the order is
        // still the one it was. The amounts are deliberately unequal and in
        // the "wrong" order for a ranking: any sort by size would flip these
        // two, which is exactly how a breakdown becomes the leaderboard
        // UX-P1-SPEC §8 rules out.
        expect(goal.contributions.map((c) => c.name), ['Ana', 'Bea']);
        expect(goal.contributions.map((c) => c.amount), [40, 58]);
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'a first-time contributor is appended, named from the roster',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(
        members: [
          buildMemberProgress('u1', name: 'Ana'),
          buildMemberProgress('u2', name: 'Bea'),
          buildMemberProgress('u3', name: 'Caro'),
        ],
        goal: _goal(
          contributions: const [
            SavingsContributor(userId: 'u1', name: 'Ana', amount: 40),
          ],
          contributedCoins: 40,
        ),
      ),
      act: (cubit) => cubit.applyRealtime('household:savings_contribution', {
        'goalId': 'g1',
        'userId': 'u3',
        'amount': 55,
        'contributedCoins': 95,
        'targetCoins': 100,
      }),
      verify: (cubit) {
        final contributions = cubit.state.activeSavingsGoal!.contributions;
        // The event carries coins, not a roster row, so the name comes from
        // the members list — and the new line goes LAST, even though 55 is
        // the biggest figure in it and a ranking would put Caro on top.
        expect(contributions.map((c) => c.name), ['Ana', 'Caro']);
        expect(contributions.map((c) => c.amount), [40, 55]);
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'a contribution to an unknown goal refetches instead of guessing',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(goal: _goal(id: 'g1')),
      act: (cubit) => cubit.applyRealtime('household:savings_contribution', {
        'goalId': 'g-other',
        'userId': 'u2',
        'amount': 12,
        'contributedCoins': 12,
        'targetCoins': 100,
      }),
      wait: const Duration(milliseconds: 10),
      verify: (cubit) {
        // The payload has totals but not the item, the price or who opened
        // it — nothing a state can be reconstructed from.
        expect(cubit.state.activeSavingsGoal!.id, isNot('g-other'));
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'household:savings_goal_unlocked keeps the per-member breakdown',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(goal: _goal(contributedCoins: 100)),
      act: (cubit) => cubit.applyRealtime('household:savings_goal_unlocked', {
        // The goal DOCUMENT, exactly as the server sends it — no
        // `contributions` array, because that breakdown lives in another
        // collection and is assembled by the read endpoint.
        'id': 'g1',
        'itemType': 'cosmetic',
        'itemId': 'dragon_skin',
        'targetCoins': 100,
        'contributedCoins': 100,
        'status': 'unlocked',
        'createdBy': 'u1',
      }),
      verify: (cubit) {
        final goal = cubit.state.activeSavingsGoal!;
        expect(goal.isUnlocked, isTrue);
        // Applying the payload verbatim would blank this at the exact moment
        // the household is looking at it.
        expect(goal.contributions.map((c) => c.name), ['Ana', 'Bea']);
        expect(cubit.state.celebration!.kind, HouseholdNoticeKind.goalUnlocked);
        expect(
          cubit.state.celebration!.message,
          contains('Lo habéis conseguido juntos'),
        );
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'household:savings_goal_cancelled clears the goal and says nothing shared',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(goal: _goal()),
      act: (cubit) => cubit.applyRealtime('household:savings_goal_cancelled', {
        'goal': {'id': 'g1', 'status': 'cancelled'},
        'refunds': [
          {'userId': 'u1', 'amount': 40},
          {'userId': 'u2', 'amount': 28},
        ],
      }),
      verify: (cubit) {
        expect(cubit.state.activeSavingsGoal, isNull);
        // The refund figure is personal: it reaches each member as
        // `economy:savings_refunded` on their own room. Announcing it here
        // would tell the whole household what everyone had put in.
        expect(cubit.state.celebration, isNull);
        expect(cubit.state.notice, isNull);
      },
    );
  });

  group('socket wiring', () {
    test('the two rooms carry disjoint event sets', () {
      // The split IS the privacy boundary: personal events reach one member's
      // devices, household ones reach every housemate. An event name in both
      // lists would be one routed to both cubits.
      expect(
        SocketService.economyP1Events
            .toSet()
            .intersection(SocketService.householdEconomyEvents.toSet()),
        isEmpty,
      );
    });

    test('the household list matches the seven documented events', () {
      expect(SocketService.householdEconomyEvents, [
        'household:xp_updated',
        'household:level_up',
        'household:milestone',
        'household:savings_goal_created',
        'household:savings_contribution',
        'household:savings_goal_unlocked',
        'household:savings_goal_cancelled',
      ]);
    });

    test('the personal list subscribes to the refund event', () {
      // F2 listed the ten events the personal economy emitted on its own and
      // left this one out, so a cancelled goal credited coins the app never
      // showed until the next read. Unsubscribing it again is invisible in
      // every cubit test, which drives the payload in directly.
      expect(
        SocketService.economyP1Events,
        contains('economy:savings_refunded'),
      );
    });

    test('every subscribed household event is handled, none falls through',
        () async {
      // The `default` branch refetches. A name that is subscribed but has no
      // `case` would therefore work by accident — at the cost of one GET per
      // event, which is the whole thing this design avoids.
      for (final event in SocketService.householdEconomyEvents) {
        final repo = FakeEconomyP1Repository(
          economy: buildEconomyP1(
            household: buildHouseholdEconomy(members: _roster()),
          ),
        );
        final cubit = _cubit(repo);
        await cubit.load('h1');
        final before = repo.loadCalls;

        cubit.emit(_ready(goal: _goal()));
        // A goal-scoped payload for the one event that legitimately refetches
        // when it cannot find its goal.
        cubit.applyRealtime(event, {'goalId': 'g1'});
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(repo.loadCalls, before, reason: '$event fell through to refetch');
        await cubit.close();
      }
    });
  });

  group('realtime — guards', () {
    test('an event arriving before the first load lands refetches', () async {
      final repo = FakeEconomyP1Repository(
        economy: buildEconomyP1(
          household: buildHouseholdEconomy(xp: 300, members: _roster()),
        ),
      );
      repo.loadGate = Completer<void>();
      final cubit = _cubit(repo);

      // The event beats the first read, the way it can on a cold start.
      final pending = cubit.load('h1');
      await Future<void>.delayed(Duration.zero);
      cubit.applyRealtime('household:xp_updated', {'householdXp': 9, 'level': 9});
      repo.loadGate!.complete();
      await pending;

      // The payload was NOT applied: activation may have just happened, and
      // no payload describes the rest of the structure. The read is.
      expect(cubit.state.householdProgress.xp, 300);
      await cubit.close();
    });

    test('an event while P1 still looks disabled refetches', () async {
      final repo = FakeEconomyP1Repository(
        economy: buildEconomyP1(
          enabled: false,
          household: buildHouseholdEconomy(enabled: false, members: _roster()),
        ),
      );
      final cubit = _cubit(repo);
      await cubit.load('h1');
      expect(cubit.state.enabled, isFalse);

      // Activation just happened server-side; this build does not know yet.
      repo.economy = buildEconomyP1(
        household: buildHouseholdEconomy(level: 2, members: _roster()),
      );
      cubit.applyRealtime('household:xp_updated', {'householdXp': 40, 'level': 2});
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(cubit.state.enabled, isTrue);
      expect(cubit.state.householdProgress.level, 2);
      await cubit.close();
    });

    test('an unknown event name refetches rather than being dropped', () async {
      final repo = FakeEconomyP1Repository(
        economy: buildEconomyP1(
          household: buildHouseholdEconomy(level: 5, members: _roster()),
        ),
      );
      final cubit = _cubit(repo);
      await cubit.load('h1');
      expect(cubit.state.householdProgress.level, 5);

      repo.economy = buildEconomyP1(
        household: buildHouseholdEconomy(level: 8, members: _roster()),
      );
      cubit.applyRealtime('household:something_new', const {});
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // A name this build does not know means the server is ahead of the app;
      // the read is the only honest response.
      expect(cubit.state.householdProgress.level, 8);
      await cubit.close();
    });

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'a malformed payload defaults rather than throwing',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(level: 5, xp: 1000),
      act: (cubit) => cubit.applyRealtime('household:xp_updated', 'not a map'),
      verify: (cubit) {
        // A socket frame must never be able to crash the tab it updates.
        expect(cubit.state.householdProgress.xp, 1000);
        expect(cubit.state.householdProgress.level, 5);
      },
    );

    blocTest<HouseholdEconomyCubit, HouseholdEconomyState>(
      'dismissing a celebration and a notice clears them',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(),
      act: (cubit) {
        cubit.applyRealtime('household:level_up', {
          'track': 'household',
          'level': 6,
          'xp': 1500,
          'unlocks': <String>[],
        });
        cubit.applyRealtime('household:milestone', {
          'kind': 'tasks_completed',
          'value': 100,
          'total': 100,
        });
        cubit.dismissCelebration();
        cubit.dismissNotice();
      },
      verify: (cubit) {
        expect(cubit.state.celebration, isNull);
        expect(cubit.state.notice, isNull);
        // Dismissing is transient by construction: the level itself survives.
        expect(cubit.state.householdProgress.level, 6);
      },
    );
  });
}

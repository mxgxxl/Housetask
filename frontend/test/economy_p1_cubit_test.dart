import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/economy_p1/economy_p1.dart';
import 'package:homesync/presentation/cubit/economy_p1_cubit.dart';
import 'package:homesync/services/device_timezone_service.dart';

import 'fakes.dart';

/// "Mi progreso" — the personal half of the P1 economy (TD-066 F2).
///
/// The properties worth pinning here are the ones a wrong answer would make
/// invisible rather than loud:
///
///  * `enabled: false` must render NOTHING. The backend answers a zeroed
///    structure instead of a 404, so a cubit that trusted the numbers would
///    show a real-looking 0 🪙 wallet and a dead streak to a member whose
///    economy was never switched on.
///  * Socket payloads are applied directly. Ten events must not become ten
///    GETs, and the flame must not lag a tap.
///  * A debit is never queued offline (TD-066-DESIGN §7). Last-write-wins on
///    money can charge twice for one tap.
///  * Sunday releases nothing but still has a claimable remainder (PDR-013).

/// Installs a fake platform answer for the IANA channel (owner decision D2).
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

/// A cubit with every collaborator faked. [connectivity] is passed explicitly
/// so no test touches the real platform channel.
EconomyP1Cubit _cubit(
  FakeEconomyP1Repository repo, {
  FakeConnectivityService? connectivity,
}) =>
    EconomyP1Cubit(
      repo,
      timeZone: DeviceTimeZoneService(),
      connectivity: connectivity ?? FakeConnectivityService(),
    );

/// A loaded, P1-enabled starting point — what every socket event assumes.
///
/// `applyRealtime` deliberately refuses to apply a payload onto a state that
/// is not ready, so a seed is how these tests say "the tab is open".
EconomyP1State _ready({
  int balance = 100,
  int dailyReleased = 10,
  int remaining = 30,
  int level = 3,
  int xp = 250,
  int xpIntoLevel = 50,
  int xpForNextLevel = 100,
  int tasksCompleted = 9,
  List<String> unlocks = const ['title:novato'],
  int streakCurrent = 5,
  int streakLongest = 12,
  int iceReserve = 1,
  bool isOnline = true,
}) =>
    EconomyP1State(
      status: EconomyP1Status.ready,
      enabled: true,
      isOnline: isOnline,
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
      weeklyBudget: const PersonalBudget(weekKey: '2026-W35', weeklyCap: 200),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => _mockTimeZone('Europe/Madrid'));
  tearDown(_clearTimeZoneMock);

  group('DeviceTimeZoneService', () {
    test('returns the platform IANA id', () async {
      _mockTimeZone('America/Bogota');
      expect(await DeviceTimeZoneService().resolve(), 'America/Bogota');
    });

    test('falls back to UTC when no handler is registered', () async {
      // TD-066-DESIGN decision 1 names UTC as the documented v1 fallback.
      _clearTimeZoneMock();
      expect(await DeviceTimeZoneService().resolve(), 'UTC');
    });

    test('falls back to UTC when the platform answers empty', () async {
      _mockTimeZone('');
      expect(await DeviceTimeZoneService().resolve(), 'UTC');
    });

    test('resolves once and memoizes', () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(DeviceTimeZoneService.channelName),
        (call) async {
          calls++;
          return 'Europe/Madrid';
        },
      );

      final service = DeviceTimeZoneService();
      await service.resolve();
      await service.resolve();

      expect(calls, 1);
    });
  });

  group('EconomyP1Cubit.load', () {
    test('sends the device timezone on every read', () async {
      final repo = FakeEconomyP1Repository();
      final cubit = _cubit(repo);

      await cubit.load('h1');

      // The whole reason F1 made timeZone required: a UTC default counts a
      // Madrid Monday 00:30 completion against Sunday (PDR-013).
      expect(repo.loadedTimeZones, ['Europe/Madrid']);
      await cubit.close();
    });

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'emits ready and enabled with fresh, non-stale content',
      build: () => _cubit(
        FakeEconomyP1Repository(
          economy: buildEconomyP1(
            personal: buildPersonalEconomy(balance: 42, streakCurrent: 7),
          ),
        ),
      ),
      act: (cubit) => cubit.load('h1'),
      expect: () => [
        isA<EconomyP1State>().having((s) => s.status, 'status', EconomyP1Status.loading),
        isA<EconomyP1State>()
            .having((s) => s.status, 'status', EconomyP1Status.ready)
            .having((s) => s.enabled, 'enabled', true)
            .having((s) => s.isStale, 'isStale', false)
            .having((s) => s.wallet.balance, 'balance', 42)
            .having((s) => s.streak.current, 'streak.current', 7),
      ],
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'stays hidden when P1 is off for the household',
      build: () => _cubit(
        FakeEconomyP1Repository(economy: buildEconomyP1(enabled: false)),
      ),
      act: (cubit) => cubit.load('h1'),
      // The section must not render, and NOT because it is empty — because
      // the flag is off. Zeroes here are structure, not truth.
      verify: (cubit) {
        expect(cubit.state.enabled, isFalse);
        expect(cubit.state.isVisible, isFalse);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'hides the section when only the household half reports enabled',
      build: () => _cubit(
        FakeEconomyP1Repository(
          economy: EconomyP1(
            personal: buildPersonalEconomy(enabled: false),
            household: const HouseholdEconomy(enabled: true),
          ),
        ),
      ),
      act: (cubit) => cubit.load('h1'),
      // Mid-activation the two endpoints can disagree. Half a feature is
      // worse than none.
      verify: (cubit) => expect(cubit.state.enabled, isFalse),
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'serves the cached snapshot marked stale when the network fails',
      build: () => _cubit(
        FakeEconomyP1Repository(
          cachedEconomy: buildEconomyP1(
            personal: buildPersonalEconomy(balance: 88, streakCurrent: 4),
          ),
        )..loadError = const NetworkFailure('sin conexión'),
      ),
      act: (cubit) => cubit.load('h1'),
      verify: (cubit) {
        // A stale wallet beats an error screen — but the UI has to be able
        // to say it is stale.
        expect(cubit.state.status, EconomyP1Status.ready);
        expect(cubit.state.isStale, isTrue);
        expect(cubit.state.wallet.balance, 88);
        expect(cubit.state.error, isNull);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'fails only when offline with nothing cached to show',
      build: () => _cubit(
        FakeEconomyP1Repository()..loadError = const NetworkFailure('sin conexión'),
      ),
      act: (cubit) => cubit.load('h1'),
      verify: (cubit) {
        expect(cubit.state.status, EconomyP1Status.failure);
        expect(cubit.state.error, 'sin conexión');
      },
    );

    test('paints the cache before the network answers', () async {
      final repo = FakeEconomyP1Repository(
        cachedEconomy: buildEconomyP1(
          personal: buildPersonalEconomy(balance: 5),
        ),
        economy: buildEconomyP1(personal: buildPersonalEconomy(balance: 9)),
      );
      final cubit = _cubit(repo);
      final seen = <int>[];
      final sub = cubit.stream.listen((s) => seen.add(s.wallet.balance));

      await cubit.load('h1');
      await Future<void>.delayed(Duration.zero);

      // Cached first so the tab opens on content, then the fresh value.
      expect(seen, [5, 9]);
      await sub.cancel();
      await cubit.close();
    });

    test('coalesces concurrent refreshes into a single request', () async {
      final repo = FakeEconomyP1Repository();
      final cubit = _cubit(repo);

      await cubit.load('h1');
      expect(repo.loadCalls, 1);

      await Future.wait([cubit.refresh(), cubit.refresh(), cubit.refresh()]);

      // Three callers, one round trip.
      expect(repo.loadCalls, 2);
      await cubit.close();
    });
  });

  group('EconomyP1Cubit realtime — payload is applied directly', () {
    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:reward credits the wallet and spends the week\'s remainder',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(balance: 100, remaining: 30, xp: 250, xpIntoLevel: 50),
      act: (cubit) => cubit.applyRealtime(
        'economy:reward',
        {'receiptId': 'r1', 'coins': 4, 'personalXp': 10},
      ),
      verify: (cubit) {
        final s = cubit.state;
        expect(s.wallet.balance, 104);
        // A reward IS the budget being spent on the member.
        expect(s.wallet.remaining, 26);
        expect(s.personalProgress.xp, 260);
        expect(s.personalProgress.xpIntoLevel, 60);
        expect(s.personalProgress.tasksCompleted, 10);
        // Levels are server-authoritative; only economy:level_up moves one.
        expect(s.personalProgress.level, 3);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:reward never drives the remainder below zero',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(remaining: 2),
      act: (cubit) => cubit.applyRealtime(
        'economy:reward',
        {'coins': 9, 'personalXp': 0},
      ),
      verify: (cubit) => expect(cubit.state.wallet.remaining, 0),
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:budget_updated takes dailyReleased and remaining verbatim',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(dailyReleased: 10, remaining: 30),
      act: (cubit) => cubit.applyRealtime(
        'economy:budget_updated',
        {'weekKey': '2026-W36', 'remaining': 24, 'dailyReleased': 0},
      ),
      verify: (cubit) {
        final s = cubit.state;
        // Sunday: nothing released, but the week's remainder is claimable
        // (PDR-013). Deriving one from the other would erase that case.
        expect(s.wallet.dailyReleased, 0);
        expect(s.wallet.remaining, 24);
        expect(s.isRestDay, isTrue);
        expect(s.weeklyBudget.weekKey, '2026-W36');
        // The cap is not in the payload and must survive.
        expect(s.weeklyBudget.weeklyCap, 200);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:streak_updated moves the flame',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(streakCurrent: 5, streakLongest: 12, iceReserve: 1),
      act: (cubit) => cubit.applyRealtime(
        'economy:streak_updated',
        {'current': 6, 'longest': 12, 'iceReserve': 1},
      ),
      verify: (cubit) => expect(cubit.state.streak.current, 6),
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:ice_consumed spends an ice and raises the spec relief banner',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(streakCurrent: 12, iceReserve: 2),
      act: (cubit) => cubit.applyRealtime(
        'economy:ice_consumed',
        {'dayKey': '2026-08-29', 'iceReserve': 1, 'current': 12},
      ),
      verify: (cubit) {
        final s = cubit.state;
        expect(s.streak.iceReserve, 1);
        // UX-P1-SPEC §7, verbatim including the flame count.
        expect(
          s.notice?.message,
          'Ayer fue un día complicado. Un hielo cubrió tu racha 🔥 12',
        );
        expect(s.notice?.kind, EconomyP1NoticeKind.iceConsumed);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:ice_refunded restores the reserve',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(iceReserve: 0),
      act: (cubit) => cubit.applyRealtime('economy:ice_refunded', {'iceReserve': 1}),
      verify: (cubit) {
        expect(cubit.state.streak.iceReserve, 1);
        expect(cubit.state.notice?.kind, EconomyP1NoticeKind.iceRefunded);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:streak_broken resets the flame without touching level, XP or coins',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(balance: 100, level: 3, xp: 250, streakCurrent: 9, streakLongest: 12),
      act: (cubit) => cubit.applyRealtime('economy:streak_broken', {'dayKey': '2026-08-29'}),
      verify: (cubit) {
        final s = cubit.state;
        expect(s.streak.current, 0);
        // PDR-019: a bad day costs the flame and nothing else. The longest
        // run is the proof the progress survived.
        expect(s.streak.longest, 12);
        expect(s.personalProgress.level, 3);
        expect(s.personalProgress.xp, 250);
        expect(s.wallet.balance, 100);
        // UX-P1-SPEC §7, verbatim and blame-free.
        expect(s.notice?.message, 'La racha se reinicia; tu nivel y tu XP siguen intactos');
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:streak_milestone records the milestone and the earned ice',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(streakCurrent: 6, streakLongest: 6, iceReserve: 0),
      act: (cubit) => cubit.applyRealtime(
        'economy:streak_milestone',
        {'value': 7, 'current': 7, 'iceReserve': 1},
      ),
      verify: (cubit) {
        final s = cubit.state;
        expect(s.streak.current, 7);
        expect(s.streak.longest, 7);
        expect(s.streak.iceReserve, 1);
        expect(s.streak.iceMilestonesReached, [7]);
        expect(s.notice?.kind, EconomyP1NoticeKind.streakMilestone);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:ice_purchased takes the server balance rather than subtracting',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(balance: 100, iceReserve: 0),
      act: (cubit) => cubit.applyRealtime(
        'economy:ice_purchased',
        {'iceReserve': 1, 'spent': 20, 'balance': 80},
      ),
      verify: (cubit) {
        // Also arrives when the purchase happened on another device, which
        // is why the balance is read, not computed.
        expect(cubit.state.wallet.balance, 80);
        expect(cubit.state.streak.iceReserve, 1);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:level_up raises a celebration and restarts the ring',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(level: 3, xp: 250, xpIntoLevel: 95, xpForNextLevel: 100),
      act: (cubit) => cubit.applyRealtime('economy:level_up', {
        'track': 'personal',
        'level': 4,
        'previousLevel': 3,
        'xp': 300,
        'unlocks': ['title:constante', 'badge:cuatro'],
      }),
      verify: (cubit) {
        final s = cubit.state;
        expect(s.personalProgress.level, 4);
        expect(s.personalProgress.xp, 300);
        expect(s.unlocks, ['title:constante', 'badge:cuatro']);
        expect(s.personalProgress.xpIntoLevel, 0);
        expect(s.celebration?.kind, EconomyP1NoticeKind.levelUp);
        expect(s.celebration?.level, 4);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:level_up for the household track never moves the personal ring',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(level: 3),
      act: (cubit) => cubit.applyRealtime('economy:level_up', {
        'track': 'household',
        'level': 6,
      }),
      verify: (cubit) {
        // The shared track is F3's, and it unlocks different things.
        expect(cubit.state.personalProgress.level, 3);
        expect(cubit.state.celebration, isNull);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'economy:milestone corrects the optimistic task count',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(tasksCompleted: 9),
      act: (cubit) => cubit.applyRealtime(
        'economy:milestone',
        {'kind': 'tasks_completed', 'value': 10, 'total': 10},
      ),
      verify: (cubit) {
        expect(cubit.state.personalProgress.tasksCompleted, 10);
        expect(cubit.state.celebration?.kind, EconomyP1NoticeKind.milestone);
        expect(cubit.state.celebration?.value, 10);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'a malformed payload leaves the state intact instead of throwing',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(balance: 100),
      act: (cubit) => cubit.applyRealtime('economy:reward', 'not-a-map'),
      // A socket frame must never be able to crash the tab it updates.
      verify: (cubit) => expect(cubit.state.wallet.balance, 100),
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'two identical notices both reach the UI',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(streakCurrent: 3),
      act: (cubit) {
        cubit.applyRealtime('economy:streak_broken', {'dayKey': 'd1'});
        cubit.applyRealtime('economy:streak_broken', {'dayKey': 'd2'});
      },
      // Equatable would collapse the second into the first without the
      // monotonic sequence, and the member would never see it.
      expect: () => [
        isA<EconomyP1State>().having((s) => s.notice?.sequence, 'sequence', 1),
        isA<EconomyP1State>().having((s) => s.notice?.sequence, 'sequence', 2),
      ],
    );
  });

  group('EconomyP1Cubit realtime — refetch fallbacks', () {
    test('an unknown event refetches, coalesced', () async {
      final repo = FakeEconomyP1Repository();
      final cubit = _cubit(repo);
      await cubit.load('h1');
      expect(repo.loadCalls, 1);

      // The server knows something this build does not; the payload cannot
      // be trusted to describe it.
      cubit.applyRealtime('economy:something_new', {'x': 1});
      cubit.applyRealtime('economy:another_new', {'y': 2});
      await Future<void>.delayed(Duration.zero);

      expect(repo.loadCalls, 2);
      await cubit.close();
    });

    test('an event arriving while P1 looks disabled refetches', () async {
      // Activation just happened server-side; no payload can describe the
      // rest of the structure.
      final repo = FakeEconomyP1Repository(economy: buildEconomyP1(enabled: false));
      final cubit = _cubit(repo);
      await cubit.load('h1');
      final before = repo.loadCalls;

      cubit.applyRealtime('economy:reward', {'coins': 5, 'personalXp': 5});
      await Future<void>.delayed(Duration.zero);

      expect(repo.loadCalls, before + 1);
      await cubit.close();
    });
  });

  group('EconomyP1Cubit.buyIce', () {
    late FakeEconomyP1Repository repo;
    late FakeConnectivityService connectivity;

    /// Goes through `load` rather than seeding a state: `buyIce` needs the
    /// household id that only a real load sets, and routing the setup through
    /// the same path the app uses keeps the test honest about it.
    EconomyP1Cubit buildCubit({
      bool enabled = true,
      int balance = 100,
      int iceReserve = 0,
      Map<String, dynamic> buyIceResult = const {},
      Object? buyIceError,
      FakeConnectivityService? connectivity,
    }) {
      repo = FakeEconomyP1Repository(
        economy: buildEconomyP1(
          enabled: enabled,
          personal: buildPersonalEconomy(
            enabled: enabled,
            balance: balance,
            iceReserve: iceReserve,
            streakCurrent: 5,
          ),
        ),
      )
        ..buyIceResult = buyIceResult
        ..buyIceError = buyIceError;
      return _cubit(repo, connectivity: connectivity);
    }

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'is unavailable while the flag is off',
      build: () => buildCubit(enabled: false),
      act: (cubit) async {
        await cubit.load('h1');
        await cubit.buyIce();
      },
      verify: (cubit) {
        expect(cubit.state.iceUnavailableReason, IceUnavailableReason.flagOff);
        expect(repo.buyIceOperationIds, isEmpty);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'is unavailable with the reserve already full',
      build: () => buildCubit(iceReserve: kMaxIceReserve),
      act: (cubit) async {
        await cubit.load('h1');
        await cubit.buyIce();
      },
      verify: (cubit) {
        expect(cubit.state.iceUnavailableReason, IceUnavailableReason.reserveFull);
        expect(repo.buyIceOperationIds, isEmpty);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'is unavailable below the price',
      build: () => buildCubit(balance: kIcePriceCoins - 1),
      act: (cubit) async {
        await cubit.load('h1');
        await cubit.buyIce();
      },
      verify: (cubit) {
        expect(cubit.state.iceUnavailableReason, IceUnavailableReason.insufficientCoins);
        expect(repo.buyIceOperationIds, isEmpty);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'greys the button out once the connectivity stream reports offline',
      build: () {
        connectivity = FakeConnectivityService()..online = false;
        return buildCubit(connectivity: connectivity);
      },
      act: (cubit) async {
        await cubit.load('h1');
        connectivity.controller.add(false);
        await Future<void>.delayed(Duration.zero);
        await cubit.buyIce();
      },
      verify: (cubit) {
        // TD-066-DESIGN §7: a debit must NOT adopt last-write-wins. The
        // button is disabled, nothing reached the repository, and nothing
        // was queued for later.
        expect(cubit.state.isOnline, isFalse);
        expect(cubit.state.iceUnavailableReason, IceUnavailableReason.offline);
        expect(repo.buyIceOperationIds, isEmpty);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'surfaces an offline transition caught on the hot path',
      // The button still looked enabled — the connectivity stream had not
      // caught up — so the last check before spending money is the one that
      // counts, and it must still queue nothing.
      build: () => buildCubit(connectivity: FakeConnectivityService()..online = false),
      act: (cubit) async {
        await cubit.load('h1');
        await cubit.buyIce();
      },
      verify: (cubit) {
        expect(repo.buyIceOperationIds, isEmpty);
        expect(cubit.state.actionError, isNotNull);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'buys with a stable idempotency key and applies the server echo',
      build: () => buildCubit(
        buyIceResult: const {'iceReserve': 1, 'spent': 20, 'balance': 80},
      ),
      act: (cubit) async {
        await cubit.load('h1');
        await cubit.buyIce();
      },
      verify: (cubit) {
        expect(repo.buyIceOperationIds, hasLength(1));
        expect(repo.buyIceOperationIds.single, isNotEmpty);
        expect(cubit.state.wallet.balance, 80);
        expect(cubit.state.streak.iceReserve, 1);
        expect(cubit.state.isBuyingIce, isFalse);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'shows a 409 conflict without retrying',
      build: () => buildCubit(buyIceError: const ConflictFailure('Operación en curso')),
      act: (cubit) async {
        await cubit.load('h1');
        await cubit.buyIce();
      },
      // A 409 means the original request is still running; retrying would be
      // the one thing guaranteed to make it worse.
      verify: (cubit) {
        expect(repo.buyIceOperationIds, hasLength(1));
        expect(cubit.state.actionError, 'Operación en curso');
        expect(cubit.state.isBuyingIce, isFalse);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'shows a 401 without queuing the debit',
      build: () => buildCubit(buyIceError: const AuthFailure('Sesión expirada')),
      act: (cubit) async {
        await cubit.load('h1');
        await cubit.buyIce();
      },
      verify: (cubit) {
        expect(cubit.state.actionError, 'Sesión expirada');
        expect(cubit.state.wallet.balance, 100);
      },
    );

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'shows a 403 without queuing the debit',
      build: () => buildCubit(
        buyIceError: const ServerFailure('No autorizado', statusCode: 403),
      ),
      act: (cubit) async {
        await cubit.load('h1');
        await cubit.buyIce();
      },
      verify: (cubit) {
        expect(cubit.state.actionError, 'No autorizado');
        expect(cubit.state.wallet.balance, 100);
      },
    );
  });

  group('EconomyP1State', () {
    test('separates a rest day from an exhausted week', () {
      // Sunday: nothing released, remainder still claimable (PDR-013).
      expect(_ready(dailyReleased: 0, remaining: 24).isRestDay, isTrue);
      expect(_ready(dailyReleased: 0, remaining: 24).isExhausted, isFalse);
      // Spent out: nothing released and nothing left.
      expect(_ready(dailyReleased: 0, remaining: 0).isRestDay, isFalse);
      expect(_ready(dailyReleased: 0, remaining: 0).isExhausted, isTrue);
    });

    test('copyWith clears nullable fields only when asked (TD-056)', () {
      final withNotice = _ready().copyWith(
        notice: const EconomyP1Notice(
          kind: EconomyP1NoticeKind.iceRefunded,
          message: 'x',
          sequence: 1,
        ),
        actionError: 'boom',
      );

      // An unrelated copyWith must not silently drop them...
      expect(withNotice.copyWith(isOnline: false).notice, isNotNull);
      expect(withNotice.copyWith(isOnline: false).actionError, 'boom');
      // ...and must be able to, when that is the intent.
      expect(withNotice.copyWith(clearNotice: true).notice, isNull);
      expect(withNotice.copyWith(clearActionError: true).actionError, isNull);
    });

    test('unlocks read through to the progress that owns them', () {
      expect(_ready(unlocks: const ['a', 'b']).unlocks, ['a', 'b']);
    });
  });

  group('EconomyP1Cubit.reset', () {
    test('a response landing after reset is dropped', () async {
      final gate = Completer<void>();
      final repo = FakeEconomyP1Repository(
        economy: buildEconomyP1(personal: buildPersonalEconomy(balance: 500)),
      )..loadGate = gate;
      final cubit = _cubit(repo);

      final pending = cubit.load('h1');
      cubit.reset();
      gate.complete();
      await pending;

      // Logging out and straight back in as someone else must not let the
      // previous member's wallet land on the new session's screen.
      expect(cubit.state, const EconomyP1State());
      await cubit.close();
    });

    blocTest<EconomyP1Cubit, EconomyP1State>(
      'drops personal data on logout (TD-055/TD-058)',
      build: () => _cubit(FakeEconomyP1Repository()),
      seed: () => _ready(balance: 500, streakCurrent: 30),
      act: (cubit) => cubit.reset(),
      // A wallet and a streak belong to whoever just logged out.
      expect: () => [const EconomyP1State()],
    );
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/models/economy_p1/economy_p1.dart';
import 'package:homesync/data/models/economy_p1/economy_p1_snapshot.dart';
import 'package:homesync/data/repositories/economy_p1_repository.dart';
import 'package:homesync/services/cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Models, repository and cache for the P1 economy (TD-066 F1).
///
/// The properties worth pinning here are the ones a wrong answer would make
/// invisible:
///
///  * `timeZone` reaches the server on every call that decides a day or a
///    week. Forgetting it does not fail — it silently counts a Monday task
///    against Sunday, the one day that pays nothing (PDR-013).
///  * A cache written by another schema version is DISCARDED, not coerced. A
///    half-understood wallet is worse than no wallet.
///  * The cache dies with the account that wrote it (TD-062).
class _RecordingAdapter implements HttpClientAdapter {
  final List<ResponseBody Function()> responses;
  final List<RequestOptions> requests = [];
  int _index = 0;

  _RecordingAdapter(this.responses);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final build = _index < responses.length ? responses[_index] : responses.last;
    _index++;
    return build();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, int status) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

Map<String, dynamic> _envelope(Map<String, dynamic> data) => {'success': true, 'data': data};

Map<String, dynamic> _personalJson({bool enabled = true}) => {
      'enabled': enabled,
      'wallet': {'balance': 57, 'dailyReleased': 33, 'remaining': 28},
      'personalProgress': {
        'xp': 120,
        'level': 2,
        'unlocks': ['title:aprendiz'],
        'tasksCompleted': 12,
        'xpIntoLevel': 20,
        'xpForNextLevel': 200,
        'xpToNextLevel': 180,
      },
      'streak': {
        'current': 5,
        'longest': 15,
        'iceReserve': 1,
        'iceMilestonesReached': [7, 14],
      },
      'weeklyBudget': {
        'weekKey': '2026-W35',
        'periodTimeZone': 'Europe/Madrid',
        'weeklyCap': 200,
        'releasedCoins': 133,
        'grantedCoins': 105,
        'planVersion': 3,
        'allocations': [
          {
            'allocationKey': 'rule:abc',
            'taskOrRuleId': 'abc',
            'expectedFrequency': 700,
            'coinAmount': 4,
            'mode': 'manual',
          },
          {
            'allocationKey': 'common:unassigned',
            'expectedFrequency': 200,
            'coinAmount': 20,
            'mode': 'automatic',
          },
        ],
      },
    };

Map<String, dynamic> _householdJson({bool enabled = true, bool withGoal = true}) => {
      'enabled': enabled,
      'householdProgress': {
        'xp': 400,
        'level': 2,
        'unlocks': ['cosmetic:hat'],
        'tasksCompleted': 40,
        'xpIntoLevel': 200,
        'xpForNextLevel': 400,
        'xpToNextLevel': 200,
      },
      'activeSavingsGoal': withGoal
          ? {
              'id': 'g1',
              'itemType': 'cosmetic',
              'itemId': 'glasses',
              'targetCoins': 40,
              'contributedCoins': 28,
              'status': 'active',
              'createdBy': 'u1',
              'contributions': [
                {'userId': 'u1', 'name': 'Ana', 'amount': 18},
                {'userId': 'u2', 'name': 'Bea', 'amount': 10},
              ],
            }
          : null,
      'members': [
        {'userId': 'u1', 'name': 'Ana', 'avatarUrl': null, 'level': 2, 'xp': 120},
        {'userId': 'u2', 'name': 'Bea', 'avatarUrl': null, 'level': 3, 'xp': 400},
      ],
    };

EconomyP1Repository _repoWith(_RecordingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))..httpClientAdapter = adapter;
  return EconomyP1Repository(ApiService(AuthLocalDataSource(), dio: dio), CacheService());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('homesync_p1_f1_test');
    await CacheService().init(testDirectory: tempDir.path);
  });

  tearDown(() async {
    await CacheService().clearAll();
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('model parsing', () {
    test('reads the personal half field for field', () {
      final personal = PersonalEconomy.fromJson(_personalJson());

      expect(personal.enabled, isTrue);
      expect(personal.wallet.balance, 57);
      expect(personal.wallet.dailyReleased, 33);
      expect(personal.wallet.remaining, 28);

      expect(personal.personalProgress.level, 2);
      expect(personal.personalProgress.unlocks, ['title:aprendiz']);
      expect(personal.personalProgress.tasksCompleted, 12);
      expect(personal.personalProgress.progressToNext, closeTo(0.1, 0.0001));

      expect(personal.streak.current, 5);
      expect(personal.streak.longest, 15);
      expect(personal.streak.iceMilestonesReached, [7, 14]);

      expect(personal.weeklyBudget.weekKey, '2026-W35');
      expect(personal.weeklyBudget.periodTimeZone, 'Europe/Madrid');
      expect(personal.weeklyBudget.allocations, hasLength(2));
      expect(personal.weeklyBudget.hasManualEdits, isTrue);
      expect(personal.weeklyBudget.allocations[1].isCommonTranche, isTrue);
    });

    test('reads the household half, including the per-member breakdown', () {
      final household = HouseholdEconomy.fromJson(_householdJson());

      expect(household.householdProgress.level, 2);
      expect(household.activeSavingsGoal!.itemId, 'glasses');
      expect(household.activeSavingsGoal!.progress, closeTo(0.7, 0.0001));
      // "Tú: 18 · Bea: 10" — one figure per person, in the order sent.
      expect(
        household.activeSavingsGoal!.contributions.map((c) => c.name),
        ['Ana', 'Bea'],
      );
      // Join order, NOT ranked by XP: the member with less XP comes first
      // because they joined first, and a client that sorted would render the
      // leaderboard the product rules out.
      expect(household.members.map((m) => m.xp), [120, 400]);
    });

    test('handles an absent goal without inventing one', () {
      final household = HouseholdEconomy.fromJson(_householdJson(withGoal: false));
      expect(household.activeSavingsGoal, isNull);
    });

    test('survives missing and oddly-typed fields instead of crashing', () {
      // An older build talking to a newer server, or vice versa. Defaulting
      // beats throwing: showing 0 where the truth was 5 is corrected by the
      // next refresh; a crash over a wallet balance is not.
      final personal = PersonalEconomy.fromJson(const {
        'wallet': {'balance': 12.0},
      });
      expect(personal.enabled, isFalse);
      expect(personal.wallet.balance, 12);
      expect(personal.personalProgress.level, 1);
      expect(personal.weeklyBudget.allocations, isEmpty);
    });

    test('never divides by zero when a level or a goal is empty', () {
      // A NaN reaches Flutter as a layout exception, not as a wrong number.
      expect(const ProgressP1().progressToNext, 0);
      expect(const SavingsGoal(id: 'g').progress, 0);
    });

    test('round-trips through toJson', () {
      final original = PersonalEconomy.fromJson(_personalJson());
      final again = PersonalEconomy.fromJson(original.toJson());
      expect(again, original);
    });
  });

  group('loading', () {
    test('sends timeZone on the personal read', () async {
      // The parameter that is required precisely because forgetting it fails
      // silently: a Monday task counted against Sunday pays nothing.
      final adapter = _RecordingAdapter([
        () => _json(_envelope(_personalJson()), 200),
        () => _json(_envelope(_householdJson()), 200),
      ]);
      final repo = _repoWith(adapter);

      await repo.load('h1', timeZone: 'Europe/Madrid');

      expect(adapter.requests.first.path, contains('/economy/p1/me'));
      expect(adapter.requests.first.queryParameters['timeZone'], 'Europe/Madrid');
      expect(adapter.requests[1].path, contains('/economy/p1/household'));
    });

    test('caches both halves as one snapshot', () async {
      final repo = _repoWith(_RecordingAdapter([
        () => _json(_envelope(_personalJson()), 200),
        () => _json(_envelope(_householdJson()), 200),
      ]));

      final loaded = await repo.load('h1', timeZone: 'UTC');
      expect(loaded.enabled, isTrue);
      expect(loaded.refreshedAt, isNotNull);

      final cached = repo.cached('h1');
      expect(cached, isNotNull);
      expect(cached!.personal.wallet.balance, 57);
      expect(cached.household.activeSavingsGoal!.itemId, 'glasses');
    });

    test('falls back to the cached snapshot when the network fails', () async {
      // A stale wallet beats an error screen; `refreshedAt` lets the UI say
      // how stale it is.
      final repo = _repoWith(_RecordingAdapter([
        () => _json(_envelope(_personalJson()), 200),
        () => _json(_envelope(_householdJson()), 200),
      ]));
      await repo.load('h1', timeZone: 'UTC');

      final offline = _repoWith(_RecordingAdapter([
        () => _json({'success': false, 'error': 'nope'}, 503),
      ]));
      final result = await offline.load('h1', timeZone: 'UTC');

      expect(result.personal.wallet.balance, 57);
    });

    test('rethrows when there is nothing cached to fall back to', () async {
      final repo = _repoWith(_RecordingAdapter([
        () => _json({'success': false, 'error': 'nope'}, 503),
      ]));

      await expectLater(repo.load('h-empty', timeZone: 'UTC'), throwsA(anything));
    });

    test('reports enabled false while P1 is off, without erroring', () async {
      // Every household today. The API answers a complete zeroed structure
      // rather than a 404, so the UI hides itself instead of showing an error.
      final repo = _repoWith(_RecordingAdapter([
        () => _json(_envelope(_personalJson(enabled: false)), 200),
        () => _json(_envelope(_householdJson(enabled: false)), 200),
      ]));

      final loaded = await repo.load('h1', timeZone: 'UTC');
      expect(loaded.enabled, isFalse);
    });

    test('treats a half-enabled reading as disabled', () async {
      // The two halves come from two requests and could disagree during an
      // activation; rendering half a feature is worse than rendering none.
      final repo = _repoWith(_RecordingAdapter([
        () => _json(_envelope(_personalJson(enabled: true)), 200),
        () => _json(_envelope(_householdJson(enabled: false)), 200),
      ]));

      final loaded = await repo.load('h1', timeZone: 'UTC');
      expect(loaded.enabled, isFalse);
    });
  });

  group('cache versioning and ownership', () {
    test('discards a snapshot written by another schema version', () async {
      await CacheService().saveEconomyP1(
        'h1',
        EconomyP1Snapshot(
          householdId: 'h1',
          personal: PersonalEconomy.fromJson(_personalJson()),
          household: HouseholdEconomy.fromJson(_householdJson()),
          refreshedAt: DateTime.now().toUtc(),
          schemaVersion: EconomyP1Snapshot.currentSchemaVersion + 1,
        ),
      );

      // Not coerced, not partially read: gone.
      expect(CacheService().economyP1('h1'), isNull);
    });

    test('discards a snapshot written before versioning existed', () {
      final legacy = EconomyP1Snapshot.fromJson({
        'householdId': 'h1',
        'personal': _personalJson(),
        'household': _householdJson(),
        'refreshedAt': DateTime.now().toUtc().toIso8601String(),
      });
      expect(legacy.schemaVersion, 0);
      expect(legacy.isReadable, isFalse);
    });

    test('dies with the account that wrote it (TD-062)', () async {
      // A wallet balance is the last thing that may survive a change of
      // account on a shared device.
      final repo = _repoWith(_RecordingAdapter([
        () => _json(_envelope(_personalJson()), 200),
        () => _json(_envelope(_householdJson()), 200),
      ]));
      await repo.load('h1', timeZone: 'UTC');
      expect(repo.cached('h1'), isNotNull);

      await CacheService().clearAll();

      expect(repo.cached('h1'), isNull);
    });

    test('clears one household without touching another', () async {
      final repo = _repoWith(_RecordingAdapter([
        () => _json(_envelope(_personalJson()), 200),
        () => _json(_envelope(_householdJson()), 200),
      ]));
      await repo.load('h1', timeZone: 'UTC');
      await repo.load('h2', timeZone: 'UTC');

      await repo.clearCache('h1');

      expect(repo.cached('h1'), isNull);
      expect(repo.cached('h2'), isNotNull);
    });
  });

  group('writes', () {
    test('adjustBudget sends the timezone, the mode and only coinAmount', () async {
      final adapter = _RecordingAdapter([
        () => _json(
              _envelope({'weeklyBudget': _personalJson()['weeklyBudget']}),
              200,
            ),
      ]);
      final repo = _repoWith(adapter);

      await repo.adjustBudget(
        'h1',
        timeZone: 'Europe/Madrid',
        mode: 'manual',
        weekKey: '2026-W35',
        allocations: const [
          BudgetAllocation(
            allocationKey: 'rule:abc',
            expectedFrequency: 700,
            coinAmount: 6,
            mode: 'manual',
          ),
        ],
      );

      final body = adapter.requests.first.data as Map<String, dynamic>;
      expect(body['timeZone'], 'Europe/Madrid');
      expect(body['mode'], 'manual');
      expect(body['weekKey'], '2026-W35');
      // expectedFrequency is an observation about the household's work, not a
      // preference — sending it would be asking to raise one's own ceiling.
      expect(body['allocations'], const [
        {'allocationKey': 'rule:abc', 'coinAmount': 6},
      ]);
    });

    test('adjustBudget in automatic mode sends no allocations at all', () async {
      final adapter = _RecordingAdapter([
        () => _json(_envelope({'weeklyBudget': _personalJson()['weeklyBudget']}), 200),
      ]);

      await _repoWith(adapter).adjustBudget('h1', timeZone: 'UTC', mode: 'automatic');

      final body = adapter.requests.first.data as Map<String, dynamic>;
      expect(body.containsKey('allocations'), isFalse);
    });

    test('buyIce reuses the caller\'s operation id as the Idempotency-Key', () async {
      // A timeout that actually reached the server must replay, not buy a
      // second ice.
      final adapter = _RecordingAdapter([
        () => _json(_envelope({'iceReserve': 1, 'spent': 20, 'balance': 37}), 200),
      ]);

      final result = await _repoWith(adapter).buyIce('h1', operationId: 'op-abc');

      expect(adapter.requests.first.headers['Idempotency-Key'], 'op-abc');
      expect(result['iceReserve'], 1);
    });

    test('createSavingsGoal sends the item, never a price', () async {
      // A client that could name its own target would unlock a 40-coin
      // cosmetic by declaring the target to be 1.
      final adapter = _RecordingAdapter([
        () => _json(_envelope({'goal': _householdJson()['activeSavingsGoal']}), 201),
      ]);

      final goal = await _repoWith(adapter)
          .createSavingsGoal('h1', itemType: 'cosmetic', itemId: 'glasses');

      final body = adapter.requests.first.data as Map<String, dynamic>;
      expect(body, {'itemType': 'cosmetic', 'itemId': 'glasses'});
      expect(body.containsKey('targetCoins'), isFalse);
      expect(goal.targetCoins, 40);
    });

    test('contribute carries the amount and its operation id', () async {
      final adapter = _RecordingAdapter([
        () => _json(_envelope({'goal': _householdJson()['activeSavingsGoal']}), 200),
      ]);

      await _repoWith(adapter).contribute('h1', 'g1', amount: 10, operationId: 'op-c');

      expect(adapter.requests.first.path, contains('/savings-goals/g1/contributions'));
      expect((adapter.requests.first.data as Map)['amount'], 10);
      expect(adapter.requests.first.headers['Idempotency-Key'], 'op-c');
    });

    test('cancelSavingsGoal POSTs to /cancel rather than DELETEing', () async {
      // The goal survives as history with status 'cancelled'; a DELETE would
      // tell the client the opposite of what happened.
      final adapter = _RecordingAdapter([
        () => _json(_envelope({'goal': _householdJson()['activeSavingsGoal'], 'refunds': []}), 200),
      ]);

      await _repoWith(adapter).cancelSavingsGoal('h1', 'g1');

      expect(adapter.requests.first.method, 'POST');
      expect(adapter.requests.first.path, contains('/savings-goals/g1/cancel'));
    });

    test('surfaces server errors instead of queueing the write', () async {
      // TD-066-DESIGN §7: contributing, cancelling and buying ice must NOT be
      // queued until their offline compensation is designed. A monetary debit
      // must not quietly adopt last-write-wins.
      for (final status in [401, 403, 409]) {
        final repo = _repoWith(_RecordingAdapter([
          () => _json({'success': false, 'error': 'no'}, status),
        ]));
        await expectLater(
          repo.contribute('h1', 'g1', amount: 5, operationId: 'op-$status'),
          throwsA(anything),
        );
      }
    });
  });
}

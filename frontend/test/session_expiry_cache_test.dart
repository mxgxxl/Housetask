import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/models/cache_owner.dart';
import 'package:homesync/data/models/household.dart';
import 'package:homesync/data/models/pending_operation.dart';
import 'package:homesync/data/models/shopping_item.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/models/timeline_session.dart';
import 'package:homesync/presentation/cubit/auth_cubit.dart';
import 'package:homesync/services/cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// TD-062 §4.1 / §4.4 — the session-expiry half of the fix, driven through the
/// real 401 interceptor instead of by calling `onSessionExpired()` by hand.
///
/// The distinction this file exists to pin is a product rule, not a technical
/// one (TD-062 decision 3): **an explicit logout discards the offline queue,
/// an expiry preserves it.** What decides is whether somebody was deciding —
/// the user chose to log out with the count in front of them (TD-061), whereas
/// a token running out is something that happened *to* them.
///
/// Preserving it is only safe because of the ownership marker: the queue
/// survives the expiry, and then whoever authenticates next decides its fate.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBox<Task> tasks;
  late FakeBox<PendingOperation> pending;
  late AuthLocalDataSource local;

  /// A syntactically valid JWT whose `exp` is in the past.
  ///
  /// The client never decodes it — that is the server's call, and here the
  /// adapter below plays the server by answering 401. It is shaped like a real
  /// token anyway so the test reads as the situation it stands for (an expired
  /// session) rather than as "some string the backend disliked".
  String expiredJwt() {
    String seg(Map<String, dynamic> m) =>
        base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
    return '${seg({'alg': 'HS256', 'typ': 'JWT'})}.'
        '${seg({
          'sub': 'user-a',
          'exp': DateTime.utc(2020, 1, 1).millisecondsSinceEpoch ~/ 1000,
        })}.sig';
  }

  PendingOperation op(String id) => PendingOperation(
        id: id,
        type: PendingOperationType.create,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        payload: const {'title': 'x'},
        timestamp: DateTime.utc(2026, 1, 1),
        idempotencyKey: 'key-$id',
      );

  setUp(() async {
    tasks = FakeBox<Task>();
    pending = FakeBox<PendingOperation>();
    CacheService().debugInjectBoxes(
      tasks: tasks,
      shopping: FakeBox<ShoppingItem>(),
      households: FakeBox<Household>(),
      pendingOperations: pending,
      cacheOwner: FakeBox<CacheOwner>(),
      // TD-064: clearAll() wipes this too, so a test exercising it has to
      // provide it — the strict accessor is deliberate (a box that silently
      // failed to open must not silently skip being cleared, TD-062).
      timelineSessions: FakeBox<TimelineSession>(),
    );

    SharedPreferences.setMockInitialValues({});
    local = AuthLocalDataSource();
    await local.saveTokens(accessToken: expiredJwt(), refreshToken: expiredJwt());

    await CacheService().claimCache('user-a');
    await CacheService().saveTask(buildTask('t1'));
    await CacheService().addPendingOperation(op('a'));
  });

  tearDown(() => CacheService().debugResetBoxes());

  /// Runs a request against a server that 401s everything, and returns the
  /// cubit that was wired to the resulting expiry — the same wiring as
  /// `app.dart:57`.
  Future<AuthCubit> triggerExpiry(String userId) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = _AlwaysUnauthorized();
    final refreshDio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = _AlwaysUnauthorized();

    final api = ApiService(local, dio: dio, refreshDio: refreshDio);
    final cubit = AuthCubit(FakeAuthRepository(userId: userId),
        cache: CacheService(), notifications: FakeNotificationService());
    api.onSessionExpired = cubit.onSessionExpired;

    await expectLater(api.get('/tasks'), throwsA(isA<Failure>()));
    return cubit;
  }

  group('an expired session', () {
    test('logs the user out without touching the offline queue', () async {
      final cubit = await triggerExpiry('user-a');

      expect(cubit.state.status, AuthStatus.unauthenticated);
      expect(await local.hasSession(), isFalse,
          reason: 'the tokens are gone — that is what makes it an expiry');
      expect(pending.entries, hasLength(1),
          reason: 'nobody decided to discard this work; the token just ran out');
      expect(CacheService().cacheOwner!.userId, 'user-a',
          reason: 'the cache still belongs to whoever queued it, and says so');
    });

    test('the same user signing back in recovers their queued work', () async {
      // TD-061 §4.3 made this a promise to the user; here it is kept even
      // across the full expiry path.
      final cubit = await triggerExpiry('user-a');

      await cubit.login('a@test.com', 'password');

      expect(pending.entries, hasLength(1));
      expect(tasks.entries, hasLength(1));
      expect(cubit.state.status, AuthStatus.authenticated);
    });

    test('a different account signing in inherits nothing', () async {
      // The case that opened TD-062: without the marker, user B's very first
      // sync replays user A's writes under B's token.
      await triggerExpiry('user-a');

      final b = AuthCubit(FakeAuthRepository(userId: 'user-b'),
          cache: CacheService(), notifications: FakeNotificationService());
      await b.login('b@test.com', 'password');

      expect(pending.entries, isEmpty);
      expect(tasks.entries, isEmpty);
      expect(CacheService().cacheOwner!.userId, 'user-b');
    });
  });

  group('the asymmetry with an explicit logout (decision 3)', () {
    test('logging out discards the queue, unlike an expiry', () async {
      final cubit = AuthCubit(FakeAuthRepository(userId: 'user-a'),
          cache: CacheService(), notifications: FakeNotificationService());

      await cubit.logout();

      // Same starting state as the expiry tests above, opposite outcome — and
      // the difference is not technical: the user was told what they were
      // discarding (TD-061) and said yes.
      expect(pending.entries, isEmpty);
      expect(CacheService().cacheOwner, isNull,
          reason: 'clearAll wipes the marker too, or it would go on claiming '
              'data that is no longer there');
    });
  });
}

/// Plays a server that rejects everything with 401 — the request AND the
/// refresh, which is what turns a retryable 401 into a dead session.
class _AlwaysUnauthorized implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode({'success': false, 'error': 'Unauthorized'}),
      401,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

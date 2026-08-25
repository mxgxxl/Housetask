import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/cache_owner.dart';
import 'package:homesync/data/models/household.dart';
import 'package:homesync/data/models/pending_operation.dart';
import 'package:homesync/data/models/shopping_item.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/models/timeline_session.dart';
import 'package:homesync/presentation/cubit/auth_cubit.dart';
import 'package:homesync/services/cache_service.dart';

import 'fakes.dart';

/// TD-062: the offline cache and the pending queue outlive a session, so a
/// different account signing in on the same device used to inherit them — and
/// `syncPendingOperations` would replay the previous user's writes under the
/// new user's token.
///
/// The fix hangs off authentication rather than off logout, because that is
/// the only moment where it is known *who* is about to use the cache.
void main() {
  late FakeBox<Task> tasks;
  late FakeBox<PendingOperation> pending;

  PendingOperation op(String id) => PendingOperation(
        id: id,
        type: PendingOperationType.create,
        entity: PendingOperationEntity.task,
        householdId: 'h1',
        payload: const {'title': 'x'},
        timestamp: DateTime.utc(2026, 1, 1),
        idempotencyKey: 'key-$id',
      );

  setUp(() {
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
  });

  tearDown(() => CacheService().debugResetBoxes());

  /// Leave the device looking like [ownerId] used it and queued work offline.
  Future<void> seedCacheOwnedBy(String ownerId) async {
    await CacheService().claimCache(ownerId);
    await CacheService().saveTask(buildTask('t1'));
    await CacheService().addPendingOperation(op('a'));
  }

  group('login', () {
    test('a different user starts from a clean cache', () async {
      await seedCacheOwnedBy('user-a');
      final cubit = AuthCubit(FakeAuthRepository(userId: 'user-b'),
          cache: CacheService(), notifications: FakeNotificationService());

      await cubit.login('b@test.com', 'password');

      expect(pending.entries, isEmpty,
          reason: "user A's queue must never replay under user B's token");
      expect(tasks.entries, isEmpty);
      expect(CacheService().cacheOwner!.userId, 'user-b');
    });

    test('the same user keeps their queued work', () async {
      // The counterpart of the case above, and the reason the check is on the
      // user id rather than on "was there a session": someone whose session
      // expired and logs back in has lost nothing.
      await seedCacheOwnedBy('user-a');
      final cubit = AuthCubit(FakeAuthRepository(userId: 'user-a'),
          cache: CacheService(), notifications: FakeNotificationService());

      await cubit.login('a@test.com', 'password');

      expect(pending.entries, hasLength(1));
      expect(tasks.entries, hasLength(1));
      expect(CacheService().cacheOwner!.userId, 'user-a');
    });

    test('an unclaimed cache is wiped — fail safe', () async {
      await CacheService().saveTask(buildTask('t1'));
      await CacheService().addPendingOperation(op('a'));
      final cubit = AuthCubit(FakeAuthRepository(userId: 'user-b'),
          cache: CacheService(), notifications: FakeNotificationService());

      await cubit.login('b@test.com', 'password');

      expect(pending.entries, isEmpty,
          reason: 'data nobody can be proven to own is not this user\'s either');
    });
  });

  group('register', () {
    test('a new account never inherits what was there', () async {
      await seedCacheOwnedBy('user-a');
      final cubit = AuthCubit(FakeAuthRepository(userId: 'user-new'),
          cache: CacheService(), notifications: FakeNotificationService());

      await cubit.register('Nuevo', 'new@test.com', 'password');

      expect(pending.entries, isEmpty);
      expect(CacheService().cacheOwner!.userId, 'user-new');
    });
  });

  group('checkAuth (app restart)', () {
    test('the same user keeps everything — the ordinary startup', () async {
      // The path taken on every launch. Wiping here would silently undo the
      // whole offline cache (TD-003), so it is the most expensive one to break.
      await seedCacheOwnedBy('user-a');
      final cubit = AuthCubit(
          FakeAuthRepository(userId: 'user-a', hasSessionResult: true),
          cache: CacheService(),
          notifications: FakeNotificationService());

      await cubit.checkAuth();

      expect(tasks.entries, hasLength(1));
      expect(pending.entries, hasLength(1));
    });

    test('a restored session for another user wipes first', () async {
      await seedCacheOwnedBy('user-a');
      final cubit = AuthCubit(
          FakeAuthRepository(userId: 'user-b', hasSessionResult: true),
          cache: CacheService(),
          notifications: FakeNotificationService());

      await cubit.checkAuth();

      expect(pending.entries, isEmpty);
      expect(CacheService().cacheOwner!.userId, 'user-b');
    });
  });

  group('ordering', () {
    test('the cache is already clean by the time authenticated is emitted',
        () async {
      // The fix is *when*, not just *what*: SplashPage loads the household off
      // the authenticated state and the connectivity listener can fire a sync
      // at any moment. Adopting late would mean adopting after the replay it
      // exists to prevent.
      await seedCacheOwnedBy('user-a');
      final cubit = AuthCubit(FakeAuthRepository(userId: 'user-b'),
          cache: CacheService(), notifications: FakeNotificationService());

      final queueAtEmit = <int>[];
      final sub = cubit.stream.listen((s) {
        if (s.status == AuthStatus.authenticated) {
          queueAtEmit.add(pending.entries.length);
        }
      });

      await cubit.login('b@test.com', 'password');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(queueAtEmit, isNotEmpty);
      expect(queueAtEmit, everyElement(0),
          reason: 'authenticated must never be observable with a stale queue');
    });
  });
}

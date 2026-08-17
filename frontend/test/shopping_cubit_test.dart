import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/shopping_item.dart';
import 'package:homesync/presentation/cubit/shopping_cubit.dart';

import 'fakes.dart';

/// Flushes pending microtasks/timers — see task_cubit_test.dart's flushAsync
/// for why this is needed instead of a single await.
Future<void> flushAsync() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

PaginatedResponse<ShoppingItem> page(
  List<ShoppingItem> items, {
  String? nextCursor,
  bool hasMore = false,
  int? total,
}) {
  return PaginatedResponse<ShoppingItem>(
    items: items,
    nextCursor: nextCursor,
    hasMore: hasMore,
    total: total,
  );
}

void main() {
  group('ShoppingCubit.load', () {
    blocTest<ShoppingCubit, ShoppingState>(
      'emits [loading, loaded] with the first page',
      build: () => ShoppingCubit(
        FakeShoppingRepository(
          pages: [
            page([buildItem('1'), buildItem('2')], nextCursor: 'c1', hasMore: true, total: 5),
          ],
        ),
      ),
      act: (cubit) => cubit.load('h1'),
      expect: () => [
        isA<ShoppingState>().having((s) => s.status, 'status', ShoppingStatusUi.loading),
        isA<ShoppingState>()
            .having((s) => s.status, 'status', ShoppingStatusUi.loaded)
            .having((s) => s.items.length, 'items', 2)
            .having((s) => s.nextCursor, 'nextCursor', 'c1')
            .having((s) => s.hasMore, 'hasMore', true)
            .having((s) => s.total, 'total', 5),
      ],
    );

    blocTest<ShoppingCubit, ShoppingState>(
      'emits error when the first page fails',
      build: () => ShoppingCubit(
        FakeShoppingRepository(failListWith: const ServerFailure('sin red')),
      ),
      act: (cubit) => cubit.load('h1'),
      expect: () => [
        isA<ShoppingState>().having((s) => s.status, 'status', ShoppingStatusUi.loading),
        isA<ShoppingState>()
            .having((s) => s.status, 'status', ShoppingStatusUi.error)
            .having((s) => s.error, 'error', 'sin red'),
      ],
    );
  });

  group('ShoppingCubit.loadMore', () {
    test('appends the next page and advances the cursor', () async {
      final repo = FakeShoppingRepository(
        pages: [
          page([buildItem('1')], nextCursor: 'c1', hasMore: true, total: 2),
          page([buildItem('2')], nextCursor: null, hasMore: false),
        ],
      );
      final cubit = ShoppingCubit(repo);

      await cubit.load('h1');
      await cubit.loadMore();

      expect(cubit.state.items.map((i) => i.id), ['1', '2']);
      expect(cubit.state.hasMore, isFalse);
      expect(cubit.state.nextCursor, isNull);
      expect(repo.receivedCursors, [null, 'c1']);
      expect(cubit.state.total, 2);
    });

    test('does nothing when the list is already exhausted', () async {
      final repo = FakeShoppingRepository(
        pages: [page([buildItem('1')], nextCursor: null, hasMore: false)],
      );
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      final before = cubit.state;
      await cubit.loadMore();

      expect(cubit.state, before);
      expect(repo.listCalls, 1);
    });

    test('runs a single fetch when called twice in a row', () async {
      final repo = FakeShoppingRepository(
        pages: [
          page([buildItem('1')], nextCursor: 'c1', hasMore: true),
          page([buildItem('2')], nextCursor: 'c2', hasMore: true),
          page([buildItem('3')], nextCursor: 'c3', hasMore: true),
        ],
      );
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      final first = cubit.loadMore();
      final second = cubit.loadMore();
      await Future.wait([first, second]);

      expect(repo.listCalls, 2);
      expect(cubit.state.items.map((i) => i.id), ['1', '2']);
    });
  });

  group('ShoppingCubit.applyRealtime', () {
    test('shopping:created inserts without duplicating', () async {
      final repo = FakeShoppingRepository(pages: [page([buildItem('1')])]);
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      const event = {
        'id': '2',
        'householdId': 'h1',
        'name': 'Pan',
        'quantity': 1,
        'isPurchased': false,
      };
      cubit.applyRealtime('shopping:created', event);
      cubit.applyRealtime('shopping:created', event);

      expect(cubit.state.items.map((i) => i.id), ['1', '2']);
    });

    test('shopping:purchased replaces the item and reorders it last', () async {
      final repo = FakeShoppingRepository(
        pages: [page([buildItem('1'), buildItem('2')])],
      );
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      cubit.applyRealtime('shopping:purchased', {
        'id': '1',
        'householdId': 'h1',
        'name': 'Producto',
        'quantity': 1,
        'isPurchased': true,
      });

      expect(cubit.state.items, hasLength(2));
      // Not-purchased items sort before purchased ones.
      expect(cubit.state.items.first.id, '2');
      expect(cubit.state.items.last.isPurchased, isTrue);
    });

    test('shopping:deleted removes the item', () async {
      final repo = FakeShoppingRepository(
        pages: [page([buildItem('1'), buildItem('2')])],
      );
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      cubit.applyRealtime('shopping:deleted', {'id': '2', 'householdId': 'h1'});

      expect(cubit.state.items.map((i) => i.id), ['1']);
    });
  });

  group('ShoppingCubit.createItem', () {
    test('upserts the created item', () async {
      final repo = FakeShoppingRepository(pages: [page([buildItem('1')])]);
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.createItem({'name': 'Arroz'});

      expect(cubit.state.items.map((i) => i.id), contains('created'));
    });

    test('exposes the failure message and creates nothing when the repo throws', () async {
      final repo = FakeShoppingRepository(
        pages: [page([buildItem('1')])],
        failCreateWith: const ConflictFailure('Operation already in progress'),
      );
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.createItem({'name': 'Fallido'});

      expect(cubit.state.error, 'Operation already in progress');
      expect(cubit.state.items.map((i) => i.id), ['1']);
    });

    test('bumps the total without a refetch', () async {
      final repo = FakeShoppingRepository(pages: [page([buildItem('1')], total: 5)]);
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');
      final callsBeforeCreate = repo.listCalls;

      await cubit.createItem({'name': 'Arroz'});

      expect(cubit.state.total, 6);
      // The header updated from create()'s own response, not a second
      // round trip: createItem never calls list().
      expect(repo.listCalls, callsBeforeCreate);
    });

    test('togglePurchased leaves the total untouched (no membership change)', () async {
      final repo = FakeShoppingRepository(pages: [page([buildItem('1')], total: 3)]);
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.togglePurchased(cubit.state.items.single);

      expect(cubit.state.total, 3);
    });
  });

  group('ShoppingCubit.deleteItem', () {
    test('decrements the total', () async {
      final repo = FakeShoppingRepository(pages: [page([buildItem('1')], total: 4)]);
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.deleteItem('1');

      expect(cubit.state.total, 3);
    });
  });

  group('ShoppingCubit offline support (TD-003)', () {
    test('load sets isOffline when the repository served the cache fallback', () async {
      final repo = FakeShoppingRepository(pages: [page([buildItem('1')])]);
      repo.lastListWasFromCache = true;
      final cubit = ShoppingCubit(repo);

      await cubit.load('h1');

      expect(cubit.state.isOffline, isTrue);
      expect(cubit.state.items.map((i) => i.id), ['1']);
    });

    test('load clears isOffline once a real page comes back', () async {
      final repo = FakeShoppingRepository(pages: [page([buildItem('1')])]);
      final cubit = ShoppingCubit(repo);

      await cubit.load('h1');

      expect(cubit.state.isOffline, isFalse);
    });

    test('createItem offline surfaces the unsynced item and an offline notice', () async {
      final repo = FakeShoppingRepository(
        pages: [page([buildItem('1')])],
        returnsUnsynced: true,
      );
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.createItem({'name': 'Sin red'});

      expect(cubit.state.items.singleWhere((i) => i.id == 'created').isSynced, isFalse);
      expect(cubit.state.offlineNotice, kShoppingOfflineNoticeMessage);
    });

    test('clearOfflineNotice consumes the notice without touching error', () async {
      final repo = FakeShoppingRepository(
        pages: [page([buildItem('1')])],
        returnsUnsynced: true,
      );
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');
      await cubit.createItem({'name': 'Sin red'});
      expect(cubit.state.offlineNotice, isNotNull);

      cubit.clearOfflineNotice();

      expect(cubit.state.offlineNotice, isNull);
    });

    test('deleteItem offline keeps the item visible, marked deleted and unsynced', () async {
      final marked = buildItem('1').copyWith(isDeleted: true, isSynced: false);
      final repo = FakeShoppingRepository(
        pages: [page([buildItem('1')])],
        offlineDeleteReturns: marked,
      );
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.deleteItem('1');

      final stored = cubit.state.items.singleWhere((i) => i.id == '1');
      expect(stored.isDeleted, isTrue);
      expect(stored.isSynced, isFalse);
      expect(cubit.state.offlineNotice, kShoppingOfflineNoticeMessage);
    });

    test('deleteItem online removes the item outright', () async {
      final repo = FakeShoppingRepository(pages: [page([buildItem('1')])]);
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.deleteItem('1');

      expect(cubit.state.items, isEmpty);
    });

    test('syncPending reloads only when operations were actually processed', () async {
      final repo = FakeShoppingRepository(pages: [page([buildItem('1')])]);
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');
      final callsAfterLoad = repo.listCalls;

      repo.syncPendingOperationsResult = 0;
      await cubit.syncPending();
      expect(repo.listCalls, callsAfterLoad);

      repo.syncPendingOperationsResult = 2;
      await cubit.syncPending();
      expect(repo.listCalls, callsAfterLoad + 1);
    });

    test('reconnection (false→true) auto-triggers a sync', () async {
      final fakeConnectivity = FakeConnectivityService();
      final repo = FakeShoppingRepository(pages: [page([buildItem('1')])]);
      final cubit = ShoppingCubit(repo, connectivity: fakeConnectivity);
      await cubit.load('h1');
      repo.syncPendingOperationsResult = 1;

      fakeConnectivity.controller.add(false);
      await flushAsync();
      fakeConnectivity.controller.add(true);
      await flushAsync();

      expect(repo.syncCalls, 1);
    });

    test('staying online never triggers a sync (no false→true edge)', () async {
      final fakeConnectivity = FakeConnectivityService();
      final repo = FakeShoppingRepository(pages: [page([buildItem('1')])]);
      final cubit = ShoppingCubit(repo, connectivity: fakeConnectivity);
      await cubit.load('h1');

      fakeConnectivity.controller.add(true);
      await flushAsync();

      expect(repo.syncCalls, 0);
    });
  });

  group('ShoppingCubit.reset (TD-058)', () {
    test('drops every item back to the initial state', () async {
      final cubit = ShoppingCubit(FakeShoppingRepository(pages: [page([buildItem('1')])]));
      await cubit.load('h1');
      expect(cubit.state.items, isNotEmpty);
      expect(cubit.householdId, 'h1');

      cubit.reset();

      expect(cubit.state, const ShoppingState());
      expect(cubit.householdId, isNull);
    });
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/shopping_item.dart';
import 'package:homesync/presentation/cubit/shopping_cubit.dart';

import 'fakes.dart';

/// Optimistic mutations in ShoppingCubit (TD-007). Mirrors
/// optimistic_task_cubit_test.dart — the two overlays are deliberate
/// duplicates and their tests should stay recognisably parallel.
void main() {
  FakeShoppingRepository repoWith(ShoppingItem seed) =>
      FakeShoppingRepository(pages: [
        PaginatedResponse<ShoppingItem>(
          items: [seed],
          nextCursor: null,
          hasMore: false,
          total: 1,
        ),
      ]);

  ShoppingItem? findIn(ShoppingCubit cubit, String id) {
    for (final i in cubit.state.items) {
      if (i.id == id) return i;
    }
    return null;
  }

  group('togglePurchased', () {
    test('marks it purchased before the server answers', () async {
      final gate = Completer<void>();
      final repo = repoWith(buildItem('i1'))..purchaseGate = gate.future;
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      final inFlight = cubit.togglePurchased(findIn(cubit, 'i1')!);

      expect(findIn(cubit, 'i1')!.isPurchased, isTrue);
      expect(cubit.state.pendingIds, contains('i1'));

      gate.complete();
      await inFlight;
    });

    test('reconciles with the server item once confirmed', () async {
      final repo = repoWith(buildItem('i1'));
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.togglePurchased(findIn(cubit, 'i1')!);

      expect(findIn(cubit, 'i1')!.isPurchased, isTrue);
      expect(findIn(cubit, 'i1')!.isSynced, isTrue);
      expect(cubit.state.pendingIds, isEmpty);
    });

    test('rolls back when the server rejects', () async {
      final repo = repoWith(buildItem('i1'))
        ..failPurchaseWith = const ServerFailure('No autorizado', statusCode: 403);
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.togglePurchased(findIn(cubit, 'i1')!);

      expect(findIn(cubit, 'i1')!.isPurchased, isFalse,
          reason: 'a rejected purchase must not stay applied');
      expect(cubit.state.error, 'No autorizado');
      expect(cubit.state.pendingIds, isEmpty);
    });

    test('does NOT roll back when the item changed meanwhile', () async {
      final gate = Completer<void>();
      final repo = repoWith(buildItem('i1', name: 'Leche'))
        ..purchaseGate = gate.future
        ..failPurchaseWith = const ServerFailure('No autorizado', statusCode: 403);
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      final inFlight = cubit.togglePurchased(findIn(cubit, 'i1')!);

      cubit.applyRealtime('shopping:updated', {
        'id': 'i1',
        'householdId': 'h1',
        'name': 'Leche entera',
        'quantity': 1,
        'unit': 'uds',
        'category': 'other',
        'isPurchased': false,
        'isRecurring': false,
      });

      gate.complete();
      await inFlight;

      expect(findIn(cubit, 'i1')!.name, 'Leche entera',
          reason: 'rolling back would discard the rename');
      expect(cubit.state.error, 'No autorizado');
    });

    test('a network failure does NOT roll back: it fell back to offline',
        () async {
      final repo = repoWith(buildItem('i1'))
        ..purchaseReturns =
            buildItem('i1', purchased: true).copyWith(isSynced: false);
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.togglePurchased(findIn(cubit, 'i1')!);

      expect(findIn(cubit, 'i1')!.isPurchased, isTrue);
      expect(cubit.state.offlineNotice, kShoppingOfflineNoticeMessage);
      expect(cubit.state.error, isNull, reason: 'queued is not failed');
    });

    test('two toggles in a row leave the item in the last state', () async {
      final repo = repoWith(buildItem('i1'));
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.togglePurchased(findIn(cubit, 'i1')!);
      await cubit.togglePurchased(findIn(cubit, 'i1')!);

      expect(findIn(cubit, 'i1')!.isPurchased, isFalse);
      expect(cubit.state.pendingIds, isEmpty);
    });
  });

  group('deleteItem', () {
    test('removes the row immediately and keeps it gone once confirmed',
        () async {
      final cubit = ShoppingCubit(repoWith(buildItem('i1')));
      await cubit.load('h1');

      await cubit.deleteItem('i1');

      expect(findIn(cubit, 'i1'), isNull);
      expect(cubit.state.pendingIds, isEmpty);
    });

    test('reinserts the row when the server rejects, naming the item',
        () async {
      final repo = repoWith(buildItem('i1', name: 'Leche'))
        ..failDeleteWith = const ServerFailure('No autorizado', statusCode: 403);
      final cubit = ShoppingCubit(repo);
      await cubit.load('h1');

      await cubit.deleteItem('i1');

      expect(findIn(cubit, 'i1'), isNotNull);
      expect(cubit.state.error, contains('Leche'));
    });
  });
}

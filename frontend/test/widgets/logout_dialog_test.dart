import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/presentation/widgets/logout_dialog.dart';

/// TD-061: logging out wipes the offline queue, and until now it did so
/// without saying anything. These pin the wording and the shape of the
/// warning, because "we told the user" is the whole feature — if the sentence
/// is wrong or absent, nothing else about it matters.
void main() {
  Future<bool?> pumpDialog(WidgetTester tester, int pendingCount) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              result = await showLogoutDialog(context, pendingCount: pendingCount);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  group('nothing queued', () {
    testWidgets('shows the plain confirmation, with no warning', (tester) async {
      await pumpDialog(tester, 0);

      expect(find.text('¿Seguro que quieres cerrar sesión?'), findsOneWidget);
      expect(find.textContaining('sin sincronizar'), findsNothing);
      // The title says "Cerrar sesión" too, so match the button specifically
      // rather than the bare string.
      expect(find.widgetWithText(FilledButton, 'Cerrar sesión'), findsOneWidget);
      expect(find.text('Cerrar sesión y descartar'), findsNothing);
    });
  });

  group('queued writes', () {
    testWidgets('names the exact number of changes', (tester) async {
      await pumpDialog(tester, 3);

      expect(find.textContaining('3 cambios sin sincronizar'), findsOneWidget);
      expect(find.textContaining('se perderán'), findsOneWidget);
    });

    testWidgets('uses the singular for exactly one change', (tester) async {
      await pumpDialog(tester, 1);

      expect(find.textContaining('1 cambio sin sincronizar'), findsOneWidget);
      expect(find.textContaining('1 cambios'), findsNothing);
    });

    testWidgets('the destructive button names the discard', (tester) async {
      await pumpDialog(tester, 2);

      // A neutral "Cerrar sesión" here would hide what the tap actually does.
      expect(find.widgetWithText(FilledButton, 'Cerrar sesión y descartar'),
          findsOneWidget);
    });
  });

  group('what the buttons return', () {
    testWidgets('cancel resolves false', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await showLogoutDialog(context, pendingCount: 4);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(result, isFalse,
          reason: 'the caller must be able to tell cancel from confirm — it is '
              'what stops the queue from being wiped');
    });

    testWidgets('confirm resolves true', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await showLogoutDialog(context, pendingCount: 4);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cerrar sesión y descartar'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });
  });

  group('draining the queue first (TD-061 §2)', () {
    Future<void> pumpWithSync(
      WidgetTester tester,
      int pendingCount,
      Future<int> Function() trySync,
    ) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () =>
                  showLogoutDialog(context, pendingCount: pendingCount, trySync: trySync),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
    }

    testWidgets('shows the transitional state and blocks confirming',
        (tester) async {
      final gate = Completer<int>();
      await pumpWithSync(tester, 3, () => gate.future);

      expect(find.textContaining('Sincronizando 3 cambios pendientes'),
          findsOneWidget);
      // Confirming mid-drain would discard writes seconds away from safety.
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);

      gate.complete(0);
      await tester.pumpAndSettle();
    });

    testWidgets('a drain that empties the queue leaves no warning at all',
        (tester) async {
      await pumpWithSync(tester, 3, () async => 0);
      await tester.pumpAndSettle();

      // The best warning is the one that turns out to be unnecessary.
      expect(find.text('¿Seguro que quieres cerrar sesión?'), findsOneWidget);
      expect(find.textContaining('sin sincronizar'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Cerrar sesión'), findsOneWidget);
    });

    testWidgets('a partial drain warns with what is LEFT, not the initial count',
        (tester) async {
      await pumpWithSync(tester, 5, () async => 2);
      await tester.pumpAndSettle();

      expect(find.textContaining('2 cambios sin sincronizar'), findsOneWidget);
      expect(find.textContaining('5 cambios'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Cerrar sesión y descartar'),
          findsOneWidget);
    });

    testWidgets('no drain is attempted when the queue is already empty',
        (tester) async {
      var called = false;
      await pumpWithSync(tester, 0, () async {
        called = true;
        return 0;
      });
      await tester.pumpAndSettle();

      expect(called, isFalse);
      expect(find.text('¿Seguro que quieres cerrar sesión?'), findsOneWidget);
    });

    testWidgets('dismissing the dialog does not blow up when the drain lands',
        (tester) async {
      // TD-061 §4.2: cancelling must not abort the sync — it is already in
      // flight and useful. All the dialog does is stop caring about the result,
      // which must not throw a setState-after-dispose.
      final gate = Completer<int>();
      await pumpWithSync(tester, 3, () => gate.future);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      gate.complete(1);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}

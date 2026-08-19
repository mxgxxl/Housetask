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
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/presentation/widgets/governance_dialogs.dart';

/// The confirmations PDR-022 D5 requires (TD-067).
///
/// Two properties are worth pinning, and neither is about layout.
///
/// FIRST, the exact wording of what the user is agreeing to. Every one of
/// these actions is irreversible from the app, and each dialog is the only
/// place the consequence is stated: that the outgoing owner keeps admin, that
/// the most senior member inherits the administration, that savings come back,
/// that personal XP does not go with the household. A dialog that dropped one
/// of those sentences would still look right.
///
/// SECOND, that "cancel" and "dismiss" both mean no. These are the paths a
/// user takes when they did NOT mean to do this, so a dialog returning
/// anything but false there is the worst possible bug in the file.

/// What the dialog answered, readable once it has closed.
///
/// A holder rather than a returned Future, because the dialog's Future does
/// not complete until the user acts — so a helper that awaited it would hang,
/// and one that did not would always report null.
class _Answer {
  bool? value;
  bool get isAnswered => value != null;
}

/// Pump a page, open the dialog, and hand back the holder its result lands in.
Future<_Answer> _show(
  WidgetTester tester,
  Future<bool> Function(BuildContext context) open,
) async {
  final answer = _Answer();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async => answer.value = await open(context),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  return answer;
}

void main() {
  group('demote (PDR-022 D1)', () {
    testWidgets('names the person and what they lose', (tester) async {
      await _show(tester, (c) => showDemoteDialog(c, 'Ana'));

      expect(find.text('Quitar permisos de administrador'), findsOneWidget);
      expect(
        find.textContaining('¿Quieres convertir a Ana en miembro?'),
        findsOneWidget,
      );
      expect(find.text('Convertir en miembro'), findsOneWidget);
    });

    testWidgets('returns false when cancelled', (tester) async {
      final answer = await _show(tester, (c) => showDemoteDialog(c, 'Ana'));
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(answer.value, isFalse);
    });

    testWidgets('returns true when confirmed', (tester) async {
      final answer = await _show(tester, (c) => showDemoteDialog(c, 'Ana'));
      await tester.tap(find.text('Convertir en miembro'));
      await tester.pumpAndSettle();

      expect(answer.value, isTrue);
    });
  });

  group('transfer ownership (PDR-022 D2)', () {
    testWidgets('says the outgoing owner stays an ADMIN', (tester) async {
      // The one place PDR-022 diverges from TD-067-DESIGN §5's copy, and the
      // divergence matters: D1 split "owner" from "admin", and only the owner
      // half moves. Telling the user they become a plain member would be
      // describing behaviour the server does not have.
      await _show(tester, (c) => showTransferOwnershipDialog(c, 'Ana'));

      expect(find.text('Transferir propiedad'), findsOneWidget);
      expect(find.textContaining('Tú seguirás siendo administrador'),
          findsOneWidget);
      expect(find.textContaining('ya no podrás cambiar roles'), findsOneWidget);
    });

    testWidgets('returns false when dismissed by tapping the barrier',
        (tester) async {
      final answer =
          await _show(tester, (c) => showTransferOwnershipDialog(c, 'Ana'));
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(answer.value, isFalse);
    });
  });

  group('leave (PDR-022 D3)', () {
    testWidgets('always promises personal progress survives', (tester) async {
      // PDR-017: XP and coins are portable. A member who thinks leaving costs
      // them their level will not leave, which makes the household a trap.
      await _show(
        tester,
        (c) => showLeaveHouseholdDialog(c, householdName: 'Casa'),
      );

      expect(find.text('Salir del hogar'), findsOneWidget);
      expect(
        find.textContaining('Tu XP y tus monedas personales se conservan'),
        findsOneWidget,
      );
    });

    // The two conditional warnings get a test each per direction rather than
    // one test toggling the flag: a second `_show` in the same test would try
    // to tap through the first dialog, which is still open.

    testWidgets('warns about the successor when the leaver is the last admin',
        (tester) async {
      await _show(
        tester,
        (c) => showLeaveHouseholdDialog(
          c,
          householdName: 'Casa',
          willPromoteSuccessor: true,
        ),
      );

      expect(
        find.textContaining(
            'Eres el único administrador, así que el miembro más antiguo'),
        findsOneWidget,
      );
    });

    testWidgets('says nothing about a successor when another admin remains',
        (tester) async {
      // Showing the warning when it does not apply is as wrong as hiding it
      // when it does: it would tell a member their exit reshuffles the
      // household when it changes nothing.
      await _show(
        tester,
        (c) => showLeaveHouseholdDialog(c, householdName: 'Casa'),
      );

      expect(find.textContaining('el miembro más antiguo'), findsNothing);
    });

    testWidgets('warns about the savings refund when the member has one',
        (tester) async {
      await _show(
        tester,
        (c) => showLeaveHouseholdDialog(
          c,
          householdName: 'Casa',
          hasSavingsContribution: true,
        ),
      );

      expect(
        find.textContaining('Se te devolverán las monedas'),
        findsOneWidget,
      );
    });

    testWidgets('says nothing about savings when there is nothing to refund',
        (tester) async {
      await _show(
        tester,
        (c) => showLeaveHouseholdDialog(c, householdName: 'Casa'),
      );

      expect(find.textContaining('hucha conjunta'), findsNothing);
    });
  });

  group('destroy household (PDR-022 D4)', () {
    Future<_Answer> open(WidgetTester tester, {String name = 'Casa Bonita'}) =>
        _show(
          tester,
          (c) => showDestroyHouseholdDialog(
            c,
            householdName: name,
            gracePeriod: const Duration(hours: 24),
          ),
        );

    testWidgets('states the grace period and what survives', (tester) async {
      await open(tester);

      expect(find.text('Eliminar hogar'), findsWidgets);
      expect(
        find.textContaining('Tendrás 24 horas para cancelarlo'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Tu XP y tus monedas personales se conservan'),
        findsOneWidget,
      );
    });

    testWidgets('the confirm button is inert until the name is typed',
        (tester) async {
      // Inert rather than absent: the user has to see what they are working
      // towards. This is the one action with no undo once the period expires,
      // so it asks for something nobody does by accident.
      await open(tester);

      final confirm = find.widgetWithText(FilledButton, 'Eliminar hogar');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'Casa Equivocada');
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'Casa Bonita');
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    });

    testWidgets('accepts a differently-cased or padded name', (tester) async {
      // The point is proving they know WHICH household they are deleting, not
      // testing their typing.
      await open(tester);

      await tester.enterText(find.byType(TextField), '  casa bonita  ');
      await tester.pump();

      final confirm = find.widgetWithText(FilledButton, 'Eliminar hogar');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    });

    testWidgets('returns true only after confirming with a matching name',
        (tester) async {
      final answer = await open(tester);
      await tester.enterText(find.byType(TextField), 'Casa Bonita');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Eliminar hogar'));
      await tester.pumpAndSettle();

      expect(answer.value, isTrue);
    });

    testWidgets('returns false when cancelled', (tester) async {
      final answer = await open(tester);
      await tester.enterText(find.byType(TextField), 'Casa Bonita');
      await tester.pump();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(answer.value, isFalse);
    });
  });
}

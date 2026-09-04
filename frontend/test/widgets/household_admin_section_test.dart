import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/household.dart';
import 'package:homesync/data/models/household_governance.dart';
import 'package:homesync/presentation/widgets/common.dart';
import 'package:homesync/presentation/widgets/household_admin_section.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../fakes.dart';

/// «Administrar hogar» (TD-067, PDR-022) — the permission matrix as UI.
///
/// What these pin is the difference between the three things PDR-022 made
/// distinct — creator, admin, member — because getting it wrong is invisible
/// rather than loud. A section that showed role controls to every admin would
/// look completely normal until an ordinary admin tapped one and the server
/// answered 403; a creator's demote button that was merely HIDDEN instead of
/// disabled would read as "this feature does not exist" rather than "this is
/// not allowed to you".
///
/// The widget is presentational on purpose, so all of this is assertable
/// without standing up five cubits (same reason `logout_dialog.dart` was
/// extracted from ProfilePage).

const _creatorId = 'creator';
const _adminId = 'admin';
const _memberId = 'member';

Household _household({
  String createdBy = _creatorId,
  Map<String, String> roles = const {
    _creatorId: 'admin',
    _adminId: 'admin',
    _memberId: 'member',
  },
}) =>
    buildHousehold(createdBy: createdBy, memberRoles: roles);

/// Records what the section asked for, so a test can assert the callback
/// rather than a side effect the widget does not have.
class _Calls {
  final List<String> log = [];
}

Future<_Calls> _pump(
  WidgetTester tester, {
  required String currentUserId,
  Household? household,
  DestructionStatus? destruction,
}) async {
  final calls = _Calls();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: HouseholdAdminSection(
            household: household ?? _household(),
            currentUserId: currentUserId,
            destruction: destruction,
            onPromote: (m) => calls.log.add('promote:${m.user.id}'),
            onDemote: (m) => calls.log.add('demote:${m.user.id}'),
            onTransferOwnership: (m) => calls.log.add('transfer:${m.user.id}'),
            onLeave: () => calls.log.add('leave'),
            onScheduleDestruction: () => calls.log.add('schedule'),
            onCancelDestruction: () => calls.log.add('cancel'),
            onConfirmDestruction: () => calls.log.add('confirm'),
          ),
        ),
      ),
    ),
  );
  return calls;
}

/// The promote/demote button on one member's row, found by its tooltip —
/// which is also the string that explains WHY it is disabled.
Finder _roleButton(String tooltip) =>
    find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton));

void main() {
  // The banner formats its deadline with the 'es' locale, as every other date
  // in the app does (main.dart initializes it at startup).
  setUpAll(() => initializeDateFormatting('es', null));

  group('who sees the admin section (PDR-022 D1)', () {
    testWidgets('the creator sees role controls', (tester) async {
      await _pump(tester, currentUserId: _creatorId);

      expect(find.text('Administrar hogar'), findsOneWidget);
      expect(find.byTooltip('Quitar administrador'), findsOneWidget);
      expect(find.byTooltip('Hacer administrador'), findsOneWidget);
    });

    testWidgets('an admin who is NOT the creator sees none of it', (tester) async {
      // The case a symmetric-admins model would have got wrong, and the one
      // that would look perfectly normal until the server refused.
      await _pump(tester, currentUserId: _adminId);

      expect(find.text('Administrar hogar'), findsNothing);
      expect(find.byTooltip('Quitar administrador'), findsNothing);
      expect(find.byTooltip('Hacer administrador'), findsNothing);
      expect(find.byTooltip('Transferir propiedad'), findsNothing);
      expect(find.text('Eliminar hogar'), findsNothing);
    });

    testWidgets('a plain member sees none of it', (tester) async {
      await _pump(tester, currentUserId: _memberId);

      expect(find.text('Administrar hogar'), findsNothing);
      expect(find.text('Eliminar hogar'), findsNothing);
    });

    testWidgets('everyone sees «Salir del hogar», creator included', (tester) async {
      // D3: leaving is a right, not an administrative action. D2 is what makes
      // it safe for the creator — their exit hands the household on.
      for (final id in [_creatorId, _adminId, _memberId]) {
        await _pump(tester, currentUserId: id);
        expect(find.text('Salir del hogar'), findsOneWidget,
            reason: 'missing for $id');
      }
    });
  });

  group('the creator is not a valid target (PDR-022 D1)', () {
    testWidgets('their demote button is disabled, not hidden', (tester) async {
      // Disabled says "not allowed"; absent says "does not exist". The second
      // is a lie the user would have to discover by trying.
      await _pump(tester, currentUserId: _creatorId);

      final button = _roleButton('El creador del hogar no puede ser degradado');
      expect(button, findsOneWidget);
      expect(tester.widget<IconButton>(button).onPressed, isNull);
    });

    testWidgets('ownership cannot be transferred to the creator', (tester) async {
      // Exactly one transfer button, and it is on the OTHER admin's row.
      // Transferring to yourself is a 400 server-side; offering the button
      // would be offering something that never works.
      final calls = await _pump(tester, currentUserId: _creatorId);

      expect(find.byTooltip('Transferir propiedad'), findsOneWidget);
      await tester.tap(find.byTooltip('Transferir propiedad'));
      expect(calls.log, ['transfer:$_adminId']);
    });

    testWidgets('ownership cannot be transferred to a plain member', (tester) async {
      // D2: the receiver must already be an admin, so the button is not on a
      // member's row at all. Offering it and letting the server answer 400
      // would be offering something that never works.
      await _pump(
        tester,
        currentUserId: _creatorId,
        household: _household(
          roles: const {_creatorId: 'admin', _memberId: 'member'},
        ),
      );

      expect(find.byTooltip('Transferir propiedad'), findsNothing);
    });
  });

  group('role controls call back with the right member', () {
    testWidgets('promotes a member and demotes an admin', (tester) async {
      final calls = await _pump(tester, currentUserId: _creatorId);

      await tester.tap(find.byTooltip('Hacer administrador'));
      await tester.tap(find.byTooltip('Quitar administrador'));

      // Promote and demote produce the same shape of success, so asserting
      // WHICH call was made is the only way to catch them being swapped.
      expect(calls.log, ['promote:$_memberId', 'demote:$_adminId']);
    });

    testWidgets('leaving calls back', (tester) async {
      final calls = await _pump(tester, currentUserId: _memberId);

      await tester.tap(find.text('Salir del hogar'));

      expect(calls.log, ['leave']);
    });
  });

  group('badges', () {
    testWidgets('shows «Creador» and «Admin» separately', (tester) async {
      // A creator is always an admin too. Collapsing the two badges would hide
      // that an ordinary admin exists alongside them — which is exactly the
      // distinction D1 introduced.
      await _pump(tester, currentUserId: _creatorId);

      expect(find.widgetWithText(Pill, 'Creador'), findsOneWidget);
      expect(find.widgetWithText(Pill, 'Admin'), findsNWidgets(2));
    });
  });

  group('the pending-deletion banner (PDR-022 D4)', () {
    DestructionStatus pending() => DestructionStatus(
          scheduled: true,
          scheduledAt: DateTime.now().add(const Duration(hours: 20)),
          scheduledBy: _creatorId,
        );

    DestructionStatus expired() => DestructionStatus(
          scheduled: true,
          scheduledAt: DateTime.now().subtract(const Duration(minutes: 1)),
          scheduledBy: _creatorId,
        );

    testWidgets('every member sees it, not just the creator', (tester) async {
      // A household about to disappear is something everyone living in it
      // should see coming, even though only one person can schedule it.
      await _pump(tester, currentUserId: _memberId, destruction: pending());

      expect(find.text('Este hogar se va a eliminar'), findsOneWidget);
      // But the buttons are the creator's alone.
      expect(find.text('Cancelar eliminación'), findsNothing);
    });

    testWidgets('only the creator gets the cancel button', (tester) async {
      final calls =
          await _pump(tester, currentUserId: _creatorId, destruction: pending());

      expect(find.text('Cancelar eliminación'), findsOneWidget);
      await tester.tap(find.text('Cancelar eliminación'));
      expect(calls.log, ['cancel']);
    });

    testWidgets('«Eliminar ahora» appears only once the grace period expires',
        (tester) async {
      // The deadline is the whole safeguard: offering the final confirmation
      // early would hand the user a button the server answers 400 to.
      await _pump(tester, currentUserId: _creatorId, destruction: pending());
      expect(find.text('Eliminar ahora'), findsNothing);

      final calls =
          await _pump(tester, currentUserId: _creatorId, destruction: expired());
      expect(find.text('Eliminar ahora'), findsOneWidget);
      expect(find.text('El plazo para cancelar ha terminado.'), findsOneWidget);

      await tester.tap(find.text('Eliminar ahora'));
      expect(calls.log, ['confirm']);
    });

    testWidgets('hides «Eliminar hogar» while a deletion is already pending',
        (tester) async {
      // Scheduling twice is harmless server-side (unique index), but offering
      // it beside a banner that says it is already scheduled reads as broken.
      await _pump(tester, currentUserId: _creatorId, destruction: pending());

      expect(find.text('Eliminar hogar'), findsNothing);
    });

    testWidgets('shows «Eliminar hogar» to the creator when nothing is pending',
        (tester) async {
      final calls = await _pump(
        tester,
        currentUserId: _creatorId,
        destruction: const DestructionStatus(),
      );

      expect(find.text('Eliminar hogar'), findsOneWidget);
      expect(find.text('Podrás cancelarlo durante 24 horas'), findsOneWidget);
      await tester.tap(find.text('Eliminar hogar'));
      expect(calls.log, ['schedule']);
    });
  });

  group('willPromoteSuccessor — the warning the leave dialog needs (D3)', () {
    // Computed here rather than fetched, because the roster already says it.
    HouseholdAdminSection section(String userId, Map<String, String> roles) =>
        HouseholdAdminSection(
          household: buildHousehold(createdBy: _creatorId, memberRoles: roles),
          currentUserId: userId,
          onPromote: (_) {},
          onDemote: (_) {},
          onTransferOwnership: (_) {},
          onLeave: () {},
          onScheduleDestruction: () {},
          onCancelDestruction: () {},
          onConfirmDestruction: () {},
        );

    test('true for the only admin', () {
      expect(
        section(_creatorId, const {_creatorId: 'admin', _memberId: 'member'})
            .willPromoteSuccessor,
        isTrue,
      );
    });

    test('false when another admin remains', () {
      expect(
        section(_creatorId, const {_creatorId: 'admin', _adminId: 'admin'})
            .willPromoteSuccessor,
        isFalse,
      );
    });

    test('false for a plain member, however few admins there are', () {
      expect(
        section(_memberId, const {_creatorId: 'admin', _memberId: 'member'})
            .willPromoteSuccessor,
        isFalse,
      );
    });
  });
}

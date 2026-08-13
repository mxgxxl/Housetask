import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/member.dart';
import 'package:homesync/data/models/user.dart';
import 'package:homesync/presentation/widgets/assignee_selector.dart';

Member _member(String id, String name) =>
    Member(user: User(id: id, email: '$id@test.com', name: name), role: 'member');

Widget _host({
  required List<User> users,
  Set<String> selectedIds = const {},
  void Function(String id)? onToggle,
  VoidCallback? onClearAll,
}) {
  return MaterialApp(
    home: Scaffold(
      body: AssigneeSelector(
        users: users,
        selectedIds: selectedIds,
        onToggle: onToggle ?? (_) {},
        onClearAll: onClearAll ?? () {},
      ),
    ),
  );
}

void main() {
  group('AssigneeSelector', () {
    testWidgets('shows both member names and the "Sin asignar" option for a 2-member household',
        (tester) async {
      final members = [_member('u1', 'Ana'), _member('u2', 'Beto')];
      final users = members.map((m) => m.user).toList();

      await tester.pumpWidget(_host(users: users));

      expect(find.text('Ana'), findsOneWidget);
      expect(find.text('Beto'), findsOneWidget);
      expect(find.text('Sin asignar'), findsOneWidget);
    });

    testWidgets('falls back to email when a member has no name', (tester) async {
      final users = [const User(id: 'u1', email: 'noname@test.com', name: '')];

      await tester.pumpWidget(_host(users: users));

      expect(find.text('noname@test.com'), findsOneWidget);
    });

    testWidgets('"Sin asignar" is selected when there is no assignee', (tester) async {
      final users = [const User(id: 'u1', email: 'a@test.com', name: 'Ana')];

      await tester.pumpWidget(_host(users: users));

      final chip = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, 'Sin asignar'),
      );
      expect(chip.selected, isTrue);
    });

    testWidgets('a member chip is selected once its id is in selectedIds', (tester) async {
      final users = [const User(id: 'u1', email: 'a@test.com', name: 'Ana')];

      await tester.pumpWidget(_host(users: users, selectedIds: const {'u1'}));

      final memberChip = tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Ana'));
      final unassignedChip = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, 'Sin asignar'),
      );
      expect(memberChip.selected, isTrue);
      expect(unassignedChip.selected, isFalse);
    });

    testWidgets('tapping a member chip calls onToggle with their id', (tester) async {
      String? toggledId;
      final users = [const User(id: 'u1', email: 'a@test.com', name: 'Ana')];

      await tester.pumpWidget(_host(users: users, onToggle: (id) => toggledId = id));
      await tester.tap(find.text('Ana'));

      expect(toggledId, 'u1');
    });

    testWidgets('tapping "Sin asignar" calls onClearAll', (tester) async {
      var cleared = false;
      final users = [const User(id: 'u1', email: 'a@test.com', name: 'Ana')];

      await tester.pumpWidget(_host(users: users, onClearAll: () => cleared = true));
      await tester.tap(find.text('Sin asignar'));

      expect(cleared, isTrue);
    });

    testWidgets('shows a fallback message when the household has no members', (tester) async {
      await tester.pumpWidget(_host(users: const []));

      expect(find.text('No hay miembros en el hogar'), findsOneWidget);
      expect(find.text('Sin asignar'), findsNothing);
    });
  });
}

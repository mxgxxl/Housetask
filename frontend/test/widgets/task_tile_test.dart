import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/household.dart';
import 'package:homesync/data/models/member.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/models/user.dart';
import 'package:homesync/presentation/cubit/household_cubit.dart';
import 'package:homesync/presentation/widgets/task_tile.dart';
import 'package:homesync/presentation/widgets/user_avatar.dart';

import '../fakes.dart';

HouseholdCubit _householdCubit(List<Member> members) {
  final cubit = HouseholdCubit(FakeHouseholdRepository());
  cubit.emit(HouseholdState(
    status: HouseholdStatusUi.loaded,
    current: Household(
      id: 'h1',
      name: 'Casa de prueba',
      inviteCode: 'CASADEMO',
      createdBy: 'u0',
      members: members,
    ),
  ));
  return cubit;
}

Widget _host(Task task, {List<Member> members = const [], HouseholdCubit? householdCubit}) {
  return MaterialApp(
    home: Scaffold(
      body: BlocProvider<HouseholdCubit>.value(
        value: householdCubit ?? _householdCubit(members),
        child: TaskTile(task: task),
      ),
    ),
  );
}

void main() {
  group('TaskTile offline indicators (TD-003)', () {
    testWidgets('isSynced true shows no pending-sync cloud icon', (tester) async {
      final task = buildTask('1');
      expect(task.isSynced, isTrue); // sanity: the model's own default

      await tester.pumpWidget(_host(task));

      expect(find.byIcon(Icons.cloud_queue), findsNothing);
    });

    testWidgets('isSynced false shows the pending-sync cloud icon', (tester) async {
      final task = buildTask('1').copyWith(isSynced: false);

      await tester.pumpWidget(_host(task));

      expect(find.byIcon(Icons.cloud_queue), findsOneWidget);
    });

    testWidgets('isDeleted true renders the row struck through and dimmed', (tester) async {
      final task = buildTask('1', title: 'Pendiente de borrar')
          .copyWith(isDeleted: true, isSynced: false);

      await tester.pumpWidget(_host(task));

      final titleWidget = tester.widget<Text>(find.text('Pendiente de borrar'));
      expect(titleWidget.style?.decoration, TextDecoration.lineThrough);

      final opacityWidget = tester.widget<Opacity>(find.byType(Opacity));
      expect(opacityWidget.opacity, lessThan(1.0));
    });

    testWidgets('a normal pending task is not dimmed', (tester) async {
      final task = buildTask('1');

      await tester.pumpWidget(_host(task));

      final opacityWidget = tester.widget<Opacity>(find.byType(Opacity));
      expect(opacityWidget.opacity, 1.0);
    });
  });

  group('TaskTile "who completed it" (cooperative visibility, PDR-002)', () {
    testWidgets('completed by a current member shows their name and initial', (tester) async {
      final task = buildTask(
        '1',
        completed: true,
        completedBy: {'id': 'u1', 'name': 'Ana Gómez', 'email': 'ana@test.com'},
      );
      final members = [
        const Member(
          user: User(id: 'u1', email: 'ana@test.com', name: 'Ana Gómez'),
          role: 'member',
        ),
      ];

      await tester.pumpWidget(_host(task, members: members));

      expect(find.text('Completada por Ana Gómez'), findsOneWidget);
      final avatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
      expect(avatar.user.initials, 'AG');
    });

    testWidgets('completed by a userId that resolves to no current member shows "Ex-miembro"',
        (tester) async {
      final task = buildTask(
        '1',
        completed: true,
        completedBy: {'id': 'gone', 'name': 'Carlos Viejo', 'email': 'carlos@test.com'},
      );

      // No members in the current household — the completer already left.
      await tester.pumpWidget(_host(task, members: const []));

      expect(find.text('Completada por Ex-miembro'), findsOneWidget);
      expect(find.text('Completada por Carlos Viejo'), findsNothing);
    });

    testWidgets('a pending task shows no completed-by row at all', (tester) async {
      final task = buildTask('1');

      await tester.pumpWidget(_host(task));

      expect(find.textContaining('Completada por'), findsNothing);
    });

    testWidgets(
        'while HouseholdCubit has not loaded yet, a completed task shows the neutral '
        'placeholder instead of prematurely claiming "Ex-miembro"', (tester) async {
      final task = buildTask(
        '1',
        completed: true,
        completedBy: {'id': 'u1', 'name': 'Ana Gómez', 'email': 'ana@test.com'},
      );
      // Default HouseholdCubit state is `initial` — membership is unknown,
      // not "resolved to zero members".
      final loadingCubit = HouseholdCubit(FakeHouseholdRepository());

      await tester.pumpWidget(_host(task, householdCubit: loadingCubit));

      expect(find.text('Completada por Ex-miembro'), findsNothing);
      expect(find.text('Completada por Ana Gómez'), findsNothing);
      expect(find.text('Completada'), findsOneWidget);
    });

    testWidgets(
        'once HouseholdCubit finishes loading with the completer absent, it resolves to '
        '"Ex-miembro" instead of staying on the placeholder forever', (tester) async {
      final task = buildTask(
        '1',
        completed: true,
        completedBy: {'id': 'gone', 'name': 'Carlos Viejo', 'email': 'carlos@test.com'},
      );
      final cubit = HouseholdCubit(FakeHouseholdRepository());

      await tester.pumpWidget(_host(task, householdCubit: cubit));
      expect(find.text('Completada'), findsOneWidget);

      cubit.emit(const HouseholdState(
        status: HouseholdStatusUi.loaded,
        current: Household(
          id: 'h1',
          name: 'Casa de prueba',
          inviteCode: 'CASADEMO',
          createdBy: 'u0',
          members: [],
        ),
      ));
      await tester.pump();

      expect(find.text('Completada por Ex-miembro'), findsOneWidget);
      expect(find.text('Completada'), findsNothing);
    });
  });
}

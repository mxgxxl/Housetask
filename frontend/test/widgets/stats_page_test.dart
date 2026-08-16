import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/household.dart';
import 'package:homesync/data/models/household_stats.dart';
import 'package:homesync/presentation/cubit/household_cubit.dart';
import 'package:homesync/presentation/cubit/stats_cubit.dart';
import 'package:homesync/presentation/pages/stats_page.dart';

import '../fakes.dart';

HouseholdCubit _loadedHouseholdCubit(FakeHouseholdRepository repo) {
  final cubit = HouseholdCubit(repo);
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
  return cubit;
}

Widget _host(FakeHouseholdRepository repo) {
  return MultiBlocProvider(
    providers: [
      BlocProvider<HouseholdCubit>.value(value: _loadedHouseholdCubit(repo)),
      BlocProvider<StatsCubit>(create: (_) => StatsCubit(repo)),
    ],
    child: const MaterialApp(home: StatsPage()),
  );
}

const _stats30d = HouseholdStats(
  totalTasks: 4,
  completedTasks: 3,
  completionRate: 75.0,
  memberStats: [
    MemberStat(userId: 'u1', userName: 'Ana', created: 3, completed: 1),
    MemberStat(userId: 'u2', userName: 'Beto', created: 1, completed: 2),
  ],
  topCompleter: TopCompleter(userId: 'u2', userName: 'Beto', completed: 2),
  period: StatsPeriod.last30days,
);

const _statsAllTime = HouseholdStats(
  totalTasks: 10,
  completedTasks: 5,
  completionRate: 50.0,
  memberStats: [
    MemberStat(userId: 'u1', userName: 'Ana', created: 6, completed: 3),
    MemberStat(userId: 'u2', userName: 'Beto', created: 4, completed: 2),
  ],
  topCompleter: TopCompleter(userId: 'u1', userName: 'Ana', completed: 3),
  period: StatsPeriod.allTime,
);

const _statsNoCompletions = HouseholdStats(
  totalTasks: 2,
  completedTasks: 0,
  completionRate: 0,
  memberStats: [
    MemberStat(userId: 'u1', userName: 'Ana', created: 2, completed: 0),
  ],
  topCompleter: null,
  period: StatsPeriod.last30days,
);

void main() {
  group('StatsPage (PDR-007)', () {
    testWidgets('shows completion rate, top completer and member bars', (tester) async {
      final repo = FakeHouseholdRepository(statsByPeriod: {StatsPeriod.last30days: _stats30d});

      await tester.pumpWidget(_host(repo));
      await tester.pump();

      expect(find.text('75.0%'), findsOneWidget);
      expect(find.text('3 de 4 tareas'), findsOneWidget);
      expect(find.text('Beto'), findsWidgets);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Ana'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
      expect(repo.statsCalls, [StatsPeriod.last30days]);
    });

    testWidgets('shows an empty message when nobody has completed anything', (tester) async {
      final repo = FakeHouseholdRepository(
        statsByPeriod: {StatsPeriod.last30days: _statsNoCompletions},
      );

      await tester.pumpWidget(_host(repo));
      await tester.pump();

      expect(find.text('Nadie ha completado tareas todavía'), findsOneWidget);
    });

    testWidgets('toggling the period refetches stats', (tester) async {
      final repo = FakeHouseholdRepository(statsByPeriod: {
        StatsPeriod.last30days: _stats30d,
        StatsPeriod.allTime: _statsAllTime,
      });

      await tester.pumpWidget(_host(repo));
      await tester.pump();
      expect(find.text('75.0%'), findsOneWidget);

      await tester.tap(find.text('Todo'));
      await tester.pump();

      expect(find.text('50.0%'), findsOneWidget);
      expect(find.text('5 de 10 tareas'), findsOneWidget);
      expect(repo.statsCalls, [StatsPeriod.last30days, StatsPeriod.allTime]);
    });
  });
}

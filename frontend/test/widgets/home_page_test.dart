import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/models/household.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/repositories/auth_repository.dart';
import 'package:homesync/presentation/cubit/auth_cubit.dart';
import 'package:homesync/presentation/cubit/economy_p1_cubit.dart';
import 'package:homesync/presentation/cubit/household_cubit.dart';
import 'package:homesync/presentation/cubit/pet_cubit.dart';
import 'package:homesync/presentation/cubit/shopping_cubit.dart';
import 'package:homesync/presentation/cubit/socket_cubit.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';
import 'package:homesync/presentation/cubit/timeline_cubit.dart';
import 'package:homesync/presentation/pages/main_scaffold.dart';
import 'package:homesync/services/socket_service.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes.dart';

PaginatedResponse<Task> page(List<Task> items, {int? total}) {
  return PaginatedResponse<Task>(
      items: items, nextCursor: null, hasMore: false, total: total);
}

/// Reported production bug: the home dashboard stayed empty until the user
/// pulled to refresh or visited Tareas. The hypothesis was that MainScaffold's
/// startup only warmed [TaskCubit.loadTimeline] (PDR-003's "Todas" tab, read
/// by tasks_page.dart) and never [TaskCubit.load] — the call that actually
/// populates `buckets[TaskFilter.all]`, which is what HomePage reads via
/// [TaskState.allTasks] (see home_page.dart's `taskState.allTasks`).
///
/// Reading main_scaffold.dart's `_loadForHousehold` shows both calls have
/// always been made together, and git history confirms `load()` was never
/// missing from it — so this file exists to pin that behavior down with a
/// regression test rather than to accompany a source fix: these tests pass
/// against the code as found, refuting the hypothesis for HomePage
/// specifically (a different, now-fixed staleness bug affected the Todas
/// tab's timeline — see TaskCubit._timelineAfterUpsert's doc comment).
///
/// Same 6-cubit composition as main_scaffold_test.dart's `_host`.
Widget _host({
  required HouseholdCubit householdCubit,
  required TaskCubit taskCubit,
  // TD-064: TasksPage's "Todas" tab reads TimelineCubit. Defaulted here rather
  // than threaded through every call site — these tests assert on the bottom
  // nav and Home, not on the timeline.
  TimelineCubit? timelineCubit,
  required ShoppingCubit shoppingCubit,
  required PetCubit petCubit,
  required AuthCubit authCubit,
  required SocketCubit socketCubit,
}) {
  return MaterialApp(
    home: MultiBlocProvider(
      providers: [
        BlocProvider<AuthCubit>.value(value: authCubit),
        BlocProvider<HouseholdCubit>.value(value: householdCubit),
        BlocProvider<TaskCubit>.value(value: taskCubit),
        BlocProvider<TimelineCubit>.value(
          value: timelineCubit ?? TimelineCubit(FakeTaskRepository()),
        ),
        BlocProvider<ShoppingCubit>.value(value: shoppingCubit),
        BlocProvider<PetCubit>.value(value: petCubit),
        BlocProvider<SocketCubit>.value(value: socketCubit),
        // TD-066 F2: the IndexedStack builds every page up front, PetPage
        // included, and PetPage now hosts the "Mi progreso" section. Its
        // state is `initial` here, so the section renders nothing.
        BlocProvider<EconomyP1Cubit>.value(
          value: EconomyP1Cubit(
            FakeEconomyP1Repository(),
            connectivity: FakeConnectivityService(),
          ),
        ),
      ],
      child: const MainScaffold(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HouseholdCubit householdCubit;
  late ShoppingCubit shoppingCubit;
  late PetCubit petCubit;
  late AuthCubit authCubit;
  late AuthLocalDataSource local;

  setUpAll(() async {
    // CalendarPage's month header (built off-screen by the IndexedStack)
    // needs 'es' locale data initialized.
    await initializeDateFormatting('es', null);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});

    householdCubit = HouseholdCubit(FakeHouseholdRepository());
    householdCubit.emit(const HouseholdState(
      status: HouseholdStatusUi.loaded,
      current: Household(
        id: 'h1',
        name: 'Casa de prueba',
        inviteCode: 'CASADEMO',
        createdBy: 'u0',
        members: [],
      ),
    ));
    shoppingCubit = ShoppingCubit(FakeShoppingRepository());
    petCubit = PetCubit(FakePetRepository());

    local = AuthLocalDataSource();
    authCubit = AuthCubit(AuthRepository(ApiService(local), local));
  });

  /// IndexedStack builds every page up front, including CalendarPage's month
  /// grid — a generous surface avoids an unrelated RenderFlex overflow there
  /// from failing this test (same precaution as main_scaffold_test.dart).
  void useGenerousSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
      'home shows an already-existing task on app start, with no manual refresh',
      (tester) async {
    useGenerousSurface(tester);

    final today = DateTime.now();
    final repo = FakeTaskRepository(
      pages: [
        page([buildTask('t1', title: 'Sacar la basura', dueDate: today)], total: 1),
      ],
    );
    final taskCubit = TaskCubit(repo, FakeNotificationService());
    final socketCubit = SocketCubit(
      SocketService(),
      local,
      taskCubit,
      shoppingCubit,
      householdCubit,
      petCubit,
    );

    await tester.pumpWidget(_host(
      householdCubit: householdCubit,
      taskCubit: taskCubit,
      shoppingCubit: shoppingCubit,
      petCubit: petCubit,
      authCubit: authCubit,
      socketCubit: socketCubit,
    ));
    // Let MainScaffold's post-frame callback fire _loadForHousehold and its
    // async TaskCubit.load() resolve — no RefreshIndicator, no explicit
    // refresh() call.
    await tester.pump();
    await tester.pump();

    expect(find.text('Sacar la basura'), findsOneWidget);
  });

  testWidgets('home reflects a newly created task immediately (upsert)',
      (tester) async {
    useGenerousSurface(tester);

    final repo = FakeTaskRepository(pages: [page(const [], total: 0)]);
    final taskCubit = TaskCubit(repo, FakeNotificationService());
    final socketCubit = SocketCubit(
      SocketService(),
      local,
      taskCubit,
      shoppingCubit,
      householdCubit,
      petCubit,
    );

    await tester.pumpWidget(_host(
      householdCubit: householdCubit,
      taskCubit: taskCubit,
      shoppingCubit: shoppingCubit,
      petCubit: petCubit,
      authCubit: authCubit,
      socketCubit: socketCubit,
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Regar las plantas'), findsNothing);

    await taskCubit.createTask({
      'title': 'Regar las plantas',
      'dueDate': DateTime.now().toIso8601String(),
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('Regar las plantas'), findsOneWidget);
  });
}

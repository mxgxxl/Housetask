import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/models/household.dart';
import 'package:homesync/data/repositories/auth_repository.dart';
import 'package:homesync/presentation/cubit/auth_cubit.dart';
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

/// Same 6-cubit composition MainScaffold is wired with in app.dart, standing
/// in the exact frame right after HouseholdCubit resolves to `loaded` but
/// before Task/Shopping/Pet finish their own first load — i.e. the real first
/// frame the IndexedStack ever renders, since MainScaffold builds every page
/// (including the off-screen ones) up front.
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
      ],
      child: const MainScaffold(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HouseholdCubit householdCubit;
  late FakeTaskRepository taskRepo;
  late TaskCubit taskCubit;
  late ShoppingCubit shoppingCubit;
  late PetCubit petCubit;
  late AuthCubit authCubit;
  late SocketCubit socketCubit;

  // CalendarPage's month header formats the current month via
  // DateFormat(..., 'es'), which needs locale data initialized — normally
  // done once in main.dart, bypassed entirely by a plain pumpWidget(). It
  // builds unconditionally here because MainScaffold's IndexedStack builds
  // every page up front, not just the visible tab (see
  // calendar_page_test.dart for the same requirement in isolation).
  setUpAll(() async {
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
    taskRepo = FakeTaskRepository();
    taskCubit = TaskCubit(taskRepo, FakeNotificationService());
    shoppingCubit = ShoppingCubit(FakeShoppingRepository());
    petCubit = PetCubit(FakePetRepository());

    final local = AuthLocalDataSource();
    authCubit = AuthCubit(AuthRepository(ApiService(local), local));
    // Real SocketService/AuthLocalDataSource are safe here: MainScaffold only
    // calls joinHousehold(), and the singleton's underlying socket stays null
    // until connect() is called (never triggered in this test), so it's a
    // harmless no-op — see SocketService.joinHousehold's null-safe emit.
    socketCubit = SocketCubit(
      SocketService(),
      local,
      taskCubit,
      shoppingCubit,
      householdCubit,
      petCubit,
    );
  });

  testWidgets('Recurrentes tab appears in the bottom nav (TD-035)', (tester) async {
    // MainScaffold's IndexedStack builds every page up front, including
    // CalendarPage's month grid — a generous surface avoids an unrelated
    // RenderFlex overflow there from failing this test (see
    // calendar_page_test.dart's pumpCalendarPage for the same precaution).
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(
      householdCubit: householdCubit,
      taskCubit: taskCubit,
      shoppingCubit: shoppingCubit,
      petCubit: petCubit,
      authCubit: authCubit,
      socketCubit: socketCubit,
    ));
    await tester.pump();

    final destination = find.widgetWithText(NavigationDestination, 'Recurrentes');
    expect(destination, findsOneWidget);
    expect(
      find.descendant(of: destination, matching: find.byIcon(Icons.repeat)),
      findsOneWidget,
    );
  });

  testWidgets('tapping Recurrentes switches the visible page to the recurring list',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(
      householdCubit: householdCubit,
      taskCubit: taskCubit,
      shoppingCubit: shoppingCubit,
      petCubit: petCubit,
      authCubit: authCubit,
      socketCubit: socketCubit,
    ));
    await tester.pump();

    // Every page lives in the IndexedStack up front (not lazily built), so
    // switching tabs is a pure index change — asserting on it rather than on
    // page content avoids depending on RecurringTasksPage's own data-loading
    // state, which is covered separately in recurring_tasks_page_test.dart.
    final before = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(before.index, 0);

    // Not pumpAndSettle: PetCubit's default/never-loaded state renders an
    // indeterminate CircularProgressIndicator in the (offstage) Mascota tab,
    // which animates forever and would make pumpAndSettle time out. A tab
    // switch is a synchronous setState, not an animation — a couple of plain
    // pumps is enough to observe it (same reasoning as offline_banner_test
    // .dart's isSyncing-spinner assertions).
    await tester.tap(find.widgetWithText(NavigationDestination, 'Recurrentes'));
    await tester.pump();
    await tester.pump();

    final after = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(after.index, 2);
  });

  testWidgets(
      'tapping Recurrentes refreshes its list — IndexedStack keeps the page '
      'mounted across tab switches, so without an explicit refresh it would '
      'never see a task created/completed/deleted while on another tab',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(
      householdCubit: householdCubit,
      taskCubit: taskCubit,
      shoppingCubit: shoppingCubit,
      petCubit: petCubit,
      authCubit: authCubit,
      socketCubit: socketCubit,
    ));
    // Let MainScaffold's post-frame callback fire its initial _loadForHousehold
    // (which already calls loadRecurringTasks once) before measuring the delta.
    await tester.pump();
    await tester.pump();
    final callsAfterInitialLoad = taskRepo.listCalls;

    await tester.tap(find.widgetWithText(NavigationDestination, 'Recurrentes'));
    await tester.pump();
    await tester.pump();

    expect(taskRepo.listCalls, greaterThan(callsAfterInitialLoad));
  });
}

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/config/constants.dart';
import 'package:homesync/config/routes.dart';
import 'package:homesync/data/datasources/local/auth_local_datasource.dart';
import 'package:homesync/data/datasources/remote/api_service.dart';
import 'package:homesync/data/models/household.dart';
import 'package:homesync/data/models/household_stats.dart';
import 'package:homesync/data/models/paginated_response.dart';
import 'package:homesync/data/models/shopping_item.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/data/repositories/auth_repository.dart';
import 'package:homesync/presentation/cubit/auth_cubit.dart';
import 'package:homesync/presentation/cubit/household_cubit.dart';
import 'package:homesync/presentation/cubit/pet_cubit.dart';
import 'package:homesync/presentation/cubit/shopping_cubit.dart';
import 'package:homesync/presentation/cubit/socket_cubit.dart';
import 'package:homesync/presentation/cubit/stats_cubit.dart';
import 'package:homesync/presentation/cubit/task_cubit.dart';
import 'package:homesync/presentation/widgets/session_listeners.dart';
import 'package:homesync/services/socket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes.dart';

/// Always answers with a bare success envelope — same stub as
/// auth_cubit_test.dart, reused here so [AuthCubit.logout] can complete for
/// real (backend call, cache wipe) without a live server.
class _StubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode({'success': true, 'data': <String, dynamic>{}}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// [FakeHouseholdRepository] throws UnimplementedError for getById/stats it
/// wasn't configured for — this fills in both, so HouseholdCubit.loadHousehold
/// and StatsCubit.load can both succeed against the same fake in one test.
class _HouseholdRepoWithData extends FakeHouseholdRepository {
  final Household household;

  _HouseholdRepoWithData(
    this.household, {
    super.statsByPeriod,
  });

  @override
  Future<Household> getById(String id) async => household;
}

/// Records whether [SocketCubit.disconnect] was actually invoked — the real
/// [SocketService] singleton has no observable "connected" flag reachable
/// from a test that never calls connect() (see main_scaffold_test.dart's
/// SocketCubit setup for the same reasoning), so this is the only way to
/// assert TD-055's teardown step ran instead of only checking its
/// side-effect (state emitting false, which it already starts as).
class _SpySocketCubit extends SocketCubit {
  int disconnectCalls = 0;

  _SpySocketCubit(
    super.socket,
    super.local,
    super.taskCubit,
    super.shoppingCubit,
    super.householdCubit,
    super.petCubit,
  );

  @override
  void disconnect() {
    disconnectCalls++;
    super.disconnect();
  }
}

Household _buildHousehold() => const Household(
      id: 'h1',
      name: 'Casa de prueba',
      inviteCode: 'ABCD1234',
      createdBy: 'user-a',
    );

PaginatedResponse<Task> page(
  List<Task> items, {
  String? nextCursor,
  bool hasMore = false,
  int? total,
}) {
  return PaginatedResponse<Task>(
    items: items,
    nextCursor: nextCursor,
    hasMore: hasMore,
    total: total,
  );
}

PaginatedResponse<ShoppingItem> shoppingPage(
  List<ShoppingItem> items, {
  String? nextCursor,
  bool hasMore = false,
  int? total,
}) {
  return PaginatedResponse<ShoppingItem>(
    items: items,
    nextCursor: nextCursor,
    hasMore: hasMore,
    total: total,
  );
}

/// Same shape SessionListeners wraps in app.dart, but with fakes standing in
/// for the composition root's network/storage dependencies (same rationale
/// as main_scaffold_test.dart's `_host`) — a `/main` and a `/login` stand-in
/// route are enough to observe which side of TD-055's navigation the app
/// landed on, without pulling in the real page widgets and their own data
/// dependencies.
Widget _host({
  required AuthCubit authCubit,
  required HouseholdCubit householdCubit,
  required TaskCubit taskCubit,
  required ShoppingCubit shoppingCubit,
  required PetCubit petCubit,
  required StatsCubit statsCubit,
  required SocketCubit socketCubit,
}) {
  return MultiBlocProvider(
    providers: [
      BlocProvider<AuthCubit>.value(value: authCubit),
      BlocProvider<HouseholdCubit>.value(value: householdCubit),
      BlocProvider<TaskCubit>.value(value: taskCubit),
      BlocProvider<ShoppingCubit>.value(value: shoppingCubit),
      BlocProvider<PetCubit>.value(value: petCubit),
      BlocProvider<StatsCubit>.value(value: statsCubit),
      BlocProvider<SocketCubit>.value(value: socketCubit),
    ],
    child: SessionListeners(
      notifications: FakeNotificationService(),
      child: MaterialApp(
        navigatorKey: Routes.navigatorKey,
        initialRoute: '/main',
        onGenerateRoute: (settings) {
          final label = settings.name == Routes.login ? 'LOGIN_SCREEN' : 'MAIN_SCREEN';
          return MaterialPageRoute(builder: (_) => Text(label));
        },
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      StorageKeys.accessToken: 'token',
      StorageKeys.refreshToken: 'refresh-token',
    });
  });

  testWidgets(
    'session expiry (onSessionExpired) routes to login from whatever page is on screen (TD-055)',
    (tester) async {
      final local = AuthLocalDataSource();
      final authCubit = AuthCubit(AuthRepository(ApiService(local), local));
      final householdCubit = HouseholdCubit(FakeHouseholdRepository());
      final taskCubit = TaskCubit(FakeTaskRepository(), FakeNotificationService());
      final shoppingCubit = ShoppingCubit(FakeShoppingRepository());
      final petCubit = PetCubit(FakePetRepository());
      final statsCubit = StatsCubit(FakeHouseholdRepository());
      final socketCubit = SocketCubit(
        SocketService(),
        local,
        taskCubit,
        shoppingCubit,
        householdCubit,
        petCubit,
      );

      await tester.pumpWidget(_host(
        authCubit: authCubit,
        householdCubit: householdCubit,
        taskCubit: taskCubit,
        shoppingCubit: shoppingCubit,
        petCubit: petCubit,
        statsCubit: statsCubit,
        socketCubit: socketCubit,
      ));

      // Starts on the app's main content, same as a user deep in the app —
      // not on SplashPage, which is the only page that used to react to
      // `unauthenticated` before this fix.
      expect(find.text('MAIN_SCREEN'), findsOneWidget);
      expect(find.text('LOGIN_SCREEN'), findsNothing);

      // Simulates ApiService._onError giving up on a 401 it could not
      // refresh and invoking the callback wired in app.dart.
      authCubit.onSessionExpired();
      await tester.pumpAndSettle();

      expect(find.text('LOGIN_SCREEN'), findsOneWidget);
      expect(find.text('MAIN_SCREEN'), findsNothing);
    },
  );

  testWidgets(
    'logout disconnects the socket and resets every domain cubit to its initial state (TD-058)',
    (tester) async {
      final household = _buildHousehold();
      const stats = HouseholdStats(
        totalTasks: 4,
        completedTasks: 2,
        completionRate: 0.5,
        memberStats: [],
        topCompleter: null,
        period: StatsPeriod.last30days,
      );

      final local = AuthLocalDataSource();
      final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
        ..httpClientAdapter = _StubAdapter();
      final authCubit = AuthCubit(
        AuthRepository(ApiService(local, dio: dio), local),
        cache: FakeCacheService(),
      );
      final householdRepo =
          _HouseholdRepoWithData(household, statsByPeriod: {StatsPeriod.last30days: stats});
      final householdCubit = HouseholdCubit(householdRepo);
      final taskCubit = TaskCubit(
        FakeTaskRepository(pages: [
          page([buildTask('t1', title: 'Tarea de usuario A')]),
        ]),
        FakeNotificationService(),
        connectivity: FakeConnectivityService(),
      );
      final shoppingCubit = ShoppingCubit(
        FakeShoppingRepository(pages: [
          shoppingPage([buildItem('i1', name: 'Compra de usuario A')]),
        ]),
        connectivity: FakeConnectivityService(),
      );
      final petCubit = PetCubit(FakePetRepository(pet: buildPet('pet1', name: 'Michi de A')));
      final statsCubit = StatsCubit(householdRepo);
      final socketCubit = _SpySocketCubit(
        SocketService(),
        local,
        taskCubit,
        shoppingCubit,
        householdCubit,
        petCubit,
      );

      // Populate every cubit the same way MainScaffold._loadForHousehold
      // does — via their real public API, not emit() directly — so this
      // reproduces an account genuinely "logged in with data loaded", not a
      // hand-crafted state.
      await householdCubit.loadHousehold('h1');
      await taskCubit.load('h1');
      await shoppingCubit.load('h1');
      await petCubit.load('h1', 'user-a');
      await statsCubit.load('h1');

      expect(householdCubit.state.current, isNotNull);
      expect(taskCubit.state.allTasks, isNotEmpty);
      expect(shoppingCubit.state.items, isNotEmpty);
      expect(petCubit.state.pet, isNotNull);
      expect(statsCubit.state.stats, isNotNull);

      await tester.pumpWidget(_host(
        authCubit: authCubit,
        householdCubit: householdCubit,
        taskCubit: taskCubit,
        shoppingCubit: shoppingCubit,
        petCubit: petCubit,
        statsCubit: statsCubit,
        socketCubit: socketCubit,
      ));

      // logout() makes a real Dio call (stubbed at the HTTP layer, but still
      // real async I/O): inside a plain testWidgets body that runs under the
      // fake-async test clock, awaiting it directly hangs forever, since
      // nothing is pumping frames to advance real IO/timers. tester.runAsync
      // steps outside the fake-async zone for the duration of the call — the
      // same pattern auth_cubit_test.dart avoids needing by using a plain
      // test() instead, which isn't an option here since this test also
      // needs a pumped widget tree to observe the listener's navigation.
      await tester.runAsync(() => authCubit.logout());
      await tester.pumpAndSettle();

      expect(socketCubit.disconnectCalls, 1);
      expect(householdCubit.state, const HouseholdState());
      expect(taskCubit.state, const TaskState());
      expect(shoppingCubit.state, const ShoppingState());
      expect(petCubit.state, const PetState());
      expect(statsCubit.state, const StatsState());
      expect(find.text('LOGIN_SCREEN'), findsOneWidget);
    },
  );

  testWidgets(
    'a new login never inherits the outgoing account\'s data (TD-055 + TD-058 together)',
    (tester) async {
      // User A: logged in, household/tasks/shopping/pet all loaded.
      final household = _buildHousehold();
      final local = AuthLocalDataSource();
      final dio = Dio(BaseOptions(baseUrl: 'http://test.local/api'))
        ..httpClientAdapter = _StubAdapter();
      final authCubit = AuthCubit(
        AuthRepository(ApiService(local, dio: dio), local),
        cache: FakeCacheService(),
      );
      final householdCubit =
          HouseholdCubit(_HouseholdRepoWithData(household, statsByPeriod: const {}));
      final taskCubit = TaskCubit(
        FakeTaskRepository(pages: [
          page([buildTask('a-task', title: 'Tarea de A')]),
        ]),
        FakeNotificationService(),
        connectivity: FakeConnectivityService(),
      );
      final shoppingCubit = ShoppingCubit(
        FakeShoppingRepository(pages: [
          shoppingPage([buildItem('a-item', name: 'Compra de A')]),
        ]),
        connectivity: FakeConnectivityService(),
      );
      final petCubit = PetCubit(FakePetRepository(pet: buildPet('a-pet', name: 'Mascota de A')));
      final statsCubit = StatsCubit(FakeHouseholdRepository());
      final socketCubit = SocketCubit(
        SocketService(),
        local,
        taskCubit,
        shoppingCubit,
        householdCubit,
        petCubit,
      );

      await householdCubit.loadHousehold('h1');
      await taskCubit.load('h1');
      await shoppingCubit.load('h1');
      await petCubit.load('h1', 'user-a');

      await tester.pumpWidget(_host(
        authCubit: authCubit,
        householdCubit: householdCubit,
        taskCubit: taskCubit,
        shoppingCubit: shoppingCubit,
        petCubit: petCubit,
        statsCubit: statsCubit,
        socketCubit: socketCubit,
      ));

      // User A logs out — this is the moment a real device would show the
      // login screen and, moments later, a different person (user B) signs
      // in on the same phone. tester.runAsync is needed here for the same
      // reason as the previous test — see its comment.
      await tester.runAsync(() => authCubit.logout());
      await tester.pumpAndSettle();

      // Simulates user B's fresh session landing on the same, still-alive
      // cubit instances (exactly what happens on a real device: the app
      // process isn't restarted between accounts). Before TD-058, these
      // cubits would still be holding user A's task/item/pet at this point,
      // which is what a mounted MainScaffold would render for the instant
      // before user B's own `load()` calls resolve.
      expect(taskCubit.state.allTasks, isEmpty,
          reason: "user A's task must not still be present for user B's first frame");
      expect(shoppingCubit.state.items, isEmpty,
          reason: "user A's shopping item must not still be present for user B's first frame");
      expect(petCubit.state.pet, isNull,
          reason: "user A's pet must not still be present for user B's first frame");
      expect(householdCubit.state.current, isNull,
          reason: "user A's household must not still be present for user B's first frame");
    },
  );
}

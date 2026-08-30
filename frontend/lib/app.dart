import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'config/routes.dart';
import 'config/theme.dart';
import 'data/datasources/local/auth_local_datasource.dart';
import 'data/datasources/remote/api_service.dart';
import 'data/repositories/auth_repository.dart';
import 'data/repositories/economy_p1_repository.dart';
import 'data/repositories/household_repository.dart';
import 'data/repositories/pet_repository.dart';
import 'data/repositories/shopping_repository.dart';
import 'data/repositories/task_repository.dart';
import 'presentation/cubit/auth_cubit.dart';
import 'presentation/cubit/economy_p1_cubit.dart';
import 'presentation/cubit/household_cubit.dart';
import 'presentation/cubit/pet_cubit.dart';
import 'presentation/cubit/shopping_cubit.dart';
import 'presentation/cubit/socket_cubit.dart';
import 'presentation/cubit/stats_cubit.dart';
import 'presentation/cubit/task_cubit.dart';
import 'presentation/cubit/timeline_cubit.dart';
import 'presentation/widgets/session_listeners.dart';
import 'services/cache_service.dart';
import 'services/notification_service.dart';
import 'services/socket_service.dart';

/// Root widget: wires up dependencies (data sources, repositories, cubits)
/// and hosts the MaterialApp.
class HomeSyncApp extends StatelessWidget {
  const HomeSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    // ---- Dependency wiring (composition root) ----
    final local = AuthLocalDataSource();
    final api = ApiService(local);

    final authRepo = AuthRepository(api, local);
    final householdRepo = HouseholdRepository(api, local);
    final taskRepo = TaskRepository(api);
    final shoppingRepo = ShoppingRepository(api);
    final petRepo = PetRepository(api);
    final economyP1Repo = EconomyP1Repository(api, CacheService());

    final notifications = NotificationService()..attachApi(api);
    final socketService = SocketService();

    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider.value(value: authRepo),
        RepositoryProvider.value(value: householdRepo),
        RepositoryProvider.value(value: taskRepo),
        RepositoryProvider.value(value: shoppingRepo),
        RepositoryProvider.value(value: petRepo),
        RepositoryProvider.value(value: economyP1Repo),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) {
            final cubit = AuthCubit(authRepo, notifications: notifications);
            // Force logout when the API layer can't refresh the session.
            api.onSessionExpired = cubit.onSessionExpired;
            return cubit;
          }),
          BlocProvider(create: (_) => HouseholdCubit(householdRepo)),
          BlocProvider(create: (_) => TimelineCubit(taskRepo)),
          // TD-064: TaskCubit echoes every mutation into the timeline through
          // the TimelineSink interface, so an optimistic write or a rollback
          // updates both surfaces without a refetch. Created after
          // TimelineCubit for that reason.
          BlocProvider(
            create: (ctx) => TaskCubit(
              taskRepo,
              notifications,
              timeline: ctx.read<TimelineCubit>(),
            ),
          ),
          BlocProvider(create: (_) => ShoppingCubit(shoppingRepo)),
          BlocProvider(create: (_) => PetCubit(petRepo)),
          BlocProvider(create: (_) => StatsCubit(householdRepo)),
          // TD-066 F2. Created before SocketCubit so the personal-room
          // `economy:*` events have somewhere to land from the first frame.
          BlocProvider(create: (_) => EconomyP1Cubit(economyP1Repo)),
          BlocProvider(
            create: (ctx) => SocketCubit(
              socketService,
              local,
              ctx.read<TaskCubit>(),
              ctx.read<ShoppingCubit>(),
              ctx.read<HouseholdCubit>(),
              ctx.read<PetCubit>(),
              timeline: ctx.read<TimelineCubit>(),
              economyP1: ctx.read<EconomyP1Cubit>(),
            ),
          ),
        ],
        // TD-055/TD-058: SessionListeners reacts to every AuthCubit
        // transition app-wide (push registration on login, socket teardown +
        // cubit resets + routing to login on logout/session-expiry) — see
        // its own doc comment for why this lives above MaterialApp rather
        // than inside AuthCubit or any one page.
        child: SessionListeners(
          notifications: notifications,
          child: MaterialApp(
            title: 'HomeSync',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light,
            navigatorKey: Routes.navigatorKey,
            initialRoute: Routes.splash,
            onGenerateRoute: Routes.onGenerateRoute,
          ),
        ),
      ),
    );
  }
}

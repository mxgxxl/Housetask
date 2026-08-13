import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
import '../../services/cache_service.dart';
import '../cubit/household_cubit.dart';
import '../cubit/shopping_cubit.dart';
import '../cubit/socket_cubit.dart';
import '../cubit/task_cubit.dart';
import 'calendar_page.dart';
import 'home_page.dart';
import 'household_setup_page.dart';
import 'profile_page.dart';
import 'shopping_page.dart';
import 'tasks_page.dart';

/// Main app shell with a BottomNavigationBar. Loads task + shopping data for
/// the active household and keeps them in sync when the household changes.
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _index = 0;
  String? _loadedHouseholdId;

  final _pages = const [
    HomePage(),
    TasksPage(),
    CalendarPage(),
    ShoppingPage(),
    ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    // The household may already be loaded (splash/login loaded it) before this
    // shell mounts, in which case the BlocConsumer listener below never fires.
    // Trigger the initial data load once after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final id = context.read<HouseholdCubit>().state.current?.id;
      if (id != null) _loadForHousehold(id);
    });
  }

  void _loadForHousehold(String householdId) {
    if (_loadedHouseholdId == householdId) return;
    _loadedHouseholdId = householdId;
    context.read<TaskCubit>().load(householdId);
    // "Todas" (PDR-003) is warmed up front like every other tab, rather than
    // lazily from TasksPage.initState, so it is ready the moment the user
    // switches to the Tareas tab instead of showing its own loading spinner.
    context.read<TaskCubit>().loadTimeline(householdId);
    context.read<ShoppingCubit>().load(householdId);
    context.read<SocketCubit>().joinHousehold(householdId);
    // Generate any missed recurring occurrences for this household.
    context.read<TaskCubit>().catchUpRecurringTasks(householdId);
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<HouseholdCubit, HouseholdState>(
      listenWhen: (p, c) => p.current?.id != c.current?.id,
      listener: (context, state) {
        final id = state.current?.id;
        if (id != null) _loadForHousehold(id);
      },
      builder: (context, state) {
        if (state.status == HouseholdStatusUi.empty) {
          return const HouseholdSetupPage();
        }
        if (state.current == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return Scaffold(
          body: Column(
            children: [
              const OfflineBanner(),
              Expanded(child: IndexedStack(index: _index, children: _pages)),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            backgroundColor: AppColors.surface,
            indicatorColor: AppColors.primary.withValues(alpha: 0.12),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: 'Inicio',
              ),
              NavigationDestination(
                icon: Icon(Icons.checklist_outlined),
                selectedIcon: Icon(Icons.checklist),
                label: 'Tareas',
              ),
              NavigationDestination(
                icon: Icon(Icons.calendar_month_outlined),
                selectedIcon: Icon(Icons.calendar_month),
                label: 'Calendario',
              ),
              NavigationDestination(
                icon: Icon(Icons.shopping_cart_outlined),
                selectedIcon: Icon(Icons.shopping_cart),
                label: 'Compras',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Perfil',
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Yellow bar shown above the tab content whenever the task or shopping list
/// most recently fell back to the offline cache (TD-003). Combines both
/// cubits — either one being offline means the household's data may be
/// stale — and shows the queued-writes count and a spinner while
/// [TaskCubit.syncPending]/[ShoppingCubit.syncPending] is replaying them.
///
/// Public (not `_OfflineBanner`) so widget tests can pump it directly with
/// just the two cubits it needs, instead of standing up all of
/// [MainScaffold]'s other page dependencies to reach it.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final taskState = context.watch<TaskCubit>().state;
    final shoppingState = context.watch<ShoppingCubit>().state;

    final isOffline = taskState.isOffline || shoppingState.isOffline;
    if (!isOffline) return const SizedBox.shrink();

    final isSyncing = taskState.isSyncing || shoppingState.isSyncing;

    return Container(
      width: double.infinity,
      color: AppColors.priorityMedium,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, size: 16, color: Colors.black87),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Sin conexión — cambios guardados localmente',
              style: TextStyle(
                color: Colors.black87,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // A dedicated stream, not a synchronous read in this build method,
          // so the badge updates the instant the queue drains or grows
          // instead of only when TaskCubit/ShoppingCubit happens to re-emit.
          StreamBuilder<int>(
            stream: CacheService().pendingOperationsCount,
            builder: (context, snapshot) {
              final pendingCount = snapshot.data ?? 0;
              if (pendingCount <= 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$pendingCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            },
          ),
          if (isSyncing)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.black87),
            ),
        ],
      ),
    );
  }
}

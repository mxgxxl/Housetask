import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
import '../../services/cache_service.dart';
import '../cubit/auth_cubit.dart';
import '../cubit/economy_p1_cubit.dart';
import '../cubit/household_cubit.dart';
import '../cubit/household_economy_cubit.dart';
import '../cubit/pet_cubit.dart';
import '../cubit/shopping_cubit.dart';
import '../cubit/socket_cubit.dart';
import '../cubit/task_cubit.dart';
import '../cubit/timeline_cubit.dart';
import 'calendar_page.dart';
import 'home_page.dart';
import 'household_setup_page.dart';
import 'pet_page.dart';
import 'profile_page.dart';
import 'recurring_tasks_page.dart';
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

  /// Index of [RecurringTasksPage] in [_pages]/the NavigationBar destinations
  /// below — used by [_onDestinationSelected] to refresh it on entry.
  static const _recurringTabIndex = 2;

  /// Index of [PetPage] in [_pages]/the NavigationBar destinations below —
  /// refreshed on entry for the same reason, see [_onDestinationSelected].
  static const _petTabIndex = 5;

  final _pages = const [
    HomePage(),
    TasksPage(),
    RecurringTasksPage(),
    CalendarPage(),
    ShoppingPage(),
    PetPage(),
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
    context.read<TimelineCubit>().load(householdId);
    context.read<ShoppingCubit>().load(householdId);
    context.read<SocketCubit>().joinHousehold(householdId);
    // Generate any missed recurring occurrences for this household.
    context.read<TaskCubit>().catchUpRecurringTasks(householdId);
    // Recurrentes tab (TD-035) — warmed up front like every other tab.
    context.read<TaskCubit>().loadRecurringTasks(householdId);

    // PetCubit needs the current user id to tell "I proposed this
    // adoption" apart from "someone else did" (PDR-001 A3) — it's read
    // here rather than made a PetCubit dependency, keeping it independent
    // like TaskCubit/ShoppingCubit.
    final userId = context.read<AuthCubit>().state.user?.id;
    if (userId != null) {
      context.read<PetCubit>().load(householdId, userId);
    }
    // TD-066 F2. Warmed up front like every other tab; while P1 is off the
    // read still answers a zeroed structure and the section stays hidden.
    context.read<EconomyP1Cubit>().load(householdId);
    // TD-066 F3, the household half. It reads the SAME snapshot — the
    // repository coalesces two concurrent loads of one household into one
    // round trip, so this line costs no extra request. `currentUserId` is
    // what lets the savings breakdown say «Tú» for one of its rows; null
    // before the profile resolves costs that one label, not the read.
    // `isAdmin` decides only whether «Cancelar meta» is offered; the backend
    // refuses a cancel from anyone but the creator or an admin regardless.
    // Read once here because roles cannot change while the app runs —
    // promotion/demotion is TD-067 and unimplemented.
    final members = context.read<HouseholdCubit>().state.current?.members;
    final isAdmin = members?.any((m) => m.user.id == userId && m.isAdmin) ?? false;
    context.read<HouseholdEconomyCubit>().load(
          householdId,
          currentUserId: userId,
          isAdmin: isAdmin,
        );
  }

  /// Every page below lives in an [IndexedStack], so switching tabs never
  /// remounts them — a page has no lifecycle hook that fires "the user just
  /// navigated to me". [RecurringTasksPage] is TD-035's derived, walk-the-
  /// whole-list-and-group-by-series view: unlike the Tareas tab's timeline
  /// (whose local upsert now keeps it live, see TaskCubit._upsert), a single
  /// mutated task can change which occurrence represents its series, which
  /// isn't something a targeted patch can cheaply reproduce — so this
  /// re-derives it by refetching each time the user lands on the tab instead.
  void _onDestinationSelected(int index) {
    setState(() => _index = index);
    final householdId = _loadedHouseholdId;
    if (householdId == null) return;

    if (index == _recurringTabIndex) {
      context.read<TaskCubit>().loadRecurringTasks(householdId);
      return;
    }

    if (index == _petTabIndex) {
      // Same IndexedStack staleness the Recurrentes tab works around, for a
      // different reason: the coin balance and the pet's hunger/mood are both
      // computed server-side and only ever fetched by PetCubit.load/refresh.
      // Completing a task credits coins through grantCoins, which emits no
      // socket event, and SocketCubit routes task:* only to Task/Timeline —
      // so without this the numbers stay at whatever they were when the app
      // started, however many tasks have been completed since.
      context.read<PetCubit>().refresh();
      // Same staleness, same tab: "Mi progreso" lives here too, and while
      // socket events keep it live for a P1 household, this covers a tab
      // opened after a spell in the background with the socket down.
      // EconomyP1Cubit coalesces concurrent refreshes, so a fast tab
      // switch is one request, not several.
      context.read<EconomyP1Cubit>().refresh();
      // Same staleness, and one thing socket events cannot cover at all: no
      // household event carries a HOUSEMATE's own level or XP — those only
      // ever travel on that member's personal room — so the roster's figures
      // move on this read and nowhere else.
      context.read<HouseholdEconomyCubit>().refresh();
    }
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
            onDestinationSelected: _onDestinationSelected,
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
                icon: Icon(Icons.repeat),
                selectedIcon: Icon(Icons.repeat),
                label: 'Recurrentes',
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
                // PDR-001 A3: emoji placeholder art, same as the pet views
                // themselves — no icon font glyph fits "our pet" as well as
                // the literal paw.
                icon: Text('🐾', style: TextStyle(fontSize: 22)),
                label: 'Mascota',
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

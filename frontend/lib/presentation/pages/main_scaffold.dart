import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
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
    context.read<ShoppingCubit>().load(householdId);
    context.read<SocketCubit>().joinHousehold(householdId);
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
          body: IndexedStack(index: _index, children: _pages),
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

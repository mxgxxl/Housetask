import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
import '../../services/cache_service.dart';
import '../cubit/auth_cubit.dart';
import '../cubit/household_cubit.dart';
import '../cubit/shopping_cubit.dart';
import '../cubit/socket_cubit.dart';
import '../cubit/task_cubit.dart';
import '../widgets/common.dart';
import '../widgets/logout_dialog.dart';
import '../widgets/user_avatar.dart';
import 'household_setup_page.dart';
import 'stats_page.dart';

/// Profile: user info, household details + invite code, members, and actions
/// to switch households or log out.
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Perfil',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: 'Estadísticas',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const StatsPage()),
            ),
          ),
        ],
      ),
      body: BlocBuilder<AuthCubit, AuthState>(
        builder: (context, authState) {
          final user = authState.user;
          if (user == null) {
            return const Center(child: CircularProgressIndicator());
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              // ---- User card ----
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      UserAvatar(user: user, size: 56),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(user.name,
                                style: const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(user.email,
                                style: const TextStyle(color: AppColors.textSecondary)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _editName(context, user.name),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // ---- Household card ----
              BlocBuilder<HouseholdCubit, HouseholdState>(
                builder: (context, hhState) {
                  final household = hhState.current;
                  if (household == null) return const SizedBox.shrink();

                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.home_outlined, color: AppColors.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(household.name,
                                    style: const TextStyle(
                                        fontSize: 16, fontWeight: FontWeight.w700)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _InviteCode(code: household.inviteCode),
                          const SizedBox(height: 16),
                          const Text('Miembros',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          ...household.members.map(
                            (m) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  UserAvatar(user: m.user, size: 34),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      m.user.name.isEmpty ? m.user.email : m.user.name,
                                      style: const TextStyle(fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                  if (m.isAdmin)
                                    const Pill(label: 'Admin', color: AppColors.primary),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),

              // ---- Actions ----
              _ActionTile(
                icon: Icons.group_add_outlined,
                label: 'Unirse a otro hogar',
                onTap: () => _joinHousehold(context),
              ),
              _ActionTile(
                icon: Icons.add_home_outlined,
                label: 'Crear nuevo hogar',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const HouseholdSetupPage(asPage: true)),
                ),
              ),
              const SizedBox(height: 8),
              _ActionTile(
                icon: Icons.logout,
                label: 'Cerrar sesión',
                color: AppColors.error,
                onTap: () => _logout(context),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editName(BuildContext context, String current) async {
    final ctrl = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cambiar nombre'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nombre'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && context.mounted) {
      context.read<AuthCubit>().updateName(name);
    }
  }

  Future<void> _joinHousehold(BuildContext context) async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unirse a un hogar'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Código de invitación',
            hintText: 'HOME1234',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Unirse'),
          ),
        ],
      ),
    );
    if (code != null && code.isNotEmpty && context.mounted) {
      final household = await context.read<HouseholdCubit>().joinHousehold(code);
      if (household != null && context.mounted) {
        context.read<SocketCubit>().joinHousehold(household.id);
        showSnack(context, 'Te has unido a ${household.name}');
      }
    }
  }

  Future<void> _logout(BuildContext context) async {
    // Read once, not from the live stream: a number that changes while the
    // user is reading the sentence is worse than a stable one — they decide
    // about what they saw (TD-061 §3).
    final pending = CacheService().pendingOperationsCountSync;
    final tasks = context.read<TaskCubit>();
    final shopping = context.read<ShoppingCubit>();

    final ok = await showLogoutDialog(
      context,
      pendingCount: pending,
      // Only worth attempting when there is something to drain.
      trySync: pending == 0 ? null : () => _drainQueue(tasks, shopping),
    );
    if (ok != true || !context.mounted) return;

    // Socket teardown, cubit resets, and navigation to login all happen in
    // reaction to the AuthState this emits — see the app-wide listener in
    // app.dart (TD-055/TD-058) — so this page only has to trigger it.
    await context.read<AuthCubit>().logout();
  }

  /// Try to empty the offline queue before logging out, and report what is
  /// left (TD-061 §2, decision C).
  ///
  /// Capped at 5 seconds: past that the user is staring at a dialog that will
  /// not tell them anything new, and whatever has not synced by then is what
  /// the warning has to be about.
  ///
  /// No connectivity pre-check on purpose. With no network the request fails
  /// immediately with a network error, so the offline case falls through to
  /// the warning fast and without spending the budget — a pre-check would only
  /// add a second source of truth about being online.
  ///
  /// Never throws: a failed drain and a drain that synced nothing are the same
  /// situation from the user's side, and the count says which.
  static Future<int> _drainQueue(TaskCubit tasks, ShoppingCubit shopping) async {
    try {
      await Future.wait([
        _syncOrAwait(
          isSyncing: tasks.state.isSyncing,
          syncing: tasks.stream.map((s) => s.isSyncing),
          start: tasks.syncPending,
        ),
        _syncOrAwait(
          isSyncing: shopping.state.isSyncing,
          syncing: shopping.stream.map((s) => s.isSyncing),
          start: shopping.syncPending,
        ),
      ]).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Timed out, offline, or the server refused. The remaining count below
      // is the answer either way.
    }
    return CacheService().pendingOperationsCountSync;
  }

  /// Wait for a sync already in flight instead of starting a second one.
  ///
  /// `syncPending()` fires automatically on the offline→online transition, so
  /// opening the logout dialog right then could overlap two drains. Replaying
  /// twice is safe (every create carries an Idempotency-Key, Hard Rule 13) but
  /// it is needless traffic (TD-061 §4.4).
  static Future<void> _syncOrAwait({
    required bool isSyncing,
    required Stream<bool> syncing,
    required Future<void> Function() start,
  }) async {
    if (isSyncing) {
      await syncing.firstWhere((v) => !v);
      return;
    }
    await start();
  }
}

class _InviteCode extends StatelessWidget {
  final String code;

  const _InviteCode({required this.code});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Código de invitación',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 2),
              Text(
                code,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.copy, color: AppColors.primary),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              showSnack(context, 'Código copiado: $code');
            },
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(icon, color: color ?? AppColors.textPrimary),
        title: Text(label,
            style: TextStyle(
                fontWeight: FontWeight.w600, color: color ?? AppColors.textPrimary)),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
        onTap: onTap,
      ),
    );
  }
}

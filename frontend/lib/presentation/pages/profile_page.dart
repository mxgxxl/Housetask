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
import '../../data/models/member.dart';
import '../cubit/household_economy_cubit.dart';
import '../widgets/common.dart';
import '../widgets/governance_dialogs.dart';
import '../widgets/household_admin_section.dart';
import '../widgets/logout_dialog.dart';
import '../widgets/user_avatar.dart';
import 'household_setup_page.dart';
import 'stats_page.dart';

/// Profile: user info, household details + invite code, members, and actions
/// to manage the household, switch households or log out.
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  @override
  void initState() {
    super.initState();
    // Whether a deletion is pending (PDR-022 D4) is not part of the household
    // document, so it needs its own read. Done here rather than on app start
    // because this is the only screen that shows it, and a failed read is
    // swallowed by the cubit — a missing banner, never an error toast.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<HouseholdCubit>().loadDestructionStatus();
    });
  }

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

              // ---- Manage household (TD-067, PDR-022) ----
              BlocBuilder<HouseholdCubit, HouseholdState>(
                builder: (context, hhState) {
                  final household = hhState.current;
                  if (household == null) return const SizedBox.shrink();

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: HouseholdAdminSection(
                      household: household,
                      currentUserId: user.id,
                      destruction: hhState.destruction,
                      hasSavingsContribution: _hasSavingsContribution(context, user.id),
                      onPromote: (m) => _promote(context, m),
                      onDemote: (m) => _demote(context, m),
                      onTransferOwnership: (m) => _transferOwnership(context, m),
                      onLeave: () => _leave(context, household.name),
                      onScheduleDestruction: () =>
                          _scheduleDestruction(context, household.name),
                      onCancelDestruction: () => _cancelDestruction(context),
                      onConfirmDestruction: () => _confirmDestruction(context),
                    ),
                  );
                },
              ),

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

  // ---- Governance handlers (TD-067, PDR-022) ----

  /// Whether the reader has coins locked in the household's active savings
  /// goal, so the leave dialog can promise them back (PDR-018).
  ///
  /// Read from the economy cubit that already holds the goal rather than
  /// fetched: this only decides whether one sentence appears, and a network
  /// round trip to decide that would delay the dialog for everyone.
  static bool _hasSavingsContribution(BuildContext context, String userId) {
    final goal = context.read<HouseholdEconomyCubit>().state.activeSavingsGoal;
    if (goal == null) return false;
    return goal.contributions.any((c) => c.userId == userId && c.amount > 0);
  }

  static String _memberName(Member m) =>
      m.user.name.isEmpty ? m.user.email : m.user.name;

  /// Promotion is the only governance action with no dialog: it GRANTS a
  /// permission rather than removing one, and PDR-022 D5 asks for confirmation
  /// on the destructive half. Demoting the person again is one tap away.
  Future<void> _promote(BuildContext context, Member member) async {
    final ok = await context.read<HouseholdCubit>().promoteMember(member.user.id);
    if (!context.mounted) return;
    _report(context, ok, '${_memberName(member)} ya es administrador');
  }

  Future<void> _demote(BuildContext context, Member member) async {
    if (!await showDemoteDialog(context, _memberName(member))) return;
    if (!context.mounted) return;
    final ok = await context.read<HouseholdCubit>().demoteMember(member.user.id);
    if (!context.mounted) return;
    _report(context, ok, '${_memberName(member)} ya no es administrador');
  }

  Future<void> _transferOwnership(BuildContext context, Member member) async {
    if (!await showTransferOwnershipDialog(context, _memberName(member))) return;
    if (!context.mounted) return;
    final ok =
        await context.read<HouseholdCubit>().transferOwnership(member.user.id);
    if (!context.mounted) return;
    _report(context, ok, '${_memberName(member)} es ahora propietario del hogar');
  }

  Future<void> _leave(BuildContext context, String householdName) async {
    final cubit = context.read<HouseholdCubit>();
    final household = cubit.state.current;
    final userId = context.read<AuthCubit>().state.user?.id;
    if (household == null || userId == null) return;

    // Both warnings are computed from state already in hand, so the dialog
    // opens immediately and says only what actually applies to this member.
    final me = household.members.where((m) => m.user.id == userId);
    final willPromote = me.isNotEmpty &&
        me.first.isAdmin &&
        household.members.where((m) => m.isAdmin).length == 1;

    final confirmed = await showLeaveHouseholdDialog(
      context,
      householdName: householdName,
      willPromoteSuccessor: willPromote,
      hasSavingsContribution: _hasSavingsContribution(context, userId),
    );
    if (!confirmed || !context.mounted) return;

    final outcome = await cubit.leaveHousehold();
    if (!context.mounted) return;
    if (outcome == null) {
      showSnack(context, cubit.state.error ?? 'No se pudo salir del hogar');
      return;
    }
    context.read<SocketCubit>().leaveHousehold(household.id);
    _resetHouseholdScopedState(context);
    showSnack(context, 'Has salido de $householdName');
  }

  Future<void> _scheduleDestruction(
    BuildContext context,
    String householdName,
  ) async {
    final confirmed = await showDestroyHouseholdDialog(
      context,
      householdName: householdName,
      gracePeriod: const Duration(hours: 24),
    );
    if (!confirmed || !context.mounted) return;
    final cubit = context.read<HouseholdCubit>();
    final ok = await cubit.scheduleDestruction();
    if (!context.mounted) return;
    _report(context, ok, 'El hogar se eliminará en 24 horas');
  }

  Future<void> _cancelDestruction(BuildContext context) async {
    final ok = await context.read<HouseholdCubit>().cancelDestruction();
    if (!context.mounted) return;
    _report(context, ok, 'Eliminación cancelada');
  }

  Future<void> _confirmDestruction(BuildContext context) async {
    final cubit = context.read<HouseholdCubit>();
    final household = cubit.state.current;
    if (household == null) return;
    final ok = await cubit.confirmDestruction();
    if (!context.mounted) return;
    if (!ok) {
      showSnack(context, cubit.state.error ?? 'No se pudo eliminar el hogar');
      return;
    }
    context.read<SocketCubit>().leaveHousehold(household.id);
    _resetHouseholdScopedState(context);
    showSnack(context, 'Hogar eliminado');
  }

  /// Drop everything scoped to the household the user just left or deleted.
  ///
  /// Same set the session-expiry listener resets (TD-055/TD-058), minus auth:
  /// the session is fine, it is the household that is gone. Without this the
  /// tasks and shopping tabs would keep rendering a household the user can no
  /// longer read, and the next request would 403 or 404 into an error state.
  static void _resetHouseholdScopedState(BuildContext context) {
    context.read<TaskCubit>().reset();
    context.read<ShoppingCubit>().reset();
  }

  /// Snack the success line, or whatever the server said went wrong.
  static void _report(BuildContext context, bool ok, String success) {
    final cubit = context.read<HouseholdCubit>();
    showSnack(context, ok ? success : (cubit.state.error ?? 'No se pudo completar la acción'));
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

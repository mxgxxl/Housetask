import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../config/theme.dart';
import '../../data/models/household.dart';
import '../../data/models/household_governance.dart';
import '../../data/models/member.dart';
import 'common.dart';
import 'user_avatar.dart';

/// «Administrar hogar» — the UI half of PDR-022 (TD-067).
///
/// Deliberately presentational: it takes a household, who is looking at it and
/// what is pending, and calls back. No cubit, no repository, no navigation. It
/// is the only way to test the permission matrix — which is the whole point of
/// the widget — without standing up five cubits to assert that a button is
/// absent.
///
/// ── What the visibility rules are, and what they are NOT ─────────────────
/// Role management, ownership transfer and deletion render only for the
/// creator (D1/D2/D4). «Salir del hogar» renders for everyone, including the
/// creator, because leaving is a right (D3) and D2 guarantees the creator's
/// exit hands the household on rather than breaking it.
///
/// None of this is security. Every action is re-authorized server-side against
/// `createdBy` read inside the transaction that writes (Hard Rule 3); hiding a
/// button only keeps the interface honest about what will work. That is why
/// the buttons targeting the creator are DISABLED rather than hidden: a
/// disabled control says "this is not allowed", while an absent one says
/// "this does not exist", and the second is a lie the user would have to
/// discover by trying.
class HouseholdAdminSection extends StatelessWidget {
  final Household household;

  /// The reader. Compared against `household.createdBy` for D1.
  final String currentUserId;

  /// Pending deletion, if the caller has loaded it (D4). Null while unknown.
  final DestructionStatus? destruction;

  /// True when the reader has coins sitting in an active joint savings goal,
  /// so the leave dialog can warn that they will come back (PDR-018).
  final bool hasSavingsContribution;

  final void Function(Member member) onPromote;
  final void Function(Member member) onDemote;
  final void Function(Member member) onTransferOwnership;
  final VoidCallback onLeave;
  final VoidCallback onScheduleDestruction;
  final VoidCallback onCancelDestruction;
  final VoidCallback onConfirmDestruction;

  const HouseholdAdminSection({
    super.key,
    required this.household,
    required this.currentUserId,
    required this.onPromote,
    required this.onDemote,
    required this.onTransferOwnership,
    required this.onLeave,
    required this.onScheduleDestruction,
    required this.onCancelDestruction,
    required this.onConfirmDestruction,
    this.destruction,
    this.hasSavingsContribution = false,
  });

  bool get _isCreator => household.createdBy == currentUserId;

  bool _isCreatorMember(Member m) => m.user.id == household.createdBy;

  /// True when the reader leaving would leave the household with no admin, so
  /// the dialog can warn that seniority decides the successor (D3).
  bool get willPromoteSuccessor {
    final me = household.members.where((m) => m.user.id == currentUserId);
    if (me.isEmpty || !me.first.isAdmin) return false;
    return household.members.where((m) => m.isAdmin).length == 1;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (destruction?.scheduled == true) ...[
          _DestructionBanner(
            status: destruction!,
            isCreator: _isCreator,
            onCancel: onCancelDestruction,
            onConfirm: onConfirmDestruction,
          ),
          const SizedBox(height: 16),
        ],
        if (_isCreator) ...[
          const Text(
            'Administrar hogar',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 4),
          const Text(
            'Sólo tú, como creador del hogar, puedes cambiar roles, transferir '
            'la propiedad o eliminarlo.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          ...household.members.map(_memberRow),
          const SizedBox(height: 8),
        ],
        // Visible to every member, creator included (D3).
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            leading: const Icon(Icons.exit_to_app, color: AppColors.error),
            title: const Text(
              'Salir del hogar',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.error,
              ),
            ),
            onTap: onLeave,
          ),
        ),
        if (_isCreator && destruction?.scheduled != true)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: const Icon(Icons.delete_forever, color: AppColors.error),
              title: const Text(
                'Eliminar hogar',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.error,
                ),
              ),
              subtitle: const Text('Podrás cancelarlo durante 24 horas'),
              onTap: onScheduleDestruction,
            ),
          ),
      ],
    );
  }

  Widget _memberRow(Member member) {
    final isCreatorRow = _isCreatorMember(member);
    final name =
        member.user.name.isEmpty ? member.user.email : member.user.name;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          UserAvatar(user: member.user, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    // Both badges, not one: «Creador» is a permission
                    // (PDR-022 D1) and «Admin» is a different one. A creator
                    // is always an admin too, and collapsing the two would
                    // hide that an ordinary admin exists alongside them.
                    if (isCreatorRow) ...[
                      const Pill(label: 'Creador', color: AppColors.secondary),
                      const SizedBox(width: 6),
                    ],
                    if (member.isAdmin)
                      const Pill(label: 'Admin', color: AppColors.primary),
                  ],
                ),
              ],
            ),
          ),
          if (member.isAdmin && !isCreatorRow)
            IconButton(
              icon: const Icon(Icons.swap_horiz),
              tooltip: 'Transferir propiedad',
              onPressed: () => onTransferOwnership(member),
            ),
          IconButton(
            icon: Icon(
              member.isAdmin
                  ? Icons.arrow_downward
                  : Icons.arrow_upward,
            ),
            tooltip: isCreatorRow
                // Says WHY, because a disabled control with no explanation is
                // just a broken one.
                ? 'El creador del hogar no puede ser degradado'
                : (member.isAdmin
                    ? 'Quitar administrador'
                    : 'Hacer administrador'),
            // Disabled, never hidden: the creator's own row must still show
            // that the action exists and does not apply to them.
            onPressed: isCreatorRow
                ? null
                : () => member.isAdmin ? onDemote(member) : onPromote(member),
          ),
        ],
      ),
    );
  }
}

/// The pending-deletion banner (PDR-022 D4).
///
/// Shown to every member, not only the creator: a household about to be
/// deleted is something everyone living in it should see coming. Only the
/// creator gets the buttons.
class _DestructionBanner extends StatelessWidget {
  final DestructionStatus status;
  final bool isCreator;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _DestructionBanner({
    required this.status,
    required this.isCreator,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final at = status.scheduledAt;
    final expired = status.isExpired;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppColors.error),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Este hogar se va a eliminar',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.error,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            expired
                ? 'El plazo para cancelar ha terminado.'
                : at == null
                    ? 'La eliminación está programada.'
                    : 'Puedes cancelarlo hasta el '
                        '${DateFormat("d 'de' MMMM 'a las' HH:mm", 'es').format(at.toLocal())}.',
            style: const TextStyle(fontSize: 13),
          ),
          if (isCreator) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: onCancel,
                  child: const Text('Cancelar eliminación'),
                ),
                const SizedBox(width: 8),
                if (expired)
                  TextButton(
                    onPressed: onConfirm,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.error,
                    ),
                    child: const Text('Eliminar ahora'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

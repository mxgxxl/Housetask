import 'package:flutter/material.dart';

import '../../config/theme.dart';

/// Confirmations for the household-governance actions (TD-067, PDR-022 D5).
///
/// Every one of these is destructive in a way the user cannot undo from the
/// app: a demotion needs the creator to re-promote, a transfer needs the new
/// owner's cooperation to reverse, leaving needs the invite code again, and a
/// deletion needs nothing because there is nothing left. So D5 requires a
/// dialog on all of them.
///
/// The dialogs are pure functions of their inputs and live outside ProfilePage
/// for the same reason [showLogoutDialog] does: standing up a page with its
/// household, auth and socket cubits to assert the wording of a sentence tests
/// everything except the sentence.
///
/// They confirm; they do not authorize. Every rule they describe is re-checked
/// server-side (Hard Rule 3) — a client that skipped the dialog would still be
/// refused.

/// Generic yes/no confirmation. Returns true only on explicit confirmation.
Future<bool> showGovernanceConfirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: AppColors.error)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// «Quitar permisos de administrador» (TD-067-DESIGN §5).
Future<bool> showDemoteDialog(BuildContext context, String name) =>
    showGovernanceConfirm(
      context,
      title: 'Quitar permisos de administrador',
      body: '¿Quieres convertir a $name en miembro? Ya no podrá gestionar '
          'roles, expulsar miembros ni realizar otras acciones '
          'administrativas.',
      confirmLabel: 'Convertir en miembro',
    );

/// «Transferir propiedad» (PDR-022 D2).
///
/// The copy differs from TD-067-DESIGN §5's «Transferir administración» on one
/// point that PDR-022 changed: the outgoing owner stays an ADMIN, not a plain
/// member, because D1 separated the two and only the D1 authority moves.
Future<bool> showTransferOwnershipDialog(BuildContext context, String name) =>
    showGovernanceConfirm(
      context,
      title: 'Transferir propiedad',
      body: '¿Quieres que $name pase a ser la persona propietaria de este '
          'hogar? Podrá gestionar roles y eliminar el hogar. Tú seguirás '
          'siendo administrador, pero ya no podrás cambiar roles.',
      confirmLabel: 'Transferir',
    );

/// «Salir del hogar» (PDR-022 D3).
///
/// The two warnings are conditional because both are consequences the user
/// cannot see from the screen they are on: [willPromoteSuccessor] is a fact
/// about the household's admin count, and [hasSavingsContribution] is about
/// money the joint goal is holding on their behalf. Showing either one when it
/// does not apply would be as wrong as hiding it when it does.
Future<bool> showLeaveHouseholdDialog(
  BuildContext context, {
  required String householdName,
  bool willPromoteSuccessor = false,
  bool hasSavingsContribution = false,
}) {
  final warnings = <String>[
    if (willPromoteSuccessor)
      'Eres el único administrador, así que el miembro más antiguo del hogar '
          'quedará como administrador.',
    if (hasSavingsContribution)
      'Se te devolverán las monedas que hayas aportado a la hucha conjunta.',
  ];

  return showGovernanceConfirm(
    context,
    title: 'Salir del hogar',
    body: [
      '¿Quieres salir de $householdName? Dejarás de ver sus tareas, su lista '
          'de la compra y su progreso compartido. Tu XP y tus monedas '
          'personales se conservan.',
      ...warnings,
    ].join('\n\n'),
    confirmLabel: 'Salir',
    destructive: true,
  );
}

/// «Eliminar hogar»: the strong confirmation of PDR-022 D4.
///
/// Typing the household's name is the point. Every other dialog here is one
/// tap away from a tap the user may have made by accident; this is the only
/// action with no undo at all once the grace period expires, so it asks for
/// something nobody does by accident. The comparison is trimmed and
/// case-insensitive — the intent is to prove the user knows WHICH household
/// they are deleting, not to test their typing.
Future<bool> showDestroyHouseholdDialog(
  BuildContext context, {
  required String householdName,
  required Duration gracePeriod,
}) async {
  final hours = gracePeriod.inHours;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => _DestroyHouseholdDialog(
      householdName: householdName,
      graceHours: hours,
    ),
  );
  return result ?? false;
}

class _DestroyHouseholdDialog extends StatefulWidget {
  final String householdName;
  final int graceHours;

  const _DestroyHouseholdDialog({
    required this.householdName,
    required this.graceHours,
  });

  @override
  State<_DestroyHouseholdDialog> createState() =>
      _DestroyHouseholdDialogState();
}

class _DestroyHouseholdDialogState extends State<_DestroyHouseholdDialog> {
  final _controller = TextEditingController();
  bool _matches = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final matches = _controller.text.trim().toLowerCase() ==
          widget.householdName.trim().toLowerCase();
      if (matches != _matches) setState(() => _matches = matches);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Eliminar hogar'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Se eliminarán las tareas, la lista de la compra, la mascota y el '
            'progreso compartido de ${widget.householdName}. Tu XP y tus '
            'monedas personales se conservan.',
          ),
          const SizedBox(height: 12),
          Text(
            'Tendrás ${widget.graceHours} horas para cancelarlo antes de que '
            'se elimine definitivamente.',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          Text(
            'Escribe «${widget.householdName}» para confirmar:',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nombre del hogar',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          // Disabled until the name matches. The button being INERT rather
          // than absent is deliberate: the user has to be able to see what
          // they are working towards.
          onPressed: _matches ? () => Navigator.pop(context, true) : null,
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          child: const Text('Eliminar hogar'),
        ),
      ],
    );
  }
}

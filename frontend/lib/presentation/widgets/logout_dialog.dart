import 'package:flutter/material.dart';

import '../../config/theme.dart';

/// Confirmation shown before closing the session.
///
/// Extracted from ProfilePage so it can be exercised on its own: TD-061 adds
/// a variant that depends on how many offline writes are still queued, and
/// standing up the whole profile page — with its household, socket and auth
/// cubits — to assert the wording of a dialog would test everything except
/// the thing under test.
///
/// Returns true when the user confirms, false or null when they cancel or
/// dismiss it.
Future<bool?> showLogoutDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => const LogoutDialog(),
  );
}

/// The dialog itself. Public so a widget test can pump it directly.
class LogoutDialog extends StatelessWidget {
  const LogoutDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cerrar sesión'),
      content: const Text('¿Seguro que quieres cerrar sesión?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Cerrar sesión'),
        ),
      ],
    );
  }
}

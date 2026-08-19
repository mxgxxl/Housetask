import 'package:flutter/material.dart';

import '../../config/theme.dart';

/// Confirmation shown before closing the session.
///
/// Extracted from ProfilePage so it can be exercised on its own: the variant
/// below depends on how many offline writes are still queued (TD-061), and
/// standing up the whole profile page — with its household, socket and auth
/// cubits — to assert the wording of a dialog would test everything except
/// the thing under test.
///
/// [pendingCount] is the number of queued offline operations that logging out
/// would discard. The caller reads it from
/// `CacheService.pendingOperationsCountSync`; it is passed in rather than read
/// here so the dialog stays a pure function of its input.
///
/// Returns true when the user confirms, false or null when they cancel or
/// dismiss it.
Future<bool?> showLogoutDialog(
  BuildContext context, {
  required int pendingCount,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => LogoutDialog(pendingCount: pendingCount),
  );
}

/// The dialog itself. Public so a widget test can pump it directly.
class LogoutDialog extends StatelessWidget {
  /// Queued offline writes that would be lost. Zero means nothing to warn about.
  final int pendingCount;

  const LogoutDialog({super.key, required this.pendingCount});

  /// "1 cambio" / "N cambios" — spelled out rather than interpolated with a
  /// trailing "(s)", which reads like a form field.
  String get _changes =>
      pendingCount == 1 ? '1 cambio' : '$pendingCount cambios';

  @override
  Widget build(BuildContext context) {
    // Nothing queued: the plain confirmation, unchanged. A warning shown on
    // every logout is a warning nobody reads — it only carries weight because
    // it appears exactly when there is something to lose (TD-061 §2).
    final hasPending = pendingCount > 0;

    return AlertDialog(
      title: const Text('Cerrar sesión'),
      content: hasPending
          ? Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Tienes '),
                  TextSpan(
                    text: '$_changes sin sincronizar',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(
                    text: '. Si cierras sesión ahora, se perderán.',
                  ),
                ],
              ),
            )
          : const Text('¿Seguro que quieres cerrar sesión?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: () => Navigator.pop(context, true),
          // Names the consequence instead of hiding it behind a neutral verb,
          // the same way a rejected delete names the task it could not remove.
          child: Text(hasPending ? 'Cerrar sesión y descartar' : 'Cerrar sesión'),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../config/theme.dart';

/// Confirmation shown before closing the session.
///
/// Extracted from ProfilePage so it can be exercised on its own: the variants
/// below depend on how many offline writes are still queued (TD-061), and
/// standing up the whole profile page — with its household, socket and auth
/// cubits — to assert the wording of a dialog would test everything except
/// the thing under test.
///
/// [pendingCount] is the number of queued offline operations that logging out
/// would discard. The caller reads it from
/// `CacheService.pendingOperationsCountSync`; it is passed in rather than read
/// here so the dialog stays a pure function of its input.
///
/// [trySync], when given, is attempted once before asking anything: the best
/// warning is the one that turns out to be unnecessary. It must resolve to the
/// number of operations STILL queued afterwards, and must never throw — the
/// dialog treats "could not sync" and "synced nothing" the same way, because
/// from the user's side they are the same situation.
///
/// Returns true when the user confirms, false or null when they cancel or
/// dismiss it.
Future<bool?> showLogoutDialog(
  BuildContext context, {
  required int pendingCount,
  Future<int> Function()? trySync,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => LogoutDialog(pendingCount: pendingCount, trySync: trySync),
  );
}

/// The dialog itself. Public so a widget test can pump it directly.
class LogoutDialog extends StatefulWidget {
  /// Queued offline writes that would be lost. Zero means nothing to warn about.
  final int pendingCount;

  /// Optional drain attempt; see [showLogoutDialog].
  final Future<int> Function()? trySync;

  const LogoutDialog({super.key, required this.pendingCount, this.trySync});

  @override
  State<LogoutDialog> createState() => _LogoutDialogState();
}

class _LogoutDialogState extends State<LogoutDialog> {
  late int _pending = widget.pendingCount;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    if (widget.trySync != null && widget.pendingCount > 0) {
      _syncing = true;
      _drain();
    }
  }

  Future<void> _drain() async {
    final remaining = await widget.trySync!();
    // Cancelling the dialog does NOT abort the sync (TD-061 §4.2): it is
    // already in flight, it is useful, and stopping it would help nobody. All
    // that happens here is that a dismissed dialog stops caring about the
    // result.
    if (!mounted) return;
    setState(() {
      _pending = remaining;
      _syncing = false;
    });
  }

  /// "1 cambio" / "N cambios" — spelled out rather than interpolated with a
  /// trailing "(s)", which reads like a form field.
  String _changes(int n) => n == 1 ? '1 cambio' : '$n cambios';

  @override
  Widget build(BuildContext context) {
    // Nothing queued: the plain confirmation, unchanged. A warning shown on
    // every logout is a warning nobody reads — it only carries weight because
    // it appears exactly when there is something to lose (TD-061 §2).
    final hasPending = _pending > 0;

    return AlertDialog(
      title: const Text('Cerrar sesión'),
      content: _content(hasPending),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          // Disabled while draining: confirming mid-sync would discard writes
          // that were seconds away from being safe.
          onPressed: _syncing ? null : () => Navigator.pop(context, true),
          // Names the consequence instead of hiding it behind a neutral verb,
          // the same way a rejected delete names the task it could not remove.
          child: Text(
            hasPending && !_syncing ? 'Cerrar sesión y descartar' : 'Cerrar sesión',
          ),
        ),
      ],
    );
  }

  Widget _content(bool hasPending) {
    if (_syncing) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          // Explicit text, not a mute spinner: the wait has a reason and the
          // user should be able to read it.
          Expanded(
            child: Text('Sincronizando ${_changes(_pending)} pendientes…'),
          ),
        ],
      );
    }

    if (!hasPending) {
      return const Text('¿Seguro que quieres cerrar sesión?');
    }

    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'Tienes '),
          TextSpan(
            text: '${_changes(_pending)} sin sincronizar',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const TextSpan(text: '. Si cierras sesión ahora, se perderán.'),
        ],
      ),
    );
  }
}

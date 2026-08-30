import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../cubit/economy_p1_cubit.dart';

/// The modal-class celebrations: a personal level-up and a task milestone
/// (TD-066 F2, owner decision D4).
///
/// ── Why a light overlay and not confetti ─────────────────────────────────
/// UX-P1-SPEC §0: «La intensidad de celebración es inversa a la frecuencia
/// del evento», and §3 puts a personal level at modal intensity — above the
/// completion chip and the ice banner, below the shared household level-up.
/// D4 asks for something coherent with the banners already in the app, so
/// this is a small card rather than a full-screen takeover.
///
/// ── Transient by construction ────────────────────────────────────────────
/// Nothing here is persisted, and nothing needs to be: the cubit raises the
/// celebration once (a level-up fires exactly once per completion, guaranteed
/// server-side by the RewardGrant unique index) and clears it on dismiss. A
/// missed one is not re-shown — the unlock itself survives in the level's
/// cumulative `unlocks` list, which the section renders.
Future<void> showEconomyCelebration(
  BuildContext context,
  EconomyP1Notice notice, {
  VoidCallback? onDismissed,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => EconomyCelebrationDialog(notice: notice),
  ).then((_) => onDismissed?.call());
}

class EconomyCelebrationDialog extends StatelessWidget {
  final EconomyP1Notice notice;

  const EconomyCelebrationDialog({super.key, required this.notice});

  bool get _isLevelUp => notice.kind == EconomyP1NoticeKind.levelUp;

  String get _emoji => _isLevelUp ? '🎉' : '🏅';

  String get _title => _isLevelUp ? '¡Subiste de nivel!' : '¡Hito conseguido!';

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_emoji, style: const TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(
              _title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              notice.message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            if (notice.unlocks.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Has desbloqueado',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final unlock in notice.unlocks)
                    Chip(
                      label: Text(unlock),
                      backgroundColor:
                          AppColors.secondary.withValues(alpha: 0.12),
                      labelStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.secondary,
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Genial'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

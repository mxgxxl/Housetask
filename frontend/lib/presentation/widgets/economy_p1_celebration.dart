import 'package:flutter/material.dart';

import '../cubit/economy_p1_cubit.dart';
import 'celebration_dialog.dart';

/// The modal-class celebrations: a personal level-up and a task milestone
/// (TD-066 F2, owner decision D4).
///
/// UX-P1-SPEC §0: «La intensidad de celebración es inversa a la frecuencia
/// del evento», and §3 puts a personal level at modal intensity — above the
/// completion chip and the ice banner, below the shared household level-up.
/// The card itself is [CelebrationDialog], shared with the household track
/// since F3: only the copy differs between the two.
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
    return CelebrationDialog(
      emoji: _emoji,
      title: _title,
      message: notice.message,
      unlocks: notice.unlocks,
    );
  }
}

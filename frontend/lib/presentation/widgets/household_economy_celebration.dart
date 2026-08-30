import 'package:flutter/material.dart';

import '../cubit/household_economy_cubit.dart';
import 'celebration_dialog.dart';

/// The modal-class SHARED celebrations: a household level-up and an unlocked
/// joint savings goal (TD-066 F3).
///
/// ── Why the copy is plural, and fixed ────────────────────────────────────
/// UX-P1-SPEC §3 names this moment in as many words: «Modal compartido "lo
/// habéis conseguido juntos" con desbloqueo de hogar». The whole point of the
/// household track is that nobody earned it alone (PDR-017: personal XP
/// travels with the account, household XP belongs to the home), so the
/// sentence never names a member and never says «tú». The message itself
/// comes from the cubit, which is where the spec's wording lives — this only
/// picks the glyph and the heading.
///
/// ── Transient by construction ────────────────────────────────────────────
/// Nothing is persisted, and nothing needs to be: a household level-up fires
/// exactly once, guaranteed server-side by the RewardGrant unique index, and
/// the unlock itself survives in the level's cumulative `unlocks` list, which
/// the section renders. A member who had the app closed simply sees the
/// unlock rather than the party.
Future<void> showHouseholdCelebration(
  BuildContext context,
  HouseholdEconomyNotice notice, {
  VoidCallback? onDismissed,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => HouseholdCelebrationDialog(notice: notice),
  ).then((_) => onDismissed?.call());
}

class HouseholdCelebrationDialog extends StatelessWidget {
  final HouseholdEconomyNotice notice;

  const HouseholdCelebrationDialog({super.key, required this.notice});

  bool get _isLevelUp => notice.kind == HouseholdNoticeKind.levelUp;

  /// A house for a shared level (UX-P1-SPEC §2's grammar), a coin purse for
  /// an unlocked goal — which is what a joint savings goal actually is.
  String get _emoji => _isLevelUp ? '🏠' : '🎁';

  String get _title => _isLevelUp
      ? '¡Nivel de hogar ${notice.level}!'
      : '¡Meta desbloqueada!';

  @override
  Widget build(BuildContext context) {
    return CelebrationDialog(
      emoji: _emoji,
      title: _title,
      message: notice.message,
      unlocks: notice.unlocks,
      // Plural, because the unlock belongs to the household rather than to
      // whoever happened to complete the task that crossed the level.
      unlocksLabel: 'Habéis desbloqueado',
    );
  }
}

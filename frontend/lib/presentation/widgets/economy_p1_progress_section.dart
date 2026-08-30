import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../config/theme.dart';
import '../../core/utils/unlock_label.dart';
import '../cubit/economy_p1_cubit.dart';
import 'common.dart';
import 'economy_p1_celebration.dart';

/// UX-P1-SPEC §2's visual grammar. Local rather than in [AppColors] because
/// they are the P1 economy's vocabulary, not the app's: amber is the coin,
/// coral is the flame, blue is the ice.
const Color _coinAmber = AppColors.priorityMedium;
const Color _flameCoral = Color(0xFFFB7185);
const Color _iceBlue = Color(0xFF38BDF8);

/// "Mi progreso" — the personal half of the P1 economy (TD-066 F2).
///
/// Lives in the Mascota tab beside the Fase A economy (owner decision D1)
/// rather than in a tab of its own, and renders NOTHING at all until the
/// household has P1 switched on.
///
/// ── Why "renders nothing" is the whole point ─────────────────────────────
/// `GET /economy/p1/me` answers a complete, ZEROED structure rather than a
/// 404 while the flag is off. A section that trusted those numbers would show
/// a real-looking 0 🪙 wallet, a dead streak and level 1 to a member whose
/// economy simply has not been activated — indistinguishable from having
/// earned nothing. Every household is in that state today, so this is the
/// common case, not the edge one.
class EconomyP1ProgressSection extends StatelessWidget {
  const EconomyP1ProgressSection({super.key});

  @override
  Widget build(BuildContext context) {
    // Two listeners rather than one with a compound condition: a
    // BlocConsumer listener is not told WHICH field changed, so a single
    // callback would have to re-derive that and could fire the wrong one.
    return MultiBlocListener(
      listeners: [
        // Only a REFUSED write is worth a snackbar. A failed read degrades to
        // the stale indicator instead.
        BlocListener<EconomyP1Cubit, EconomyP1State>(
          listenWhen: (previous, current) =>
              current.actionError != null &&
              current.actionError != previous.actionError,
          listener: (context, state) {
            showSnack(context, state.actionError!, isError: true);
            context.read<EconomyP1Cubit>().clearActionError();
          },
        ),
        // Level-ups and milestones (D4). `sequence` is what makes two
        // identical celebrations in a row two distinct states, so the second
        // is not swallowed by Equatable.
        BlocListener<EconomyP1Cubit, EconomyP1State>(
          listenWhen: (previous, current) =>
              current.celebration != null &&
              current.celebration?.sequence != previous.celebration?.sequence,
          listener: (context, state) {
            final cubit = context.read<EconomyP1Cubit>();
            showEconomyCelebration(
              context,
              state.celebration!,
              onDismissed: cubit.dismissCelebration,
            );
          },
        ),
      ],
      child: BlocBuilder<EconomyP1Cubit, EconomyP1State>(
        builder: (context, state) {
          if (!state.isVisible) return const SizedBox.shrink();

          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(state: state),
                const SizedBox(height: 12),
                _TodayLine(state: state),
                const SizedBox(height: 16),
                _PersonalLevel(state: state),
                if (state.weeklyBudget.allocations.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _WeeklyPlan(state: state),
                ],
                const SizedBox(height: 16),
                _BuyIceButton(state: state),
                if (state.notice != null) ...[
                  const SizedBox(height: 12),
                  _NoticeBanner(notice: state.notice!),
                ],
                const SizedBox(height: 8),
                const Divider(),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Wallet, flame and ice reserve — UX-P1-SPEC §2's three header objects,
/// minus the avatar ring, which belongs to the app-wide header rather than
/// to this section.
class _Header extends StatelessWidget {
  final EconomyP1State state;
  const _Header({required this.state});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            'Mi progreso',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        if (state.isStale) ...[
          const Icon(Icons.cloud_off, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 6),
          const Text(
            'Sin conexión',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(width: 12),
        ],
        _Chip(
          emoji: '🪙',
          label: '${state.wallet.balance}',
          color: _coinAmber,
          semantics: 'Saldo: ${state.wallet.balance} monedas',
        ),
        const SizedBox(width: 8),
        _Chip(
          emoji: '🔥',
          label: '${state.streak.current}',
          color: _flameCoral,
          semantics: 'Racha: ${state.streak.current} días',
        ),
        const SizedBox(width: 8),
        _Chip(
          emoji: '❄️',
          label: '${state.streak.iceReserve}',
          color: _iceBlue,
          semantics: 'Hielos: ${state.streak.iceReserve}',
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String emoji;
  final String label;
  final Color color;
  final String semantics;

  const _Chip({
    required this.emoji,
    required this.label,
    required this.color,
    required this.semantics,
  });

  @override
  Widget build(BuildContext context) {
    // `container: true` + ExcludeSemantics so the node carries exactly this
    // label. Without them it merges with the children and a screen reader
    // announces "🔥, 7" — the glyph and a bare number — instead of
    // "Racha: 7 días".
    return Semantics(
      label: semantics,
      container: true,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontWeight: FontWeight.w700, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of UX-P1-SPEC §4's four exact sentences. Which one is decided by
/// [EconomyP1State.todayLineKind]; this only renders it.
class _TodayLine extends StatelessWidget {
  final EconomyP1State state;
  const _TodayLine({required this.state});

  @override
  Widget build(BuildContext context) {
    final wallet = state.wallet;
    final (String text, IconData icon, Color color) =
        switch (state.todayLineKind) {
      TodayLineKind.spentOut => (
          'Completaste tu recompensa de hoy; el progreso sigue contando',
          Icons.check_circle_outline,
          AppColors.priorityLow,
        ),
      // The leaf is the rest day's mark in the spec's visual grammar (§2).
      TodayLineKind.restDay => (
          'Día de descanso: tu progreso cuenta, las monedas descansan',
          Icons.eco_outlined,
          AppColors.priorityLow,
        ),
      TodayLineKind.carryOver => (
          'Hoy: ${wallet.remaining} 🪙 (incluye ${state.carriedOverCoins} de días anteriores)',
          Icons.today_outlined,
          _coinAmber,
        ),
      TodayLineKind.normal => (
          'Hoy: ${wallet.remaining}/${wallet.dailyReleased} 🪙 disponibles',
          Icons.today_outlined,
          _coinAmber,
        ),
    };

    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

/// Level, its progress bar, and the unlocks earned up to it.
///
/// The unlocks come from the read and are rendered as-is; nothing is stored
/// locally. An unlock that lived only in a socket event would be forgotten on
/// the next launch, which is why the API returns the cumulative list.
class _PersonalLevel extends StatelessWidget {
  final EconomyP1State state;
  const _PersonalLevel({required this.state});

  @override
  Widget build(BuildContext context) {
    final progress = state.personalProgress;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Nivel ${progress.level}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            Text(
              '${progress.xpIntoLevel}/${progress.xpForNextLevel} XP',
              style:
                  const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: progress.progressToNext,
            minHeight: 8,
            backgroundColor: AppColors.divider,
            valueColor:
                const AlwaysStoppedAnimation<Color>(AppColors.secondary),
          ),
        ),
        if (state.unlocks.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final unlock in state.unlocks)
                // `title:constante` → «Constante». Shared with the household
                // track since F3, which needs the identical mapping — two
                // copies would drift towards two names for one unlock.
                Pill(label: unlockLabel(unlock), color: AppColors.secondary),
            ],
          ),
        ],
      ],
    );
  }
}

/// The weekly plan, READ-ONLY (owner decision D3).
///
/// `PATCH /economy/p1/budget` exists (B8) but gets no UI this round, so
/// nothing here is tappable — showing the numbers without an editor is the
/// point, not an oversight.
class _WeeklyPlan extends StatelessWidget {
  final EconomyP1State state;
  const _WeeklyPlan({required this.state});

  @override
  Widget build(BuildContext context) {
    final budget = state.weeklyBudget;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Plan semanal',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
            Text(
              '${budget.weeklyCap} 🪙',
              style:
                  const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final allocation in budget.allocations)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    allocation.isCommonTranche
                        ? 'Tareas sin asignar'
                        : allocation.allocationKey,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textSecondary),
                  ),
                ),
                if (allocation.isManual) ...[
                  const Text(
                    'ajustado',
                    style:
                        TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  '${allocation.coinAmount} 🪙',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Buy one ice, with the reason it cannot be bought spelled out.
///
/// A disabled button that does not say why is a dead end, and three of the
/// four reasons are things the member can act on. Offline is deliberately one
/// of them: a monetary debit is never queued (TD-066-DESIGN §7), so the
/// honest thing is to disable it rather than accept a tap that would be lost.
class _BuyIceButton extends StatelessWidget {
  final EconomyP1State state;
  const _BuyIceButton({required this.state});

  static String? _reasonLabel(IceUnavailableReason reason) => switch (reason) {
        IceUnavailableReason.none || IceUnavailableReason.inFlight => null,
        IceUnavailableReason.flagOff =>
          'La economía no está activa en este hogar',
        IceUnavailableReason.reserveFull =>
          'Ya tienes el máximo de hielos ($kMaxIceReserve)',
        IceUnavailableReason.insufficientCoins =>
          'Te faltan monedas (cuesta $kIcePriceCoins 🪙)',
        IceUnavailableReason.offline =>
          'Sin conexión: no se puede comprar ahora',
        IceUnavailableReason.noHousehold => 'Todavía no hay datos de tu hogar',
      };

  @override
  Widget build(BuildContext context) {
    final reason = state.iceUnavailableReason;
    final label = _reasonLabel(reason);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: state.canBuyIce
              ? () => context.read<EconomyP1Cubit>().buyIce()
              : null,
          icon: state.isBuyingIce
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('❄️', style: TextStyle(fontSize: 16)),
          label: const Text('Comprar hielo ($kIcePriceCoins 🪙)'),
        ),
        if (label != null) ...[
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style:
                const TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ],
      ],
    );
  }
}

/// The banner-class events: an ice spent, an ice returned, a streak reset.
///
/// UX-P1-SPEC §3 puts these at banner intensity, below a level-up's modal —
/// the celebration scale is inverse to how often the thing happens.
class _NoticeBanner extends StatelessWidget {
  final EconomyP1Notice notice;
  const _NoticeBanner({required this.notice});

  @override
  Widget build(BuildContext context) {
    final color = switch (notice.kind) {
      EconomyP1NoticeKind.iceConsumed ||
      EconomyP1NoticeKind.iceRefunded =>
        _iceBlue,
      EconomyP1NoticeKind.streakMilestone => _flameCoral,
      // Coins coming back are coins: amber, the wallet's colour (§2).
      EconomyP1NoticeKind.savingsRefunded => _coinAmber,
      // A reset is stated plainly, never in an alarm colour: PDR-019 keeps
      // level, XP and coins intact and the copy says so.
      _ => AppColors.textSecondary,
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              notice.message,
              style:
                  const TextStyle(fontSize: 13, color: AppColors.textPrimary),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            tooltip: 'Descartar',
            onPressed: () => context.read<EconomyP1Cubit>().dismissNotice(),
          ),
        ],
      ),
    );
  }
}

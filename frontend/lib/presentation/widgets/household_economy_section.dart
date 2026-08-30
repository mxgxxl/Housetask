import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../config/theme.dart';
import '../../core/utils/unlock_label.dart';
import '../../data/models/economy_p1/economy_p1.dart';
import '../cubit/household_economy_cubit.dart';
import 'common.dart';
import 'household_economy_celebration.dart';

/// UX-P1-SPEC §2's visual grammar for the shared track: «Nivel de hogar:
/// icono de casa con número y barra». Amber stays the coin, as in
/// [EconomyP1ProgressSection].
const Color _coinAmber = AppColors.priorityMedium;
const Color _houseIndigo = AppColors.primary;

/// «Hogar» — the cooperative half of the P1 economy (TD-066 F3).
///
/// Sits below «Mi progreso» in the Mascota tab, and renders NOTHING at all
/// until the household has P1 switched on.
///
/// ── Why "renders nothing" is the whole point ─────────────────────────────
/// `GET /economy/p1/household` answers a complete, ZEROED structure rather
/// than a 404 while the flag is off — and, unlike the personal half, it still
/// returns a REAL roster, because membership is not economy data. A section
/// that trusted the numbers beside those names would show a household of
/// members all sitting at level 1 with 0 XP, indistinguishable from a home
/// that had done nothing. Every household is in that state today.
///
/// ── What this section is careful not to become ───────────────────────────
/// The roster is rendered in the order the cubit holds it — join order, from
/// the server — with no position numbers, no medals, no podium and no sort
/// control. UX-P1-SPEC §0 rules out «leaderboards de culpa», and every one of
/// those affordances is a step towards one. The same rule governs the savings
/// breakdown: «Tú: 40 · Ana: 28» is a list of who chipped in, not a ranking
/// of who chipped in most, so it keeps the order the cubit gives it too.
class HouseholdEconomySection extends StatelessWidget {
  const HouseholdEconomySection({super.key});

  @override
  Widget build(BuildContext context) {
    // Two listeners rather than one with a compound condition, for the same
    // reason "Mi progreso" uses two: a listener is not told WHICH field
    // changed, so a single callback would have to re-derive that and could
    // fire the wrong feedback.
    return MultiBlocListener(
      listeners: [
        // Modal class: a shared level-up, an unlocked goal (UX-P1-SPEC §3).
        // `sequence` is what makes two identical celebrations in a row two
        // distinct states, so the second is not swallowed by Equatable.
        BlocListener<HouseholdEconomyCubit, HouseholdEconomyState>(
          listenWhen: (previous, current) =>
              current.celebration != null &&
              current.celebration?.sequence != previous.celebration?.sequence,
          listener: (context, state) {
            final cubit = context.read<HouseholdEconomyCubit>();
            showHouseholdCelebration(
              context,
              state.celebration!,
              onDismissed: cubit.dismissCelebration,
            );
          },
        ),
        // Toast class: a pooled milestone. Below a level-up in the same
        // hierarchy — it happens more often, so it interrupts less.
        BlocListener<HouseholdEconomyCubit, HouseholdEconomyState>(
          listenWhen: (previous, current) =>
              current.notice != null &&
              current.notice?.sequence != previous.notice?.sequence,
          listener: (context, state) {
            showSnack(context, state.notice!.message);
            context.read<HouseholdEconomyCubit>().dismissNotice();
          },
        ),
      ],
      child: BlocBuilder<HouseholdEconomyCubit, HouseholdEconomyState>(
        builder: (context, state) {
          if (!state.isVisible) return const SizedBox.shrink();

          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(state: state),
                const SizedBox(height: 12),
                _HouseholdLevel(state: state),
                const SizedBox(height: 16),
                _MemberList(state: state),
                const SizedBox(height: 16),
                _SavingsGoalBlock(state: state),
                const SizedBox(height: 12),
                // UX-P1-SPEC §4's line for the household card, verbatim. It is
                // the sentence that explains the whole two-track design to
                // someone who will never read a PDR.
                const Text(
                  'Tu nivel viaja contigo. El nivel de hogar es de los dos.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
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

class _Header extends StatelessWidget {
  final HouseholdEconomyState state;
  const _Header({required this.state});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            'Hogar',
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
        ],
      ],
    );
  }
}

/// The house icon, the shared level and its bar — UX-P1-SPEC §2 and §4.
class _HouseholdLevel extends StatelessWidget {
  final HouseholdEconomyState state;
  const _HouseholdLevel({required this.state});

  @override
  Widget build(BuildContext context) {
    final progress = state.householdProgress;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.home_outlined, size: 18, color: _houseIndigo),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Nivel de hogar ${progress.level}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Text(
              // «200 XP para nivel 6» — the spec's own phrasing for the
              // household card, which says the distance rather than the
              // fraction because a shared goal reads better as a thing left
              // to do together.
              '${progress.xpToNextLevel} XP para nivel ${progress.level + 1}',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
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
            valueColor: const AlwaysStoppedAnimation<Color>(_houseIndigo),
          ),
        ),
        if (state.unlocks.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final unlock in state.unlocks)
                Pill(label: unlockLabel(unlock), color: _houseIndigo),
            ],
          ),
        ],
      ],
    );
  }
}

/// The roster: one row per member, in the order the server sent.
///
/// Level and personal XP are shown by owner decision (2026-08-27) — no PDR
/// authorizes it, so the backend's read comment records it as a product call.
/// A wallet, a budget or a streak never appear here and never arrive on this
/// room at all: PDR-012 keeps those personal precisely so there is nothing
/// shared to compare.
class _MemberList extends StatelessWidget {
  final HouseholdEconomyState state;
  const _MemberList({required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Miembros',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        // `state.members` is rendered as-is. No `.sorted`, no `..sort`, no
        // index badge: the order IS the join order, and any of those would
        // turn a roster into a ranking (UX-P1-SPEC §0).
        for (final member in state.members)
          _MemberRow(
            member: member,
            isMe: member.userId == state.currentUserId,
          ),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  final HouseholdMemberProgress member;
  final bool isMe;

  const _MemberRow({required this.member, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final name = member.name.isEmpty ? 'Miembro' : member.name;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          _Initial(name: name, userId: member.userId),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isMe ? '$name (tú)' : name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Text(
            'Nivel ${member.level} · ${member.xp} XP',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// A plain initial circle.
///
/// Deliberately not [UserAvatar]: that takes a `User`, and a
/// [HouseholdMemberProgress] is not one — building a fake `User` to satisfy a
/// constructor would put an object in the tree that no repository ever
/// produced.
class _Initial extends StatelessWidget {
  final String name;
  final String userId;

  const _Initial({required this.name, required this.userId});

  @override
  Widget build(BuildContext context) {
    final color =
        Colors.primaries[userId.hashCode.abs() % Colors.primaries.length];

    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.18),
      ),
      alignment: Alignment.center,
      child: Text(
        name.characters.first.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color.shade700,
        ),
      ),
    );
  }
}

/// The joint savings goal and its per-member breakdown (PDR-018).
class _SavingsGoalBlock extends StatelessWidget {
  final HouseholdEconomyState state;
  const _SavingsGoalBlock({required this.state});

  @override
  Widget build(BuildContext context) {
    final goal = state.activeSavingsGoal;

    if (goal == null) {
      // UX-P1-SPEC §4 pairs this empty state with a CTA — «Elegid algo para
      // los dos» — which needs `POST /savings-goals`. That write is F4's, and
      // a button that did nothing would be worse than none, so the line
      // states the fact and stops there.
      return const Text(
        'Todavía no tenéis una meta conjunta.',
        style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                goal.isUnlocked ? 'Meta desbloqueada' : 'Meta conjunta',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Text(
              '${goal.contributedCoins}/${goal.targetCoins} 🪙',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: _coinAmber,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: goal.progress,
            minHeight: 8,
            backgroundColor: AppColors.divider,
            valueColor: const AlwaysStoppedAnimation<Color>(_coinAmber),
          ),
        ),
        if (goal.contributions.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            // «Tú: 40 · Ana: 28» (UX-P1-SPEC §4), in the cubit's order —
            // which is the order the contributions arrived in, never sorted
            // by amount.
            _breakdown(goal, state.currentUserId),
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }

  static String _breakdown(SavingsGoal goal, String? currentUserId) {
    return goal.contributions.map((c) {
      final name = c.userId == currentUserId
          ? 'Tú'
          : (c.name.isEmpty ? 'Miembro' : c.name);
      return '$name: ${c.amount}';
    }).join(' · ');
  }
}

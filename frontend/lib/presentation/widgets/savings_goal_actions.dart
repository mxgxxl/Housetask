import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../config/pet_config.dart';
import '../../config/theme.dart';
import '../../data/models/economy_p1/economy_p1.dart';
import '../cubit/economy_p1_cubit.dart';
import '../cubit/household_economy_cubit.dart';

/// The joint savings goal's write surfaces (TD-066 F4, PDR-018).
///
/// ── What is deliberately absent from every one of these ──────────────────
/// A price the client chooses. A goal saves toward a CATALOG item, and the
/// server looks its price up; the picker below sends `itemType`/`itemId` and
/// nothing else. If the client could name a `targetCoins`, a household would
/// unlock a 40 🪙 cosmetic by declaring the target to be 1 and the whole
/// economy's ceiling would be decorative.
///
/// The prices shown here come from [kCosmeticsCatalog], a hand-kept mirror of
/// the backend's — they are a preview, not an input. When the two drift the
/// server answers 400 and the cubit says «Ese artículo ya no está
/// disponible», which is the honest outcome; the fix is a catalog endpoint
/// (see the PR's Proposed Improvements).

/// «Elegid algo para los dos» (UX-P1-SPEC §4) — pick the item to save toward.
Future<void> showCreateSavingsGoalSheet(BuildContext context) {
  final cubit = context.read<HouseholdEconomyCubit>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BlocProvider<HouseholdEconomyCubit>.value(
      value: cubit,
      child: const _CreateGoalSheet(),
    ),
  );
}

class _CreateGoalSheet extends StatelessWidget {
  const _CreateGoalSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Elegid algo para los dos',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Aportáis por turnos hasta llegar al precio. Si canceláis la '
              'meta, cada uno recupera lo suyo.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            for (final cosmetic in kCosmeticsCatalog)
              _CatalogRow(cosmetic: cosmetic),
          ],
        ),
      ),
    );
  }
}

class _CatalogRow extends StatelessWidget {
  final Cosmetic cosmetic;
  const _CatalogRow({required this.cosmetic});

  @override
  Widget build(BuildContext context) {
    // `select` rather than a builder around the whole sheet: only the
    // in-flight flag can change while this is open, and only it should
    // rebuild these rows.
    final busy = context.select((HouseholdEconomyCubit c) => c.state.isCreatingGoal);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: OutlinedButton(
        onPressed: busy
            ? null
            : () {
                // The PRICE is not sent — see the library doc. Only which
                // item the household chose.
                context.read<HouseholdEconomyCubit>().createGoal(
                      itemType: 'cosmetic',
                      itemId: cosmetic.id,
                    );
                Navigator.of(context).pop();
              },
        child: Row(
          children: [
            Text(cosmetic.emoji, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                cosmetic.name,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Text(
              '${cosmetic.price} 🪙',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.priorityMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// «Aportar» — move coins from the personal wallet into [goal].
Future<void> showContributeDialog(BuildContext context, SavingsGoal goal) {
  final economy = context.read<EconomyP1Cubit>();
  return showDialog<void>(
    context: context,
    builder: (_) => BlocProvider<EconomyP1Cubit>.value(
      value: economy,
      child: _ContributeDialog(goal: goal),
    ),
  );
}

class _ContributeDialog extends StatefulWidget {
  final SavingsGoal goal;
  const _ContributeDialog({required this.goal});

  @override
  State<_ContributeDialog> createState() => _ContributeDialogState();
}

class _ContributeDialogState extends State<_ContributeDialog> {
  /// Null until the first frame reads the cubit's ceiling — the dialog opens
  /// on "everything I can give", which is the common intent and is always a
  /// legal value.
  int? _amount;

  @override
  Widget build(BuildContext context) {
    // The ceiling is the CUBIT's, not this widget's: it is the lower of the
    // wallet balance and what the goal still needs, and both halves of that
    // rule are economy policy (PDR-018), not presentation. A slider that
    // computed its own max would be a second place for «never overspend» to
    // be got wrong.
    final max = context.select(
      (EconomyP1Cubit c) => c.state.maxContributionFor(widget.goal),
    );
    final busy = context.select((EconomyP1Cubit c) => c.state.isContributing);
    final amount = (_amount ?? max).clamp(1, max < 1 ? 1 : max);

    return AlertDialog(
      title: const Text('Aportar a la meta'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Puedes aportar hasta $max 🪙.',
            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          Text(
            '$amount 🪙',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: AppColors.priorityMedium,
            ),
          ),
          if (max > 1)
            Slider(
              value: amount.toDouble(),
              min: 1,
              max: max.toDouble(),
              divisions: max - 1,
              label: '$amount',
              onChanged: busy
                  ? null
                  : (value) => setState(() => _amount = value.round()),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: busy || max < 1
              ? null
              : () {
                  context
                      .read<EconomyP1Cubit>()
                      .contributeToGoal(widget.goal, amount);
                  Navigator.of(context).pop();
                },
          child: const Text('Aportar'),
        ),
      ],
    );
  }
}

/// «Cancelar meta» — dissolve the goal and give everyone their coins back.
///
/// A confirmation, and an explicit one: UX-P1-SPEC §4 says «la confirmación
/// de cancelación avisa del reembolso», and it is the only action in P1 that
/// moves other people's money. The member tapping it may have contributed
/// nothing at all — an admin can cancel a goal someone else opened — so the
/// sentence names the effect on EVERYONE, not on them.
Future<void> showCancelSavingsGoalDialog(BuildContext context) {
  final cubit = context.read<HouseholdEconomyCubit>();
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('¿Cancelar la meta?'),
      content: const Text(
        'Esto reembolsará a todos los que aportaron. Cada persona recuperará '
        'exactamente lo que puso.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Volver'),
        ),
        // Destructive styling, and NOT the default action: the safe choice is
        // the one a stray tap should land on.
        TextButton(
          onPressed: () {
            cubit.cancelGoal();
            Navigator.of(dialogContext).pop();
          },
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
          child: const Text('Cancelar meta'),
        ),
      ],
    ),
  );
}

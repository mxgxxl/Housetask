import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../config/pet_config.dart';
import '../../config/theme.dart';
import '../cubit/pet_cubit.dart';
import '../widgets/common.dart';

/// Cosmetics shop (PDR-001 A3): balance header + the static catalog
/// (config/pet_config.dart — no catalog-listing endpoint exists yet, see
/// that file's doc comment), buy button gated on balance/ownership, and
/// "Usar" to set the pet's activeCosmetic.
class PetShopPage extends StatelessWidget {
  const PetShopPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tienda', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: BlocConsumer<PetCubit, PetState>(
        listenWhen: (previous, current) =>
            current.error != null && current.error != previous.error,
        listener: (context, state) => showSnack(context, state.error!, isError: true),
        builder: (context, state) {
          final pet = state.pet;
          if (pet == null) {
            return const Center(child: CircularProgressIndicator());
          }

          return Column(
            children: [
              _BalanceHeader(balance: state.economy.balance),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: kCosmeticsCatalog.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final cosmetic = kCosmeticsCatalog[index];
                    final owned = pet.cosmetics.contains(cosmetic.id);
                    final active = pet.activeCosmetic == cosmetic.id;
                    final canAfford = state.economy.balance >= cosmetic.price;

                    return _CosmeticTile(
                      cosmetic: cosmetic,
                      owned: owned,
                      active: active,
                      canAfford: canAfford,
                      busy: state.actionInProgress,
                      onBuy: () => context.read<PetCubit>().buyCosmetic(cosmetic.id),
                      onUse: () => context.read<PetCubit>().setActiveCosmetic(cosmetic.id),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BalanceHeader extends StatelessWidget {
  final num balance;
  const _BalanceHeader({required this.balance});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      color: AppColors.primary.withValues(alpha: 0.08),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('🪙', style: TextStyle(fontSize: 24)),
          const SizedBox(width: 8),
          Text(
            '$balance monedas',
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _CosmeticTile extends StatelessWidget {
  final Cosmetic cosmetic;
  final bool owned;
  final bool active;
  final bool canAfford;
  final bool busy;
  final VoidCallback onBuy;
  final VoidCallback onUse;

  const _CosmeticTile({
    required this.cosmetic,
    required this.owned,
    required this.active,
    required this.canAfford,
    required this.busy,
    required this.onBuy,
    required this.onUse,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Text(cosmetic.emoji, style: const TextStyle(fontSize: 32)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(cosmetic.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  const SizedBox(height: 4),
                  if (active)
                    const Pill(label: 'En uso', color: AppColors.priorityLow)
                  else
                    Text(
                      '${cosmetic.price} 🪙',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    ),
                ],
              ),
            ),
            if (!active)
              owned
                  ? OutlinedButton(
                      onPressed: busy ? null : onUse,
                      child: const Text('Usar'),
                    )
                  : ElevatedButton(
                      onPressed: (busy || !canAfford) ? null : onBuy,
                      child: const Text('Comprar'),
                    ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../config/pet_config.dart';
import '../../config/theme.dart';
import '../cubit/pet_cubit.dart';
import '../widgets/common.dart';
import 'pet_shop_page.dart';

/// Mascota tab (PDR-001 A3): adoption proposal/confirmation/cancellation,
/// the care view (feed/play with cooldown), and an entry point into the
/// cosmetics shop (pet_shop_page.dart) once the household has a pet.
class PetPage extends StatelessWidget {
  const PetPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PetCubit, PetState>(
      listenWhen: (previous, current) =>
          current.error != null && current.error != previous.error,
      listener: (context, state) => showSnack(context, state.error!, isError: true),
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Mascota',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
            actions: [
              if (state.status == PetStatusUi.hasPet)
                IconButton(
                  icon: const Icon(Icons.storefront_outlined),
                  tooltip: 'Tienda',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PetShopPage()),
                  ),
                ),
            ],
          ),
          body: switch (state.status) {
            PetStatusUi.initial ||
            PetStatusUi.loading =>
              const Center(child: CircularProgressIndicator()),
            PetStatusUi.error => EmptyState(
                icon: Icons.error_outline,
                title: state.error ?? 'No se pudo cargar la mascota',
                action: ElevatedButton(
                  onPressed: () => context.read<PetCubit>().refresh(),
                  child: const Text('Reintentar'),
                ),
              ),
            PetStatusUi.noPet => const _AdoptionProposalView(),
            PetStatusUi.pendingRequest => _PendingRequestView(state: state),
            PetStatusUi.hasPet => _CareView(state: state),
          },
        );
      },
    );
  }
}

class _SpeciesOption extends StatelessWidget {
  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SpeciesOption({
    required this.emoji,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 110,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.12) : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.divider,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 40)),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected ? AppColors.primary : AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdoptionProposalView extends StatefulWidget {
  const _AdoptionProposalView();

  @override
  State<_AdoptionProposalView> createState() => _AdoptionProposalViewState();
}

class _AdoptionProposalViewState extends State<_AdoptionProposalView> {
  String _species = 'cat';
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final actionInProgress = context.select((PetCubit c) => c.state.actionInProgress);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Adopten una mascota juntos',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Un miembro propone, el otro confirma.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _SpeciesOption(
                  emoji: kSpeciesEmoji['cat']!,
                  label: 'Gato',
                  selected: _species == 'cat',
                  onTap: () => setState(() => _species = 'cat'),
                ),
                const SizedBox(width: 16),
                _SpeciesOption(
                  emoji: kSpeciesEmoji['dog']!,
                  label: 'Perro',
                  selected: _species == 'dog',
                  onTap: () => setState(() => _species = 'dog'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Nombre de la mascota'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (_nameController.text.trim().isEmpty || actionInProgress)
                    ? null
                    : () => context.read<PetCubit>().proposeAdoption(
                          species: _species,
                          name: _nameController.text.trim(),
                        ),
                child: actionInProgress
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Proponer adopción'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingRequestView extends StatelessWidget {
  final PetState state;
  const _PendingRequestView({required this.state});

  @override
  Widget build(BuildContext context) {
    final request = state.pendingRequest!;
    final emoji = kSpeciesEmoji[request.species] ?? '🐾';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 64)),
            const SizedBox(height: 16),
            Text(
              request.name,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              state.requestedByMe
                  ? 'Esperando confirmación de tu pareja'
                  : '${request.name} está esperando tu confirmación',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            if (!state.requestedByMe)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: state.actionInProgress
                      ? null
                      : () => context.read<PetCubit>().confirmAdoption(),
                  child: const Text('Confirmar adopción'),
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed:
                    state.actionInProgress ? null : () => context.read<PetCubit>().cancelAdoption(),
                child: const Text('Cancelar'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// null when the action is available now, otherwise a short "Disponible en
/// N min" label computed from the last action time + the cooldown window.
/// Purely client-side (the backend's 409 has no "retry after" field) —
/// mirrors backend/src/config/economy.ts's FEED_COOLDOWN_HOURS/
/// PLAY_COOLDOWN_HOURS via config/pet_config.dart.
String? cooldownRemainingLabel(DateTime? lastAt, int cooldownHours) {
  if (lastAt == null) return null;
  final readyAt = lastAt.add(Duration(hours: cooldownHours));
  final remaining = readyAt.difference(DateTime.now());
  if (remaining.inSeconds <= 0) return null;
  final minutes = (remaining.inSeconds / 60).ceil();
  return 'Disponible en $minutes min';
}

/// Look up a catalog Cosmetic by id, or null (never adopted / unknown id).
Cosmetic? _cosmeticById(String? id) {
  if (id == null) return null;
  for (final cosmetic in kCosmeticsCatalog) {
    if (cosmetic.id == id) return cosmetic;
  }
  return null;
}

class _StatBar extends StatelessWidget {
  final String label;
  final num value;
  const _StatBar({required this.label, required this.value});

  Color get _color {
    if (value >= 60) return AppColors.priorityLow;
    if (value >= 30) return AppColors.priorityMedium;
    return AppColors.priorityHigh;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            Text('${value.round()}%',
                style: TextStyle(fontWeight: FontWeight.w700, color: _color)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: value.clamp(0, 100) / 100,
            minHeight: 10,
            backgroundColor: AppColors.divider,
            valueColor: AlwaysStoppedAnimation<Color>(_color),
          ),
        ),
      ],
    );
  }
}

class _CareButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final String? disabledText;
  final bool enabled;
  final VoidCallback onPressed;

  const _CareButton({
    required this.label,
    required this.icon,
    required this.disabledText,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: enabled ? onPressed : null,
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
        ),
        if (disabledText != null) ...[
          const SizedBox(height: 4),
          Text(disabledText!,
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        ],
      ],
    );
  }
}

class _CareView extends StatelessWidget {
  final PetState state;
  const _CareView({required this.state});

  @override
  Widget build(BuildContext context) {
    final pet = state.pet!;
    final emoji = kSpeciesEmoji[pet.species] ?? '🐾';
    final feedRemaining = cooldownRemainingLabel(pet.lastFedAt, kFeedCooldownHours);
    final playRemaining = cooldownRemainingLabel(pet.lastPlayedAt, kPlayCooldownHours);
    final activeCosmetic = _cosmeticById(pet.activeCosmetic);

    return RefreshIndicator(
      onRefresh: () => context.read<PetCubit>().refresh(),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(child: Text(emoji, style: const TextStyle(fontSize: 96))),
          if (activeCosmetic != null) ...[
            const SizedBox(height: 4),
            Center(
              child: Text(
                '${activeCosmetic.emoji} ${activeCosmetic.name}',
                style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Center(
            child: Text(
              pet.name,
              style: const TextStyle(
                  fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: 24),
          _StatBar(label: 'Hambre', value: pet.hunger),
          const SizedBox(height: 12),
          _StatBar(label: 'Ánimo', value: pet.mood),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _CareButton(
                  label: 'Alimentar',
                  icon: Icons.restaurant,
                  disabledText: feedRemaining,
                  enabled: feedRemaining == null && !state.actionInProgress,
                  onPressed: () => context.read<PetCubit>().feed(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _CareButton(
                  label: 'Jugar',
                  icon: Icons.sports_esports,
                  disabledText: playRemaining,
                  enabled: playRemaining == null && !state.actionInProgress,
                  onPressed: () => context.read<PetCubit>().play(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

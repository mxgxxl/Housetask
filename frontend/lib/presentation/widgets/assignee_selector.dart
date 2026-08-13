import 'package:flutter/material.dart';
import '../../config/theme.dart';
import '../../data/models/user.dart';
import 'user_avatar.dart';

/// Household-member picker for task assignment.
///
/// Renders one chip per member — avatar (deterministic color by userId) plus
/// name — and a leading "Sin asignar" chip that clears the selection.
class AssigneeSelector extends StatelessWidget {
  final List<User> users;
  final Set<String> selectedIds;
  final void Function(String id) onToggle;
  final VoidCallback onClearAll;

  const AssigneeSelector({
    super.key,
    required this.users,
    required this.selectedIds,
    required this.onToggle,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    if (users.isEmpty) {
      return const Text('No hay miembros en el hogar',
          style: TextStyle(color: AppColors.textSecondary));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilterChip(
          label: const Text('Sin asignar'),
          selected: selectedIds.isEmpty,
          onSelected: (_) => onClearAll(),
          selectedColor: AppColors.textSecondary.withValues(alpha: 0.18),
          checkmarkColor: AppColors.textSecondary,
        ),
        for (final u in users)
          FilterChip(
            avatar: UserAvatar(user: u, size: 22),
            label: Text(u.name.isEmpty ? u.email : u.name),
            selected: selectedIds.contains(u.id),
            onSelected: (_) => onToggle(u.id),
            selectedColor: AppColors.primary.withValues(alpha: 0.16),
            checkmarkColor: AppColors.primary,
          ),
      ],
    );
  }
}

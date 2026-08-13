import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
import '../../core/utils/ui_helpers.dart';
import '../../data/models/task.dart';
import '../../data/models/user.dart';
import '../cubit/household_cubit.dart';
import 'user_avatar.dart';

/// A single task row: completion checkbox, title, category, due date,
/// assignees, and a priority indicator.
class TaskTile extends StatelessWidget {
  final Task task;
  final VoidCallback? onToggle;
  final VoidCallback? onTap;

  const TaskTile({super.key, required this.task, this.onToggle, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = priorityColor(task.priority);
    final overdue = task.dueDate != null &&
        !task.isCompleted &&
        task.dueDate!.isBefore(DateTime.now());
    // isDeleted implies isSynced == false (TaskRepository sets both together
    // for an offline delete), so the strike-through and the pending-sync
    // indicator below combine naturally: the row reads as "queued to be
    // removed once back online".
    final struckThrough = task.isCompleted || task.isDeleted;

    // A completer who is no longer a household member (TD-018) still has a
    // valid User document — the id just no longer appears in the current
    // members list — so "current member" is decided here, not by a null
    // name/email.
    String? completedByLabel;
    User? completedByAvatarUser;
    final completedBy = task.completedBy;
    if (task.isCompleted && completedBy != null) {
      final members = context.watch<HouseholdCubit>().state.current?.members ?? const [];
      final isCurrentMember = members.any((m) => m.user.id == completedBy.id);
      completedByLabel = isCurrentMember
          ? (completedBy.name.isEmpty ? completedBy.email : completedBy.name)
          : 'Ex-miembro';
      completedByAvatarUser =
          isCurrentMember ? completedBy : User(id: completedBy.id, email: '', name: '');
    }

    return Opacity(
      opacity: task.isDeleted ? 0.5 : 1,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                // Priority stripe.
                Container(
                  width: 4,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 10),
                // Completion checkbox.
                GestureDetector(
                  onTap: onToggle,
                  child: Icon(
                    task.isCompleted
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: task.isCompleted
                        ? AppColors.priorityLow
                        : AppColors.textSecondary,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          decoration:
                              struckThrough ? TextDecoration.lineThrough : null,
                          color: struckThrough
                              ? AppColors.textSecondary
                              : AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(taskCategoryIcon(task.category),
                              size: 13, color: AppColors.textSecondary),
                          const SizedBox(width: 4),
                          Icon(Icons.event,
                              size: 13,
                              color: overdue
                                  ? AppColors.error
                                  : AppColors.textSecondary),
                          const SizedBox(width: 3),
                          Text(
                            formatDueDate(task.dueDate),
                            style: TextStyle(
                              fontSize: 12,
                              color: overdue
                                  ? AppColors.error
                                  : AppColors.textSecondary,
                              fontWeight:
                                  overdue ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                          if (task.isRecurring) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.repeat,
                                size: 13, color: AppColors.secondary),
                          ],
                          if (!task.isSynced) ...[
                            const SizedBox(width: 6),
                            const _PendingSyncIndicator(),
                          ],
                        ],
                      ),
                      if (completedByLabel != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            UserAvatar(user: completedByAvatarUser!, size: 16),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'Completada por $completedByLabel',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AvatarStack(users: task.assignedTo, size: 26),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small cloud-with-spinner glyph for a task/item created, edited, or deleted
/// offline (TD-003) and still waiting for TaskCubit/ShoppingCubit.syncPending
/// to replay it against the server.
class _PendingSyncIndicator extends StatelessWidget {
  const _PendingSyncIndicator();

  @override
  Widget build(BuildContext context) {
    return const Tooltip(
      message: 'Pendiente de sincronizar',
      child: SizedBox(
        width: 26,
        height: 13,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Icon(Icons.cloud_queue, size: 13, color: AppColors.secondary),
            Positioned(
              right: 0,
              child: SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.secondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

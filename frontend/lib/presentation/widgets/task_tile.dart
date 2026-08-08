import 'package:flutter/material.dart';
import '../../config/theme.dart';
import '../../core/utils/ui_helpers.dart';
import '../../data/models/task.dart';
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

    return Card(
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
                  color: task.isCompleted ? AppColors.priorityLow : AppColors.textSecondary,
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
                            task.isCompleted ? TextDecoration.lineThrough : null,
                        color: task.isCompleted
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
                            color: overdue ? AppColors.error : AppColors.textSecondary),
                        const SizedBox(width: 3),
                        Text(
                          formatDueDate(task.dueDate),
                          style: TextStyle(
                            fontSize: 12,
                            color: overdue ? AppColors.error : AppColors.textSecondary,
                            fontWeight: overdue ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        if (task.isRecurring) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.repeat,
                              size: 13, color: AppColors.secondary),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AvatarStack(users: task.assignedTo, size: 26),
            ],
          ),
        ),
      ),
    );
  }
}

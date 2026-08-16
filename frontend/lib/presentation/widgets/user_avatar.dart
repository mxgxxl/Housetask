import 'package:flutter/material.dart';
import '../../config/theme.dart';
import '../../data/models/user.dart';

/// Circular avatar showing the user's image or their initials.
class UserAvatar extends StatelessWidget {
  final User user;
  final double size;

  const UserAvatar({super.key, required this.user, this.size = 32});

  @override
  Widget build(BuildContext context) {
    final hasImage = user.avatarUrl != null && user.avatarUrl!.isNotEmpty;
    // Derive a stable-ish color from the user id.
    final color = Colors.primaries[user.id.hashCode.abs() % Colors.primaries.length];

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.18),
        image: hasImage
            ? DecorationImage(image: NetworkImage(user.avatarUrl!), fit: BoxFit.cover)
            : null,
      ),
      alignment: Alignment.center,
      child: hasImage
          ? null
          : Text(
              user.initials,
              style: TextStyle(
                fontSize: size * 0.38,
                fontWeight: FontWeight.w700,
                color: color.shade700,
              ),
            ),
    );
  }
}

/// A row of overlapping avatars for assigned members.
///
/// TD-018: an assignee can be a former member — either they left/were
/// removed from the household (their id is no longer in [formerMemberIds],
/// computed by the caller from the current member list) or their ref never
/// populated at all (empty name AND email, e.g. a hard-deleted account).
/// Either case renders a neutral placeholder avatar with an "Ex-miembro"
/// tooltip instead of the normal name-initials avatar, same label
/// [TaskTile] already uses for a former `completedBy` (PDR-002).
class AvatarStack extends StatelessWidget {
  final List<User> users;
  final double size;
  final int max;
  final Set<String> formerMemberIds;

  const AvatarStack({
    super.key,
    required this.users,
    this.size = 28,
    this.max = 3,
    this.formerMemberIds = const {},
  });

  bool _isFormerMember(User user) =>
      (user.name.isEmpty && user.email.isEmpty) || formerMemberIds.contains(user.id);

  @override
  Widget build(BuildContext context) {
    if (users.isEmpty) {
      return Icon(Icons.person_off_outlined, size: size * 0.7, color: AppColors.textSecondary);
    }
    final shown = users.take(max).toList();
    final overflow = users.length - shown.length;

    return SizedBox(
      height: size,
      width: size + (shown.length - 1) * size * 0.6 + (overflow > 0 ? size * 0.6 : 0),
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * size * 0.6,
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surface,
                ),
                padding: const EdgeInsets.all(1.5),
                child: _isFormerMember(shown[i])
                    ? Tooltip(
                        message: 'Ex-miembro',
                        child: CircleAvatar(
                          radius: size / 2,
                          backgroundColor: AppColors.textSecondary.withValues(alpha: 0.18),
                          child: Icon(
                            Icons.person_outline,
                            size: size * 0.6,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      )
                    : UserAvatar(user: shown[i], size: size),
              ),
            ),
          if (overflow > 0)
            Positioned(
              left: shown.length * size * 0.6,
              child: CircleAvatar(
                radius: size / 2,
                backgroundColor: AppColors.divider,
                child: Text(
                  '+$overflow',
                  style: const TextStyle(fontSize: 11, color: AppColors.textPrimary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

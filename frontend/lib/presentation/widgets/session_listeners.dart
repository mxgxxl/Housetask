import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../config/routes.dart';
import '../../services/notification_service.dart';
import '../cubit/auth_cubit.dart';
import '../cubit/economy_p1_cubit.dart';
import '../cubit/household_cubit.dart';
import '../cubit/pet_cubit.dart';
import '../cubit/shopping_cubit.dart';
import '../cubit/socket_cubit.dart';
import '../cubit/stats_cubit.dart';
import '../cubit/task_cubit.dart';

/// App-wide reactions to [AuthCubit] state transitions, wrapping [child]
/// (the MaterialApp in app.dart). Two independent concerns share this widget
/// because both react to the same cubit and both must outlive any single
/// page — a per-page `BlocListener` only fires while that page is mounted,
/// which is exactly what made TD-055 possible (see below).
///
/// - `authenticated` → registers this device for push notifications
///   (PDR-008). [NotificationService] itself no-ops past the first
///   successful call, so repeated `authenticated` emissions (e.g. a profile
///   update) don't re-request permission or double-subscribe listeners.
/// - `unauthenticated` → session-lifecycle teardown (TD-055/TD-058):
///   disconnects the socket, resets every domain cubit, and routes to
///   login via [Routes.navigatorKey] — regardless of which page happens to
///   be on screen when an explicit logout or an unrecoverable refresh
///   failure (`ApiService.onSessionExpired`) occurs. Lives at this level
///   rather than inside AuthCubit itself: AuthCubit is constructed before
///   the domain cubits it would need to reach (see app.dart's provider
///   order), and this mirrors the existing pattern of pages coordinating
///   cross-cubit actions via `context.read` (SplashPage/LoginPage's
///   post-auth setup) rather than cubits holding direct references to
///   each other.
///
/// Extracted from app.dart into its own widget so a test can exercise this
/// logic directly against fake cubits, instead of standing up the real
/// composition root's network/storage dependencies just to prove routing
/// and cleanup happen on session end.
class SessionListeners extends StatelessWidget {
  final NotificationService notifications;
  final Widget child;

  const SessionListeners({
    super.key,
    required this.notifications,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<AuthCubit, AuthState>(
          listenWhen: (previous, current) =>
              current.status == AuthStatus.authenticated,
          listener: (context, state) => notifications.initPushNotifications(),
        ),
        BlocListener<AuthCubit, AuthState>(
          listenWhen: (previous, current) =>
              previous.status != current.status &&
              current.status == AuthStatus.unauthenticated,
          listener: (context, state) {
            context.read<SocketCubit>().disconnect();
            context.read<HouseholdCubit>().reset();
            context.read<TaskCubit>().reset();
            context.read<ShoppingCubit>().reset();
            context.read<PetCubit>().reset();
            context.read<StatsCubit>().reset();
            // TD-066 F2: a wallet, a streak and a level are personal data —
            // leaving them on screen for the next account is the same leak
            // TD-058 closed for tasks and shopping.
            context.read<EconomyP1Cubit>().reset();
            Routes.navigatorKey.currentState
                ?.pushNamedAndRemoveUntil(Routes.login, (route) => false);
          },
        ),
      ],
      child: child,
    );
  }
}

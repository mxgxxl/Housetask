import 'package:flutter/material.dart';
import '../presentation/pages/splash_page.dart';
import '../presentation/pages/login_page.dart';
import '../presentation/pages/register_page.dart';
import '../presentation/pages/main_scaffold.dart';

/// Named routes for the auth + shell flow. Feature forms are pushed directly
/// with MaterialPageRoute so they can receive typed constructor arguments.
class Routes {
  Routes._();

  /// Lets NotificationService navigate on a push-notification tap (PDR-008)
  /// without needing a BuildContext of its own — it runs from a top-level
  /// FirebaseMessaging listener, not from inside the widget tree.
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  static const String splash = '/';
  static const String login = '/login';
  static const String register = '/register';
  static const String main = '/main';

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case splash:
        return _page(const SplashPage());
      case login:
        return _page(const LoginPage());
      case register:
        return _page(const RegisterPage());
      case main:
        return _page(const MainScaffold());
      default:
        return _page(const SplashPage());
    }
  }

  static MaterialPageRoute<dynamic> _page(Widget child) =>
      MaterialPageRoute(builder: (_) => child);
}

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/routes.dart';
import '../../config/theme.dart';
import '../cubit/auth_cubit.dart';
import '../cubit/household_cubit.dart';
import '../cubit/socket_cubit.dart';

/// Decides the initial destination: checks for a valid session, then routes to
/// the main shell or the login screen.
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthCubit>().checkAuth();
    });
  }

  Future<void> _onAuthenticated() async {
    final auth = context.read<AuthCubit>();
    final user = auth.state.user;
    if (user == null) return;

    await context.read<HouseholdCubit>().init(user);
    await context.read<SocketCubit>().connectAndListen();

    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(Routes.main);
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AuthCubit, AuthState>(
      listenWhen: (prev, curr) => prev.status != curr.status,
      listener: (context, state) {
        if (state.status == AuthStatus.authenticated) {
          _onAuthenticated();
        } else if (state.status == AuthStatus.unauthenticated) {
          Navigator.of(context).pushReplacementNamed(Routes.login);
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.primary,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(Icons.home_rounded, color: Colors.white, size: 44),
              ),
              const SizedBox(height: 20),
              const Text(
                'HomeSync',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 24),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

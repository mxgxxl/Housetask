import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
import '../cubit/household_cubit.dart';
import '../cubit/socket_cubit.dart';
import '../widgets/common.dart';

/// Shown when the user belongs to no household yet: create one or join with a
/// code. Also reachable from Profile to add another household.
class HouseholdSetupPage extends StatefulWidget {
  /// When true this is presented as a pushed page (with a back button) rather
  /// than the root shell.
  final bool asPage;

  const HouseholdSetupPage({super.key, this.asPage = false});

  @override
  State<HouseholdSetupPage> createState() => _HouseholdSetupPageState();
}

class _HouseholdSetupPageState extends State<HouseholdSetupPage> {
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    final household = await context.read<HouseholdCubit>().createHousehold(name);
    if (household != null && mounted) {
      context.read<SocketCubit>().joinHousehold(household.id);
      if (widget.asPage) Navigator.of(context).pop();
    }
  }

  Future<void> _join() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) return;
    final household = await context.read<HouseholdCubit>().joinHousehold(code);
    if (household != null && mounted) {
      context.read<SocketCubit>().joinHousehold(household.id);
      if (widget.asPage) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.asPage ? AppBar(title: const Text('Añadir hogar')) : null,
      body: SafeArea(
        child: BlocConsumer<HouseholdCubit, HouseholdState>(
          listenWhen: (p, c) => p.error != c.error && c.error != null,
          listener: (context, state) => showSnack(context, state.error!, isError: true),
          builder: (context, state) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!widget.asPage) ...[
                    const SizedBox(height: 24),
                    const Icon(Icons.home_work_outlined,
                        size: 56, color: AppColors.primary),
                    const SizedBox(height: 16),
                    const Text(
                      'Configura tu hogar',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Crea un hogar nuevo o únete a uno con un código',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 32),
                  ],
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('Crear un hogar',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _nameCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Nombre del hogar',
                              hintText: 'Ej: Nuestro piso',
                            ),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: state.loading ? null : _create,
                            icon: const Icon(Icons.add_home_outlined),
                            label: const Text('Crear hogar'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: const [
                      Expanded(child: Divider()),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('o', style: TextStyle(color: AppColors.textSecondary)),
                      ),
                      Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('Unirse a un hogar',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _codeCtrl,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'Código de invitación',
                              hintText: 'Ej: HOME1234',
                            ),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: state.loading ? null : _join,
                            icon: const Icon(Icons.group_add_outlined),
                            label: const Text('Unirse'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

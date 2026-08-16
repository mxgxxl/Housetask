import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
import '../../data/models/household_stats.dart';
import '../../data/models/user.dart';
import '../cubit/household_cubit.dart';
import '../cubit/stats_cubit.dart';
import '../widgets/common.dart';
import '../widgets/user_avatar.dart';

/// Household stats screen (PDR-007): completion rate, top completer and a
/// per-member breakdown with proportional bars — the seed for future
/// retention features. Reached from Profile's AppBar (bar_chart icon).
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  @override
  void initState() {
    super.initState();
    final householdId = context.read<HouseholdCubit>().currentId;
    if (householdId != null) {
      context.read<StatsCubit>().load(householdId);
    }
  }

  void _onPeriodChanged(StatsPeriod period) {
    final householdId = context.read<HouseholdCubit>().currentId;
    if (householdId != null) {
      context.read<StatsCubit>().load(householdId, period: period);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Estadísticas',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: BlocBuilder<StatsCubit, StatsState>(
        builder: (context, state) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _PeriodToggle(period: state.period, onChanged: _onPeriodChanged),
              const SizedBox(height: 16),
              if (state.status == StatsStatusUi.loading && state.stats == null)
                const Padding(
                  padding: EdgeInsets.only(top: 60),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (state.status == StatsStatusUi.error && state.stats == null)
                EmptyState(
                  icon: Icons.error_outline,
                  title: 'No se pudieron cargar las estadísticas',
                  subtitle: state.error,
                )
              else if (state.stats != null) ...[
                _CompletionRateCard(stats: state.stats!),
                const SizedBox(height: 16),
                _TopCompleterCard(topCompleter: state.stats!.topCompleter),
                const SizedBox(height: 20),
                const Text('Reparto por miembro',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 8),
                _MemberStatsList(memberStats: state.stats!.memberStats),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _PeriodToggle extends StatelessWidget {
  final StatsPeriod period;
  final ValueChanged<StatsPeriod> onChanged;

  const _PeriodToggle({required this.period, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<StatsPeriod>(
      key: const Key('statsPeriodSelector'),
      segments: const [
        ButtonSegment(value: StatsPeriod.last30days, label: Text('30 días')),
        ButtonSegment(value: StatsPeriod.allTime, label: Text('Todo')),
      ],
      selected: {period},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

class _CompletionRateCard extends StatelessWidget {
  final HouseholdStats stats;

  const _CompletionRateCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Tasa de completado',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text(
                    '${stats.completionRate.toStringAsFixed(1)}%',
                    style: const TextStyle(
                        fontSize: 32, fontWeight: FontWeight.w800, color: AppColors.primary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${stats.completedTasks} de ${stats.totalTasks} tareas',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 64,
              height: 64,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: (stats.completionRate / 100).clamp(0, 1),
                    strokeWidth: 7,
                    backgroundColor: AppColors.divider,
                    color: AppColors.primary,
                  ),
                  const Center(
                    child: Icon(Icons.check_circle_outline, color: AppColors.primary, size: 26),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopCompleterCard extends StatelessWidget {
  final TopCompleter? topCompleter;

  const _TopCompleterCard({required this.topCompleter});

  @override
  Widget build(BuildContext context) {
    final top = topCompleter;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.emoji_events_outlined, color: AppColors.secondary, size: 28),
            const SizedBox(width: 12),
            if (top == null)
              const Expanded(
                child: Text('Nadie ha completado tareas todavía',
                    style: TextStyle(color: AppColors.textSecondary)),
              )
            else ...[
              UserAvatar(
                user: User(id: top.userId, email: '', name: top.userName),
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Quien más completa',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    Text(top.userName,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  ],
                ),
              ),
              Text('${top.completed}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
            ],
          ],
        ),
      ),
    );
  }
}

class _MemberStatsList extends StatelessWidget {
  final List<MemberStat> memberStats;

  const _MemberStatsList({required this.memberStats});

  @override
  Widget build(BuildContext context) {
    if (memberStats.isEmpty) {
      return const EmptyState(
        icon: Icons.bar_chart,
        title: 'Sin datos todavía',
      );
    }
    final maxCompleted = memberStats
        .map((m) => m.completed)
        .fold<int>(0, (max, v) => v > max ? v : max);

    return Column(
      children: memberStats
          .map((m) => _MemberStatRow(memberStat: m, maxCompleted: maxCompleted))
          .toList(),
    );
  }
}

class _MemberStatRow extends StatelessWidget {
  final MemberStat memberStat;
  final int maxCompleted;

  const _MemberStatRow({required this.memberStat, required this.maxCompleted});

  @override
  Widget build(BuildContext context) {
    final ratio = maxCompleted > 0 ? memberStat.completed / maxCompleted : 0.0;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            UserAvatar(
              user: User(
                id: memberStat.userId,
                email: '',
                name: memberStat.userName,
                avatarUrl: memberStat.avatarUrl,
              ),
              size: 40,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(memberStat.userName,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 6,
                      backgroundColor: AppColors.divider,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${memberStat.completed} completadas · ${memberStat.created} creadas',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

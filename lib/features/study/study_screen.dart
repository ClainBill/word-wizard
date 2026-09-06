import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/study_dashboard.dart';

class StudyScreen extends ConsumerWidget {
  const StudyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(studyStatsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Study'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Manage study words',
            onPressed: () => context.push('/study/manage'),
          ),
        ],
      ),
      body: statsAsync.when(
        data: (stats) => _Dashboard(stats: stats),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load stats: $e')),
      ),
    );
  }
}

class _Dashboard extends ConsumerWidget {
  final StudyDashboardStats stats;

  const _Dashboard({required this.stats});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (stats.total == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.school_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'Nothing to study yet',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Add words to study from any dictionary entry via its\n"Study" button, or from a list via its play button.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final streakAsync = ref.watch(studyStreakProvider);
    final forecastAsync = ref.watch(studyForecastProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        streakAsync.maybeWhen(
          data: (streak) => streak > 0 ? _StreakBanner(days: streak) : const SizedBox.shrink(),
          orElse: () => const SizedBox.shrink(),
        ),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                label: 'Due today',
                value: stats.dueToday,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatTile(
                label: 'Mastered',
                value: stats.mastered,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatTile(
                label: 'In progress',
                value: stats.learning + stats.reviewing,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        Text('Next 14 days', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 12),
        forecastAsync.maybeWhen(
          data: (forecast) => _ForecastChart(counts: forecast),
          orElse: () => const SizedBox(height: 64),
        ),
        const SizedBox(height: 32),
        Center(
          child: FilledButton.icon(
            onPressed: stats.dueToday == 0 ? null : () => context.push('/study/session'),
            icon: const Icon(Icons.play_arrow),
            label: Text(stats.dueToday == 0 ? 'Nothing due right now' : 'Start session'),
          ),
        ),
      ],
    );
  }
}

class _StreakBanner extends StatelessWidget {
  final int days;

  const _StreakBanner({required this.days});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Text('🔥', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Text(
            '$days-day streak',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _StatTile({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Column(
          children: [
            Text(
              '$value',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ForecastChart extends StatelessWidget {
  final List<int> counts;

  const _ForecastChart({required this.counts});

  @override
  Widget build(BuildContext context) {
    final maxCount = counts.fold(0, (m, c) => c > m ? c : m);
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: 72,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < counts.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Tooltip(
                  message: i == 0
                      ? 'Today: ${counts[i]}'
                      : 'In $i day${i == 1 ? '' : 's'}: ${counts[i]}',
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        height: maxCount == 0 ? 4 : 4 + (counts[i] / maxCount) * 48,
                        decoration: BoxDecoration(
                          color: i == 0 ? scheme.primary : scheme.primary.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

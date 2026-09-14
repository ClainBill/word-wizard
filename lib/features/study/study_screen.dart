import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/progress.dart';
import '../../domain/models/study_dashboard.dart';
import '../progress/progress_bar.dart';
import '../progress/progress_format.dart';
import 'study_options_sheet.dart';

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
            tooltip: 'Study options',
            onPressed: () => showStudyOptionsSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.list_alt),
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
    final overview = ref.watch(progressOverviewProvider).valueOrNull;
    // Words sitting in lists are progress too — the bar shows them as the
    // grey stretch still to be studied — so the empty state is only for a
    // user with nothing anywhere.
    if (stats.total == 0 && (overview == null || overview.total == 0)) {
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
        if (overview != null) _ProgressCard(overview: overview),
        streakAsync.maybeWhen(
          data: (streak) => streak > 0 ? _StreakBanner(days: streak) : const SizedBox.shrink(),
          orElse: () => const SizedBox.shrink(),
        ),
        _StatTile(
          label: stats.dueToday == 1 ? 'card due today' : 'cards due today',
          value: stats.dueToday,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 12),
        // The direction setting silently doubles or halves the daily load,
        // so it belongs next to the numbers it moves rather than buried in
        // the sheet that changes it.
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => showStudyOptionsSheet(context),
            icon: const Icon(Icons.swap_horiz, size: 16),
            label: Text(
              ref.watch(studyDirectionModeProvider).valueOrNull?.label ?? '…',
              style: const TextStyle(fontSize: 12),
            ),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ),
        const SizedBox(height: 16),
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

/// The headline and the bar. Tapping anywhere on it opens the full
/// progress screen — the card is the summary, not the destination.
class _ProgressCard extends StatelessWidget {
  final ProgressOverview overview;

  const _ProgressCard({required this.overview});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/study/progress'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    formatCount(overview.mastered),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      overview.mastered == 1 ? 'word mastered' : 'words mastered',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    '${formatCount(overview.total)} words',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 20, color: scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 12),
              ProgressSegmentsBar(overview: overview),
              const SizedBox(height: 10),
              ProgressLegend(overview: overview),
            ],
          ),
        ),
      ),
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
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$value',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
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

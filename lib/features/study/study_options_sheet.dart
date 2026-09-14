import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/study_direction.dart';
import '../../domain/srs/sm2.dart';

/// How far into a session the user is, when the sheet is opened from one.
/// Null on the Study dashboard, where there's no session to report on.
typedef StudySessionProgress = ({int done, int total, Map<Grade, int> grades});

/// The SRS control panel, pulled up from the bottom — either by tapping the
/// progress bar mid-session or from the Study tab.
///
/// It deliberately puts the *settings* and the *state* on one surface: the
/// question "should I be studying both ways?" is unanswerable without seeing
/// what the current setting is already costing you per day, so the direction
/// picker sits directly above the forecast it changes.
Future<void> showStudyOptionsSheet(
  BuildContext context, {
  StudySessionProgress? progress,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _StudyOptionsSheet(progress: progress),
  );
}

class _StudyOptionsSheet extends ConsumerWidget {
  final StudySessionProgress? progress;

  const _StudyOptionsSheet({this.progress});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final mode = ref.watch(studyDirectionModeProvider).valueOrNull;
    final statsAsync = ref.watch(studyStatsProvider);
    final forecastAsync = ref.watch(studyForecastProvider);
    final streakAsync = ref.watch(studyStreakProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Row(
            children: [
              Text('Study options', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              streakAsync.maybeWhen(
                data: (streak) => streak == 0
                    ? const SizedBox.shrink()
                    : Text('🔥 $streak', style: Theme.of(context).textTheme.titleMedium),
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 16),
            _SessionProgressBlock(progress: progress!),
          ],
          const SizedBox(height: 24),
          Text('Which way round', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            'Each direction is scheduled on its own — a word you can read '
            'instantly may still be one you cannot produce, so the two are '
            'reviewed separately.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          if (mode == null)
            const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
          else
            for (final option in StudyDirectionMode.values)
              _DirectionOption(
                mode: option,
                selected: option == mode,
                onTap: option == mode ? null : () => _select(context, ref, option),
              ),
          const SizedBox(height: 24),
          Text('Where you are', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 10),
          statsAsync.when(
            data: (stats) => Column(
              children: [
                Row(
                  children: [
                    Expanded(child: _MiniStat(label: 'Due now', value: '${stats.dueToday}')),
                    const SizedBox(width: 8),
                    Expanded(child: _MiniStat(label: 'Mastered', value: '${stats.mastered}')),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MiniStat(
                        label: 'In progress',
                        value: '${stats.learning + stats.reviewing}',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: _MiniStat(label: 'Words', value: '${stats.total}')),
                  ],
                ),
                if (mode == StudyDirectionMode.both) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Counts above are cards. ${stats.total} word'
                    '${stats.total == 1 ? '' : 's'}, studied both ways, is up to '
                    '${stats.total * 2} cards.',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
            loading: () => const SizedBox(height: 56),
            error: (e, _) => Text('Couldn\'t load stats: $e'),
          ),
          const SizedBox(height: 20),
          Text('Next 14 days', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 10),
          forecastAsync.maybeWhen(
            data: (forecast) => _ForecastStrip(counts: forecast),
            orElse: () => const SizedBox(height: 72),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.tune),
            label: const Text('Manage study words'),
            onPressed: () {
              Navigator.of(context).pop();
              context.push('/study/manage');
            },
          ),
        ],
      ),
    );
  }

  Future<void> _select(BuildContext context, WidgetRef ref, StudyDirectionMode mode) async {
    await ref.read(settingsRepositoryProvider).setStudyDirectionMode(mode);
    // Backfills the cards the newly-enabled direction needs for words
    // already in the pool. Turning a direction *off* deliberately writes
    // nothing: those cards keep their history and simply stop being queued.
    await ref.read(studyRepositoryProvider).syncDirections(mode.directions);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          mode == StudyDirectionMode.both
              ? 'Studying both ways. New reverse cards arrive with each word\'s next review, '
                  'not all at once.'
              : 'Studying ${mode.label.toLowerCase()}. Cards in the other direction keep their '
                  'progress and stop appearing.',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }
}

class _SessionProgressBlock extends StatelessWidget {
  final StudySessionProgress progress;

  const _SessionProgressBlock({required this.progress});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final remaining = progress.total - progress.done;
    final graded = progress.grades.values.fold(0, (a, b) => a + b);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This session',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurface),
          ),
          const SizedBox(height: 6),
          Text(
            '${progress.done} of ${progress.total} done · $remaining to go',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress.total == 0 ? 0 : progress.done / progress.total,
              minHeight: 6,
            ),
          ),
          if (graded > 0) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final grade in Grade.values)
                  if ((progress.grades[grade] ?? 0) > 0)
                    _GradePill(grade: grade, count: progress.grades[grade]!),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _GradePill extends StatelessWidget {
  final Grade grade;
  final int count;

  const _GradePill({required this.grade, required this.count});

  @override
  Widget build(BuildContext context) {
    final color = switch (grade) {
      Grade.again => Colors.red,
      Grade.hard => Colors.orange,
      Grade.good => Colors.green,
      Grade.easy => Colors.teal,
    };
    final label = switch (grade) {
      Grade.again => 'Again',
      Grade.hard => 'Hard',
      Grade.good => 'Good',
      Grade.easy => 'Easy',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('$label $count', style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

class _DirectionOption extends StatelessWidget {
  final StudyDirectionMode mode;
  final bool selected;
  final VoidCallback? onTap;

  const _DirectionOption({required this.mode, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: 0.08) : null,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode.label,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: selected ? scheme.primary : null,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      mode.description,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;

  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ForecastStrip extends StatelessWidget {
  final List<int> counts;

  const _ForecastStrip({required this.counts});

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
                  message: i == 0 ? 'Today: ${counts[i]}' : 'In $i day${i == 1 ? '' : 's'}: ${counts[i]}',
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

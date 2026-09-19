import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../domain/crossword/crossword_models.dart';
import '../../domain/models/progress.dart';
import 'progress_bar.dart';
import 'progress_format.dart';

/// Everything the app has counted, in units.
///
/// Laid out as the areas of the app rather than as one leaderboard: study,
/// games, lookups, reading. There is deliberately no total at the bottom —
/// see `progress.dart` for why "words mastered" is the only headline.
class ProgressScreen extends ConsumerWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(progressSummaryProvider);
    final streak = ref.watch(studyStreakProvider).valueOrNull ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Progress'),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Share',
            onPressed: summaryAsync.valueOrNull == null
                ? null
                : () => _share(context, summaryAsync.valueOrNull!, streak),
          ),
        ],
      ),
      body: summaryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load progress: $e')),
        data: (summary) => _Body(summary: summary, streak: streak),
      ),
    );
  }

  Future<void> _share(BuildContext context, ProgressSummary summary, int streak) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: shareText(summary, streak: streak),
        // iPad's share sheet is a popover and needs somewhere to point.
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }
}

/// The share card, as text: numbers with units, so what gets compared
/// between friends is what the numbers actually measure.
String shareText(ProgressSummary s, {required int streak}) {
  final o = s.overview;
  final lines = <String>[
    'Lexery — my vocabulary',
    '${formatCount(o.mastered)} words mastered · ${formatCount(o.studying)} studying'
        '${o.unstudied > 0 ? ' · ${formatCount(o.unstudied)} in lists' : ''}',
  ];
  if (s.reviews > 0) {
    final parts = ['${formatCount(s.reviews)} reviews'];
    if (s.retention != null) parts.add('${formatPercent(s.retention)} retention');
    if (s.studyTime.inMinutes > 0) parts.add('${formatSpan(s.studyTime)} studying');
    if (streak > 1) parts.add('$streak-day streak');
    lines.add(parts.join(' · '));
  }
  if (s.gamesCompleted > 0) {
    final bests = [
      for (final g in s.games)
        if (g.best != null) '${_gameLabel(g)} ${formatClock(g.best!)}',
    ];
    lines.add(
      '${formatCount(s.gamesCompleted)} puzzle${s.gamesCompleted == 1 ? '' : 's'} solved'
      '${s.gamesClean > 0 ? ' (${formatCount(s.gamesClean)} clean)' : ''}'
      '${bests.isEmpty ? '' : ' · best ${bests.join(', ')}'}',
    );
  }
  if (s.distinctLookups > 0) {
    lines.add('${formatCount(s.distinctLookups)} words looked up');
  }
  if (s.activeDays > 0) {
    lines.add('${formatCount(s.activeDays)} active day${s.activeDays == 1 ? '' : 's'}');
  }
  return lines.join('\n');
}

/// A game row's name: crosswords by size, other games by name.
String _gameLabel(GameDifficultyStats g) {
  if (g.game == 'hunt') return 'Word Hunt';
  try {
    return CrosswordDifficulty.fromStorageKey(g.difficulty).label;
  } catch (_) {
    return g.difficulty;
  }
}

class _Body extends ConsumerWidget {
  final ProgressSummary summary;
  final int streak;

  const _Body({required this.summary, required this.streak});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final s = summary;
    final o = s.overview;
    final activity = ref.watch(progressActivityProvider).valueOrNull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: [
        // Headline
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              formatCount(o.mastered),
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(width: 10),
            Text(
              o.mastered == 1 ? 'word mastered' : 'words mastered',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'A word is mastered once its review interval reaches 90 days — '
          'it takes real time, not just taps.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        ProgressSegmentsBar(overview: o, height: 18),
        const SizedBox(height: 10),
        ProgressLegend(overview: o),

        if (activity != null) ...[
          _SectionTitle('Last 12 weeks'),
          _ActivityHeatmap(days: activity),
          const SizedBox(height: 6),
          Text(
            '${formatCount(s.activeDays)} active day${s.activeDays == 1 ? '' : 's'}'
            '${s.firstActivity == null ? '' : ' since ${_monthYear(s.firstActivity!)}'}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],

        _SectionTitle('Study'),
        _StatGrid([
          _Stat(formatCount(s.reviews), 'reviews'),
          _Stat(s.studyTime.inMinutes == 0 ? '—' : formatSpan(s.studyTime), 'studying'),
          _Stat(
            formatPercent(s.retention),
            'retention',
            hint: 'Share of reviews on cards ≥3 weeks out that weren\'t forgotten',
          ),
          _Stat('$streak', 'day streak'),
        ]),

        _SectionTitle('Games'),
        if (s.games.isEmpty)
          _Muted('No puzzles finished yet.')
        else
          _GamesTable(games: s.games),

        _SectionTitle('Lookups'),
        _StatGrid([
          _Stat(formatCount(s.distinctLookups), 'words looked up'),
          _Stat(formatCount(s.lookups), 'lookups'),
        ]),
        if (s.repeatLookups.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Looked up more than once', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          for (final r in s.repeatLookups) _RepeatLookupRow(lookup: r),
        ],

        _SectionTitle('Reading & collecting'),
        _StatGrid([
          _Stat(formatCount(s.readerDocuments), s.readerDocuments == 1 ? 'text read' : 'texts read'),
          _Stat(formatCount(s.readerWords), 'words read'),
          _Stat(formatCount(s.listWords), 'words in lists'),
          _Stat(formatCount(s.notes), s.notes == 1 ? 'note written' : 'notes written'),
        ]),
      ],
    );
  }
}

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _monthYear(DateTime d) => '${_monthNames[d.month - 1]} ${d.year}';

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 10),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _Muted extends StatelessWidget {
  final String text;

  const _Muted(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant));
  }
}

class _Stat {
  final String value;
  final String label;
  final String? hint;

  const _Stat(this.value, this.label, {this.hint});
}

/// Two tiles to a row; a number and what it counts.
class _StatGrid extends StatelessWidget {
  final List<_Stat> stats;

  const _StatGrid(this.stats);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final stat in stats)
              SizedBox(
                width: width,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stat.value,
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              stat.label,
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                          ),
                          if (stat.hint != null) ...[
                            const SizedBox(width: 4),
                            Tooltip(
                              message: stat.hint!,
                              triggerMode: TooltipTriggerMode.tap,
                              child: Icon(Icons.info_outline, size: 13, color: scheme.outline),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _GamesTable extends StatelessWidget {
  final List<GameDifficultyStats> games;

  const _GamesTable({required this.games});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    final ordered = [...games]..sort((a, b) {
        // Crosswords by size, then the other games.
        int rank(GameDifficultyStats g) {
          try {
            return g.game == 'crossword' ? CrosswordDifficulty.fromStorageKey(g.difficulty).index : 99;
          } catch (_) {
            return 99;
          }
        }

        return rank(a).compareTo(rank(b));
      });

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(flex: 3, child: Text('Game', style: muted)),
                Expanded(flex: 2, child: Text('Solved', style: muted, textAlign: TextAlign.right)),
                Expanded(flex: 2, child: Text('Best', style: muted, textAlign: TextAlign.right)),
                Expanded(flex: 2, child: Text('Typical', style: muted, textAlign: TextAlign.right)),
              ],
            ),
          ),
          for (final g in ordered)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(_gameLabel(g),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text.rich(
                      TextSpan(
                        text: formatCount(g.completed),
                        children: [
                          if (g.clean != g.completed)
                            TextSpan(text: '  ${g.clean} clean', style: muted),
                        ],
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      g.best == null ? '—' : formatClock(g.best!),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      g.median == null ? '—' : formatClock(g.median!),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Times are clean solves only — no letters revealed.', style: muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// A word the user keeps coming back to. If it isn't in study yet, one tap
/// puts it there — the whole reason the lookup ledger keeps repeats.
class _RepeatLookupRow extends ConsumerWidget {
  final RepeatLookup lookup;

  const _RepeatLookupRow({required this.lookup});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(lookup.headword),
      subtitle: Text('${lookup.count} lookups'),
      trailing: lookup.studying
          ? Icon(Icons.school, size: 18, color: scheme.primary)
          : TextButton.icon(
              onPressed: () async {
                await ref
                    .read(studyRepositoryProvider)
                    .ensureCard(lookup.entryId, ref.read(studyDirectionsProvider));
                ref.invalidate(dueCountProvider);
              },
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Study'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
      onTap: () => context.push('/entry/${Uri.encodeComponent(lookup.headword)}'),
    );
  }
}

/// Twelve weeks of days, one square each, darker the more happened. Weeks
/// run left to right, weekdays top to bottom, the first column padded so
/// Monday is always the top row.
class _ActivityHeatmap extends StatelessWidget {
  final List<ActivityDay> days;

  const _ActivityHeatmap({required this.days});

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final lead = days.first.day.weekday - 1;
    final cells = <ActivityDay?>[for (var i = 0; i < lead; i++) null, ...days];
    final columns = (cells.length / 7).ceil();
    final peak = days.fold(0, (m, d) => d.total > m ? d.total : m);

    Color colorFor(int total) {
      if (total == 0) return scheme.surfaceContainerHighest.withValues(alpha: 0.6);
      // Quartiles of the busiest day, so one huge session doesn't wash
      // every other day out to the palest shade.
      final level = peak == 0 ? 1 : (total / peak * 4).ceil().clamp(1, 4);
      return scheme.primary.withValues(alpha: 0.25 + 0.25 * (level - 1));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 3.0;
        final size = ((constraints.maxWidth - gap * (columns - 1)) / columns).clamp(6.0, 22.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var row = 0; row < 7; row++)
              Padding(
                padding: EdgeInsets.only(bottom: row == 6 ? 0 : gap),
                child: Row(
                  children: [
                    for (var col = 0; col < columns; col++)
                      () {
                        final i = col * 7 + row;
                        final day = i < cells.length ? cells[i] : null;
                        return Padding(
                          padding: EdgeInsets.only(right: col == columns - 1 ? 0 : gap),
                          child: Tooltip(
                            message: day == null
                                ? ''
                                : '${_monthNames[day.day.month - 1]} ${day.day.day}: '
                                    '${day.reviews} reviews, ${day.lookups} lookups, '
                                    '${day.games} puzzles',
                            child: Container(
                              width: size,
                              height: size,
                              decoration: BoxDecoration(
                                color: day == null ? Colors.transparent : colorFor(day.total),
                                borderRadius: BorderRadius.circular(2.5),
                              ),
                            ),
                          ),
                        );
                      }(),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

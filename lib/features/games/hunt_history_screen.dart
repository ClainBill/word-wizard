import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/repositories/crossword_repository.dart' show CrosswordRepository;
import '../../data/repositories/hunt_repository.dart';
import '../progress/progress_format.dart';

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(String date) {
  if (date == CrosswordRepository.today()) return 'Today';
  final parts = date.split('-');
  final year = int.parse(parts[0]);
  final month = int.parse(parts[1]);
  final day = int.parse(parts[2]);
  final yesterday = DateTime.now().subtract(const Duration(days: 1));
  if (year == yesterday.year && month == yesterday.month && day == yesterday.day) {
    return 'Yesterday';
  }
  return '${_monthNames[month - 1]} $day, $year';
}

/// Every board generated so far, newest first, with how far each got.
class HuntHistoryScreen extends ConsumerWidget {
  const HuntHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(huntHistoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Word Hunt History')),
      body: historyAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load history: $e')),
        data: (entries) {
          if (entries.isEmpty) return const Center(child: Text('No boards yet.'));
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _SummaryCard(entries: entries),
              for (final entry in entries) _HistoryRow(entry: entry),
            ],
          );
        },
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final List<HuntHistoryEntry> entries;

  const _SummaryCard({required this.entries});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final completed = entries.where((e) => e.play.completed).length;
    final clean = [
      for (final e in entries)
        if (e.play.completed && !e.play.aided && e.play.activeMs != null) e.play.activeMs!,
    ]..sort();
    final bestScore = entries.fold(0, (n, e) => e.play.score > n ? e.play.score : n);

    Widget stat(String value, String label) => Column(
          children: [
            Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            Text(label, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        );

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            stat('${entries.length}', 'boards'),
            stat('$completed', 'completed'),
            stat(clean.isEmpty ? '—' : formatClock(Duration(milliseconds: clean.first)), 'best clean'),
            stat(formatCount(bestScore), 'best score'),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final HuntHistoryEntry entry;

  const _HistoryRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final play = entry.play;
    final progress = play.requiredTotal == 0 ? 0.0 : play.foundRequired / play.requiredTotal;

    final details = <String>[
      '${play.foundRequired}/${play.requiredTotal} words',
      if (play.bonusFound > 0) '${play.bonusFound} bonus',
      '${formatCount(play.score)} pts',
      if (play.activeMs != null && play.activeMs! > 0)
        formatClock(Duration(milliseconds: play.activeMs!)),
      if (play.aided) 'with help',
    ];

    return ListTile(
      onTap: () => context.push('/games/hunt?puzzle=${entry.id}'),
      leading: SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: progress,
              strokeWidth: 3,
              backgroundColor: scheme.surfaceContainerHighest,
              color: play.completed ? scheme.primary : scheme.secondary,
            ),
            Icon(
              play.completed ? Icons.check : Icons.grid_view_rounded,
              size: 18,
              color: play.completed ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
      title: Row(
        children: [
          Text(_formatDate(entry.date)),
          if (entry.isRegeneration) ...[
            const SizedBox(width: 6),
            Text('(new board)', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(details.join(' · ')),
          Text(
            [
              if (entry.themeLabel != null) 'Theme: ${entry.themeLabel}',
              if (entry.studyWords > 0)
                '${entry.studyWords} study word${entry.studyWords == 1 ? '' : 's'}',
            ].join(' · '),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

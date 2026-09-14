import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/repositories/crossword_repository.dart';
import '../../domain/crossword/crossword_models.dart';
import '../../domain/crossword/editorial.dart';
import '../../domain/models/progress.dart';
import '../progress/progress_format.dart';

/// Past puzzles for one size, and — **for development** — what the editorial
/// pass (PORTING_SPEC.md §9.3) did to each of them and what it billed.
///
/// The pass is the only part of the app that spends money and the only part
/// whose output isn't reproducible from a seed, so while it is being tuned
/// this screen is where you find out whether a run rewrote eight clues or
/// timed out, and what the month is costing. Regenerating a puzzle reviews it
/// again and adds a second run under the same day, which is how two attempts
/// get compared. Remove this section before release.

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(String date) {
  final today = CrosswordRepository.today();
  if (date == today) return 'Today';
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

String _formatTokens(int tokens) {
  if (tokens < 1000) return '$tokens';
  return '${(tokens / 1000).toStringAsFixed(1)}k';
}

/// Four decimal places, because a single review costs fractions of a cent and
/// rounding to two would show every run as $0.00.
String _formatCost(double usd) {
  if (usd <= 0) return '—';
  if (usd < 0.0001) return '<\$0.0001';
  return '\$${usd.toStringAsFixed(4)}';
}

String _formatTime(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

({String label, Color Function(ColorScheme) color}) _outcomeStyle(String outcome) =>
    switch (outcome) {
      'applied' => (label: 'applied', color: (s) => s.primary),
      'no_edits' => (label: 'no edits', color: (s) => s.onSurfaceVariant),
      'all_rejected' => (label: 'all rejected', color: (s) => s.error),
      'not_applied' => (label: 'dropped (in progress)', color: (s) => s.onSurfaceVariant),
      'failed' => (label: 'failed', color: (s) => s.error),
      _ => (label: outcome, color: (s) => s.onSurfaceVariant),
    };

class CrosswordHistoryScreen extends ConsumerWidget {
  final CrosswordDifficulty difficulty;

  const CrosswordHistoryScreen({super.key, required this.difficulty});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(crosswordHistoryProvider(difficulty));
    final totalsAsync = ref.watch(crosswordReviewTotalsProvider(difficulty));

    return Scaffold(
      appBar: AppBar(
        title: Text('${difficulty.label} History'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (_) async {
              await ref.read(crosswordRepositoryProvider).clearReviewLog(difficulty);
              ref.invalidate(crosswordHistoryProvider(difficulty));
              ref.invalidate(crosswordReviewTotalsProvider(difficulty));
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'clear', child: Text('Clear AI editor log')),
            ],
          ),
        ],
      ),
      body: historyAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load history: $e')),
        data: (entries) {
          if (entries.isEmpty) {
            return const Center(child: Text('No puzzles yet.'));
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _PlaySummaryCard(difficulty: difficulty),
              for (final entry in entries) _HistoryRow(difficulty: difficulty, entry: entry),
              // Development-only, so it sits under the puzzles rather than
              // above them.
              _ReviewTotalsCard(totals: totalsAsync.valueOrNull),
            ],
          );
        },
      ),
    );
  }
}

class _ReviewTotalsCard extends ConsumerWidget {
  final CrosswordReviewTotals? totals;

  const _ReviewTotalsCard({required this.totals});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = ref.watch(crosswordReviewEnabledProvider).valueOrNull ?? true;
    final configured = ref.watch(crosswordRepositoryProvider).reviewConfigured;
    final t = totals;

    final status = !configured
        ? 'No API key in this build'
        : enabled
            ? 'On'
            : 'Off — puzzles generate without it';

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_fix_high_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text('AI editor', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                Text(
                  status,
                  style: TextStyle(
                    color: configured && enabled ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (t == null || t.runs == 0)
              Text(
                'No runs at this size yet.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              )
            else ...[
              Text(
                '${_formatCost(t.costUsd)} over ${t.runs} run${t.runs == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              Text(
                '${_formatTokens(t.promptTokens + t.completionTokens)} tokens '
                '(${_formatTokens(t.promptTokens)} in, '
                '${_formatTokens(t.completionTokens)} out — of which '
                '${_formatTokens(t.reasoningTokens)} reasoning)',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              Text(
                '${t.cluesApplied} of ${t.cluesProposed} proposed edits survived '
                'verification'
                '${t.failures > 0 ? ' · ${t.failures} run${t.failures == 1 ? '' : 's'} failed' : ''}',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Text(
                'Cost is estimated locally from token counts and a hardcoded '
                'price table — check the pricing page before trusting it.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            const _BannedAnswersLine(),
          ],
        ),
      ),
    );
  }
}

/// How the user has done at this size: solved, clean, fastest, typical.
class _PlaySummaryCard extends ConsumerWidget {
  final CrosswordDifficulty difficulty;

  const _PlaySummaryCard({required this.difficulty});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final summary = ref.watch(progressSummaryProvider).valueOrNull;
    GameDifficultyStats? stats;
    for (final g in summary?.games ?? const <GameDifficultyStats>[]) {
      if (g.game == 'crossword' && g.difficulty == difficulty.storageKey) stats = g;
    }
    if (stats == null || stats.completed == 0) return const SizedBox.shrink();

    Widget stat(String value, String label) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              Text(label, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
        );

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            stat(formatCount(stats.completed), 'solved'),
            stat(formatCount(stats.clean), 'clean'),
            stat(stats.best == null ? '—' : formatClock(stats.best!), 'best'),
            stat(stats.median == null ? '—' : formatClock(stats.median!), 'typical'),
          ],
        ),
      ),
    );
  }
}

/// A ring that fills as the puzzle does. Done puzzles get a tick, clean
/// ones in the primary colour; an aided finish is still a finish, just not
/// one to rank.
class _FillRing extends StatelessWidget {
  final CrosswordPlayState play;

  const _FillRing({required this.play});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = play.completed;
    final color = done
        ? (play.aided ? scheme.secondary : scheme.primary)
        : play.filledRatio > 0
            ? scheme.primary
            : scheme.outlineVariant;
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: play.filledRatio.clamp(0.0, 1.0),
            strokeWidth: 4,
            color: color,
            backgroundColor: scheme.surfaceContainerHighest,
            strokeCap: StrokeCap.round,
          ),
          if (done)
            Icon(Icons.check, size: 20, color: color)
          else if (play.filledRatio > 0)
            Text(
              '${(play.filledRatio * 100).floor()}',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
            ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final CrosswordDifficulty difficulty;
  final CrosswordHistoryEntry entry;

  const _HistoryRow({required this.difficulty, required this.entry});

  /// One line on how the puzzle went — what a glance at the list should
  /// answer: finished or not, how far, how long.
  String _statusLine() {
    final play = entry.play;
    final time = play.activeMs == null || play.activeMs == 0
        ? null
        : formatClock(Duration(milliseconds: play.activeMs!));
    if (play.completed) {
      final how = play.aided ? 'with help' : 'clean';
      return time == null ? 'Solved · $how' : 'Solved in $time · $how';
    }
    if (play.filledRatio == 0 && play.solvedWords == 0) {
      return time == null ? 'Not started' : 'Opened · $time';
    }
    final words = '${play.solvedWords} of ${play.totalWords} words';
    return time == null ? words : '$words · $time so far';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Opening a puzzle from history must not just push another crossword
    // screen on top of this one: crossword -> history -> crossword ->
    // history -> ... would keep growing, and back would need one press per
    // hop to escape. Popping this history screen first and then replacing
    // the crossword screen it sat on top of keeps the stack exactly one
    // crossword screen deep no matter how many puzzles get opened this way.
    void open() {
      final router = GoRouter.of(context);
      router.pop();
      router.pushReplacement('/games/crossword/${difficulty.storageKey}?puzzle=${entry.id}');
    }

    // A day can hold several generations, so the title has to say which one:
    // "Today" three times over would be exactly the confusion this list
    // exists to remove.
    final title = Row(
      children: [
        Text(_formatDate(entry.date), style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        Text(
          _formatTime(entry.generatedAt),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
        if (entry.isRegeneration) ...[
          const SizedBox(width: 6),
          Icon(Icons.refresh, size: 13, color: scheme.onSurfaceVariant),
        ],
      ],
    );
    final play = entry.play;
    final subtitle = Text(
      _statusLine(),
      style: TextStyle(
        color: play.completed && !play.aided ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
    final leading = _FillRing(play: play);

    if (entry.reviews.isEmpty) {
      return Column(
        children: [
          ListTile(
            leading: leading,
            title: title,
            subtitle: subtitle,
            trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            onTap: open,
          ),
          const Divider(height: 1),
        ],
      );
    }

    // The editorial runs are development detail — a small mark that they
    // exist, and the rest behind the expansion.
    final latest = entry.reviews.first;
    return Column(
      children: [
        ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          leading: leading,
          title: title,
          subtitle: Row(
            children: [
              Flexible(child: subtitle),
              const SizedBox(width: 8),
              Icon(Icons.auto_fix_high_outlined,
                  size: 13, color: _outcomeStyle(latest.outcome).color(scheme)),
            ],
          ),
          trailing: IconButton(
            icon: const Icon(Icons.play_arrow_outlined),
            tooltip: 'Open puzzle',
            onPressed: open,
          ),
          children: [for (final run in entry.reviews) _RunDetail(run: run)],
        ),
        const Divider(height: 1),
      ],
    );
  }
}

class _RunDetail extends StatelessWidget {
  final CrosswordReviewRun run;

  const _RunDetail({required this.run});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = _outcomeStyle(run.outcome);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_formatTime(run.at), style: Theme.of(context).textTheme.labelLarge),
              Text(style.label,
                  style: TextStyle(color: style.color(scheme), fontWeight: FontWeight.w600)),
              Text(run.model, style: TextStyle(color: scheme.onSurfaceVariant)),
              Text('${(run.latencyMs / 1000).toStringAsFixed(1)}s',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              // Which puzzle this run judged: a regenerate makes a new seed,
              // so two runs under one day are told apart by this.
              Text('seed ${run.puzzleSeed}', style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${_formatTokens(run.promptTokens)} in + '
            '${_formatTokens(run.completionTokens)} out '
            '(${_formatTokens(run.reasoningTokens)} reasoning) = '
            '${_formatCost(run.costUsd)}',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          if (run.error.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(run.error, style: TextStyle(color: scheme.error)),
          ],
          if (run.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Scored ${run.entertainment.toStringAsFixed(0)}/10 — ${run.notes}',
                style: Theme.of(context).textTheme.bodySmall),
          ],
          if (run.edits.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final edit in run.edits) _EditRow(edit: edit),
          ],
        ],
      ),
    );
  }
}

class _EditRow extends StatelessWidget {
  final CrosswordProposedEdit edit;

  const _EditRow({required this.edit});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            edit.applied ? Icons.check : Icons.block,
            size: 15,
            color: edit.applied ? scheme.primary : scheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${edit.answer}${edit.isWordEdit ? ' · banned' : ''}'
                  '${edit.rejection.isEmpty ? '' : ' · ${edit.rejection}'}',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                Text(
                  edit.before,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        decoration: edit.applied ? TextDecoration.lineThrough : null,
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                // A ban that failed has nothing to show on the other side:
                // the reviewer never proposed a replacement, by design.
                if (edit.after.isNotEmpty)
                  Text(
                    edit.isWordEdit ? 'solver chose ${edit.after}' : edit.after,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// **Debug.** The standing ban list, and a way out of it.
///
/// The reviewer's verdicts accumulate here across every puzzle, so this is
/// where you find out what it keeps rejecting — the raw material for the
/// word list's own crosswordese set. It is a model's opinion, so it is
/// visible and reversible rather than a silent, permanent narrowing of the
/// pool.
class _BannedAnswersLine extends ConsumerWidget {
  const _BannedAnswersLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final banned = ref.watch(crosswordBannedAnswersProvider).valueOrNull ?? const [];
    if (banned.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: InkWell(
        onTap: () => context.push('/games/crossword-bans'),
        child: Row(
          children: [
            Icon(Icons.block, size: 15, color: scheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${banned.length} answer${banned.length == 1 ? '' : 's'} banned: '
                '${banned.take(6).map((b) => b.answer).join(', ')}'
                '${banned.length > 6 ? '…' : ''}',
                style: TextStyle(color: scheme.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.chevron_right, size: 15, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

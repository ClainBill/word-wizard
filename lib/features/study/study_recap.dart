import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models/study_card.dart';
import '../../domain/srs/sm2.dart';
import '../../widgets/word_detail_sheet.dart';

/// One graded card from a session: what was asked, how it went, and where
/// SM-2 put it as a result.
typedef SessionReview = ({StudyCard card, Grade grade, SrsUpdate update});

/// The end-of-session screen — shown both when the queue runs out and when
/// the user backs out of a session part-way through with something graded.
///
/// Its job is to close the loop the grade buttons open: mid-session you tap
/// "Again" or "Good" and the card vanishes, and nothing tells you what that
/// did. So the recap says, per word, when it's coming back, and pulls the
/// misses out so they can be reread before they're forgotten again.
class StudyRecap extends ConsumerWidget {
  final List<SessionReview> reviews;

  /// Cards left in the queue that were never graded. Zero when the session
  /// ran to the end; otherwise the session was ended early.
  final int remaining;

  /// Time from the first card shown to the last grade given.
  final Duration elapsed;

  final VoidCallback onDone;

  /// Only offered when there's something left to resume.
  final VoidCallback? onResume;

  /// Takes back the last grade and returns to that card. Offered when the
  /// session can still put the card back on screen.
  final VoidCallback? onUndo;

  const StudyRecap({
    super.key,
    required this.reviews,
    required this.remaining,
    required this.elapsed,
    required this.onDone,
    this.onResume,
    this.onUndo,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final finished = remaining == 0;
    final grades = <Grade, int>{};
    for (final r in reviews) {
      grades[r.grade] = (grades[r.grade] ?? 0) + 1;
    }
    final missed = reviews.where((r) => r.grade == Grade.again).toList();
    final recalled = reviews.length - missed.length;
    final streak = ref.watch(studyStreakProvider).valueOrNull ?? 0;
    final forecast = ref.watch(studyForecastProvider).valueOrNull;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            children: [
              Icon(
                finished ? Icons.celebration_outlined : Icons.stop_circle_outlined,
                size: 44,
                color: scheme.primary,
              ),
              const SizedBox(height: 10),
              Text(
                finished ? 'Session complete' : 'Session ended',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                _summaryLine(reviews.length, remaining, elapsed),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              _GradeBar(grades: grades, total: reviews.length),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final grade in Grade.values)
                    if ((grades[grade] ?? 0) > 0) _GradePill(grade: grade, count: grades[grade]!),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '$recalled of ${reviews.length} recalled',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall,
              ),
              if (streak > 0) ...[const SizedBox(height: 16), _StreakBanner(days: streak)],
              const SizedBox(height: 20),
              Text('Up next', style: theme.textTheme.labelLarge),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _MiniStat(
                      label: 'Still due today',
                      value: forecast == null ? '…' : '${forecast[0]}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MiniStat(
                      label: 'Due tomorrow',
                      value: forecast == null || forecast.length < 2 ? '…' : '${forecast[1]}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MiniStat(
                      label: 'Back tomorrow',
                      value: '${missed.length}',
                      tone: missed.isEmpty ? null : Colors.red,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text('Reviewed this session', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(
                missed.isEmpty
                    ? 'Tap a word to open its full card.'
                    : 'Misses are listed first — tap a word to reread its card while '
                          'it\'s fresh.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              // Misses first, then the rest in the order they were seen —
              // the misses are what you'd act on, so they shouldn't be
              // scattered through a long list.
              for (final r in missed) _ReviewRow(review: r),
              for (final r in reviews)
                if (r.grade != Grade.again) _ReviewRow(review: r),
            ],
          ),
        ),
        if (onUndo != null)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton.icon(
                onPressed: onUndo,
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('Undo last grade'),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Row(
            children: [
              if (onResume != null) ...[
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: onResume,
                    icon: const Icon(Icons.play_arrow),
                    label: Text('Keep going ($remaining)'),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: FilledButton(onPressed: onDone, child: const Text('Done')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _summaryLine(int reviewed, int remaining, Duration elapsed) {
    final cards = '$reviewed card${reviewed == 1 ? '' : 's'} reviewed';
    final time = describeElapsed(elapsed);
    if (remaining == 0) return '$cards in $time.';
    return '$cards in $time · $remaining left in the queue.';
  }
}

/// "tomorrow", "in 6 days", "in 3 weeks", "in 4 months" — the coarseness
/// grows with the interval, since "in 97 days" says less than "in 3 months".
String describeNextDue(int intervalDays) {
  if (intervalDays <= 1) return 'tomorrow';
  if (intervalDays < 14) return 'in $intervalDays days';
  if (intervalDays < 60) {
    final weeks = (intervalDays / 7).round();
    return 'in $weeks week${weeks == 1 ? '' : 's'}';
  }
  if (intervalDays < 365) {
    final months = (intervalDays / 30).round();
    return 'in $months month${months == 1 ? '' : 's'}';
  }
  final years = (intervalDays / 365).round();
  return 'in $years year${years == 1 ? '' : 's'}';
}

String describeElapsed(Duration elapsed) {
  final minutes = elapsed.inMinutes;
  if (minutes < 1) return 'under a minute';
  return '$minutes min';
}

Color gradeColor(Grade grade) => switch (grade) {
  Grade.again => Colors.red,
  Grade.hard => Colors.orange,
  Grade.good => Colors.green,
  Grade.easy => Colors.teal,
};

String gradeLabel(Grade grade) => switch (grade) {
  Grade.again => 'Again',
  Grade.hard => 'Hard',
  Grade.good => 'Good',
  Grade.easy => 'Easy',
};

/// A single stacked bar, one segment per grade, sized by share of the
/// session — the shape of the session at a glance before any numbers.
class _GradeBar extends StatelessWidget {
  final Map<Grade, int> grades;
  final int total;

  const _GradeBar({required this.grades, required this.total});

  @override
  Widget build(BuildContext context) {
    if (total == 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        height: 10,
        child: Row(
          // A childless ColoredBox is zero-height under loose constraints;
          // stretching makes each segment fill the bar.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final grade in Grade.values)
              if ((grades[grade] ?? 0) > 0)
                Expanded(
                  flex: grades[grade]!,
                  child: ColoredBox(color: gradeColor(grade)),
                ),
          ],
        ),
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
    final color = gradeColor(grade);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('${gradeLabel(grade)} $count', style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

class _StreakBanner extends StatelessWidget {
  final int days;

  const _StreakBanner({required this.days});

  @override
  Widget build(BuildContext context) {
    return Container(
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

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? tone;

  const _MiniStat({required this.label, required this.value, this.tone});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
      decoration: BoxDecoration(
        border: Border.all(color: tone?.withValues(alpha: 0.5) ?? scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: tone),
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

class _ReviewRow extends StatelessWidget {
  final SessionReview review;

  const _ReviewRow({required this.review});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = review.card;
    final color = gradeColor(review.grade);
    final missed = review.grade == Grade.again;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showWordDetailSheet(context, card.headword),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
          decoration: BoxDecoration(
            color: missed ? color.withValues(alpha: 0.06) : null,
            border: Border.all(color: missed ? color.withValues(alpha: 0.45) : scheme.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 4,
                height: 34,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            card.headword,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            border: Border.all(color: scheme.outlineVariant),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            card.direction.shortLabel,
                            style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                    if (card.gloss != null && card.gloss!.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        card.gloss!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    gradeLabel(review.grade),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    describeNextDue(review.update.state.intervalDays),
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

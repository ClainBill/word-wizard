import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models/study_card_summary.dart';
import '../../domain/models/study_direction.dart';
import '../../domain/srs/sm2.dart';
import '../../widgets/pos_tag.dart';

final _allCardsProvider = StreamProvider<List<StudyCardSummary>>(
  (ref) => ref.watch(studyRepositoryProvider).watchAllCards(),
);

final _historyProvider = StreamProvider.family<List<ReviewLogEntry>, int>(
  (ref, cardId) => ref.watch(studyRepositoryProvider).watchReviewHistory(cardId),
);

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime d) => '${_monthNames[d.month - 1]} ${d.day}, ${d.year}';

String _stageLabel(CardStage stage) => switch (stage) {
      CardStage.newCard => 'New',
      CardStage.learning => 'Learning',
      CardStage.review => 'Review',
      CardStage.mastered => 'Mastered',
    };

String _gradeLabel(Grade g) => switch (g) {
      Grade.again => 'Again',
      Grade.hard => 'Hard',
      Grade.good => 'Good',
      Grade.easy => 'Easy',
    };

Color _stageColor(BuildContext context, CardStage stage) {
  final scheme = Theme.of(context).colorScheme;
  return switch (stage) {
    CardStage.newCard => scheme.onSurfaceVariant,
    CardStage.learning => Colors.orange,
    CardStage.review => scheme.secondary,
    CardStage.mastered => Colors.green,
  };
}

/// Which way round a card is asked, as a badge. A word studied both ways
/// has two rows in this list — they are separately scheduled cards, and
/// pausing or resetting one has nothing to do with the other — so the list
/// has to say which is which.
class _DirectionBadge extends StatelessWidget {
  final StudyDirection direction;

  const _DirectionBadge({required this.direction});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: direction.label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          direction.shortLabel,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class ManageStudyScreen extends ConsumerWidget {
  const ManageStudyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardsAsync = ref.watch(_allCardsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Manage study words')),
      body: cardsAsync.when(
        data: (cards) => cards.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'No words in the SRS yet. Add some from any dictionary '
                    'entry\'s "Study" button, or from a list.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              )
            : ListView.separated(
                itemCount: cards.length,
                separatorBuilder: (context, i) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final card = cards[i];
                  final now = DateTime.now();
                  final dueLabel = card.paused
                      ? 'Paused'
                      : card.dueAt.isBefore(now)
                          ? 'Due now'
                          : 'Due ${_formatDate(card.dueAt)}';
                  return ListTile(
                    title: Row(
                      children: [
                        Flexible(child: Text(card.headword, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 8),
                        PosTag(card.pos),
                        const SizedBox(width: 6),
                        _DirectionBadge(direction: card.direction),
                      ],
                    ),
                    subtitle: Text(
                      'Added ${_formatDate(card.createdAt)} · '
                      'Reviewed ${card.reviewCount} time${card.reviewCount == 1 ? '' : 's'} · '
                      '$dueLabel',
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: (card.paused
                                  ? Theme.of(context).colorScheme.onSurfaceVariant
                                  : _stageColor(context, card.stage))
                              .withValues(alpha: 0.5),
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        card.paused ? 'Paused' : _stageLabel(card.stage),
                        style: TextStyle(
                          fontSize: 11,
                          color: card.paused
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : _stageColor(context, card.stage),
                        ),
                      ),
                    ),
                    onTap: () => _showCardDetail(context, ref, card),
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load: $e')),
      ),
    );
  }

  void _showCardDetail(BuildContext context, WidgetRef ref, StudyCardSummary card) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CardDetailSheet(card: card),
    );
  }
}

class _CardDetailSheet extends ConsumerWidget {
  final StudyCardSummary card;

  const _CardDetailSheet({required this.card});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(_historyProvider(card.cardId));
    final scheme = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              card.headword,
                              style: Theme.of(context).textTheme.titleLarge,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          PosTag(card.pos),
                          const SizedBox(width: 6),
                          _DirectionBadge(direction: card.direction),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        card.paused ? 'Paused' : _stageLabel(card.stage),
                        style: TextStyle(
                          color: card.paused ? scheme.onSurfaceVariant : _stageColor(context, card.stage),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _InfoRow(label: 'Asked', value: card.direction.label),
            _InfoRow(label: 'Added', value: _formatDate(card.createdAt)),
            _InfoRow(
              label: 'Due',
              value: card.paused ? 'Paused (excluded from due queue)' : _formatDate(card.dueAt),
            ),
            _InfoRow(label: 'Reviewed', value: '${card.reviewCount} time${card.reviewCount == 1 ? '' : 's'}'),
            _InfoRow(label: 'Interval', value: '${card.srs.intervalDays} day(s)'),
            _InfoRow(label: 'Ease factor', value: card.srs.easeFactor.toStringAsFixed(2)),
            const SizedBox(height: 8),
            Text('History', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Expanded(
              child: historyAsync.when(
                data: (entries) => entries.isEmpty
                    ? Text(
                        'No reviews yet.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: entries.length,
                        itemBuilder: (context, i) {
                          final e = entries[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 90,
                                  child: Text(
                                    _gradeLabel(e.grade),
                                    style: const TextStyle(fontWeight: FontWeight.w500),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    _formatDate(e.reviewedAt),
                                    style: TextStyle(color: scheme.onSurfaceVariant),
                                  ),
                                ),
                                Text(
                                  'was ${e.priorInterval}d',
                                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('Couldn\'t load history: $e'),
              ),
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: Icon(card.paused ? Icons.play_arrow : Icons.pause),
                    label: Text(card.paused ? 'Resume' : 'Pause'),
                    onPressed: () async {
                      await ref
                          .read(studyRepositoryProvider)
                          .setPaused(card.cardId, !card.paused);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Reset'),
                    onPressed: () => _confirmAndRun(
                      context,
                      title: 'Reset "${card.headword}"?',
                      message: 'This clears its review history and progress, putting it back '
                          'to a brand-new card due immediately.',
                      confirmLabel: 'Reset',
                      action: () => ref.read(studyRepositoryProvider).resetCard(card.cardId),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove this card'),
                onPressed: () => _confirmAndRun(
                  context,
                  title: 'Remove the ${card.direction.label.toLowerCase()} card?',
                  message: 'This deletes the review history for "${card.headword}" in this '
                      'direction only. Its other direction, if you study it both ways, keeps '
                      'its own schedule. The word stays in any lists it belongs to and can be '
                      'added back to study later.',
                  confirmLabel: 'Remove',
                  destructive: true,
                  action: () => ref.read(studyRepositoryProvider).removeCard(card.cardId),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmAndRun(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    required Future<void> Function() action,
    bool destructive = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error)
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await action();
      if (context.mounted) Navigator.of(context).pop();
    }
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

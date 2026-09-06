import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models/study_card.dart';
import '../../domain/srs/sm2.dart';
import '../../widgets/ipa_label.dart';
import '../../widgets/pos_tag.dart';
import '../../widgets/tappable_word_text.dart';
import '../../widgets/word_detail_sheet.dart';

final _dueQueueProvider = FutureProvider.family<List<StudyCard>, int?>(
  (ref, listId) => ref.watch(studyRepositoryProvider).dueQueue(listId: listId),
);

class StudySessionScreen extends ConsumerStatefulWidget {
  final int? listId;

  const StudySessionScreen({super.key, this.listId});

  @override
  ConsumerState<StudySessionScreen> createState() => _StudySessionScreenState();
}

class _StudySessionScreenState extends ConsumerState<StudySessionScreen> {
  int _index = 0;
  bool _revealed = false;
  List<StudyCard>? _queue;

  @override
  Widget build(BuildContext context) {
    final queueAsync = ref.watch(_dueQueueProvider(widget.listId));

    return Scaffold(
      appBar: AppBar(title: const Text('Study session')),
      body: queueAsync.when(
        data: (queue) {
          _queue ??= queue;
          final cards = _queue!;
          if (cards.isEmpty) return _SessionDone(total: 0);
          if (_index >= cards.length) return _SessionDone(total: cards.length);
          return _CardView(
            card: cards[_index],
            index: _index,
            total: cards.length,
            revealed: _revealed,
            onReveal: () => setState(() => _revealed = true),
            onGrade: (grade) async {
              await ref.read(studyRepositoryProvider).grade(cards[_index], grade);
              ref.invalidate(dueCountProvider);
              setState(() {
                _index += 1;
                _revealed = false;
              });
            },
            onRemove: () async {
              final card = cards[_index];
              final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text('Remove "${card.headword}" from study?'),
                      content: const Text(
                        'This deletes its review history and takes it out of the SRS pool. '
                        'It stays in any lists it belongs to and can be added back to study later.',
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Remove'),
                        ),
                      ],
                    ),
                  ) ??
                  false;
              if (!confirmed) return;
              await ref.read(studyRepositoryProvider).removeCard(card.cardId);
              ref.invalidate(dueCountProvider);
              setState(() {
                _queue = List.of(cards)..removeAt(_index);
                _revealed = false;
              });
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load session: $e')),
      ),
    );
  }
}

class _CardView extends StatelessWidget {
  final StudyCard card;
  final int index;
  final int total;
  final bool revealed;
  final VoidCallback onReveal;
  final void Function(Grade) onGrade;
  final VoidCallback onRemove;

  const _CardView({
    required this.card,
    required this.index,
    required this.total,
    required this.revealed,
    required this.onReveal,
    required this.onGrade,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${index + 1} / $total', style: Theme.of(context).textTheme.labelMedium),
                  PopupMenuButton<void>(
                    icon: const Icon(Icons.more_vert),
                    tooltip: 'More',
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        onTap: onRemove,
                        child: const Row(
                          children: [
                            Icon(Icons.delete_outline, size: 18),
                            SizedBox(width: 8),
                            Text('Remove from study'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(value: total == 0 ? 0 : index / total),
              ),
            ],
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: revealed ? () => showWordDetailSheet(context, card.headword) : onReveal,
            onVerticalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity < -250) showWordDetailSheet(context, card.headword);
            },
            behavior: HitTestBehavior.opaque,
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(card.headword, style: Theme.of(context).textTheme.headlineMedium),
                        const SizedBox(height: 6),
                        IpaLabel(card.ipa),
                        const SizedBox(height: 8),
                        PosTag(card.pos),
                        const SizedBox(height: 20),
                        if (!revealed)
                          Text(
                            'Tap to reveal',
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                          )
                        else ...[
                          if (card.gloss != null)
                            TappableWordText(card.gloss!, textAlign: TextAlign.center),
                          if (card.example != null) ...[
                            const SizedBox(height: 8),
                            TappableWordText(
                              '"${card.example}"',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontStyle: FontStyle.italic,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (card.note != null && card.note!.trim().isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Divider(color: Theme.of(context).colorScheme.outlineVariant),
                            const SizedBox(height: 8),
                            MarkdownBody(data: card.note!, shrinkWrap: true),
                          ],
                          const SizedBox(height: 20),
                          Text(
                            'Tap or swipe up for the full card',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _ComprehensionExercise(key: ValueKey(card.cardId), card: card),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (revealed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Row(
              children: [
                _GradeButton(label: 'Again', color: Colors.red, onTap: () => onGrade(Grade.again)),
                _GradeButton(label: 'Hard', color: Colors.orange, onTap: () => onGrade(Grade.hard)),
                _GradeButton(label: 'Good', color: Colors.green, onTap: () => onGrade(Grade.good)),
                _GradeButton(label: 'Easy', color: Colors.teal, onTap: () => onGrade(Grade.easy)),
              ],
            ),
          )
        else
          const SizedBox(height: 88),
      ],
    );
  }
}

class _GradeButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _GradeButton({required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: color,
            side: BorderSide(color: color.withValues(alpha: 0.6)),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}

enum _ExerciseKind { definition, spelling }

/// A tiny, few-seconds-long comprehension check shown under a flipped
/// card — never gates grading, just gives the word a moment of active
/// recall. Randomly definition-match or letter-spelling depending on what
/// data the card has, with a shuffle button to try a different one.
class _ComprehensionExercise extends ConsumerStatefulWidget {
  final StudyCard card;

  const _ComprehensionExercise({super.key, required this.card});

  @override
  ConsumerState<_ComprehensionExercise> createState() => _ComprehensionExerciseState();
}

class _ComprehensionExerciseState extends ConsumerState<_ComprehensionExercise> {
  static final _pureAlpha = RegExp(r'^[A-Za-z]+$');
  final _rand = Random();

  late bool _canDefine;
  late bool _canSpell;
  _ExerciseKind? _kind;

  List<String>? _defineOptions;
  String? _selectedOption;

  List<String>? _scrambledLetters;
  final List<int> _pickedLetterIndices = [];

  @override
  void initState() {
    super.initState();
    _canDefine = widget.card.gloss?.trim().isNotEmpty ?? false;
    _canSpell = _pureAlpha.hasMatch(widget.card.headword);
    _pick(reroll: false);
  }

  void _pick({required bool reroll}) {
    if (!_canDefine && !_canSpell) {
      _kind = null;
      return;
    }
    final _ExerciseKind kind;
    if (_canDefine && _canSpell) {
      kind = (reroll && _kind != null)
          ? (_kind == _ExerciseKind.definition ? _ExerciseKind.spelling : _ExerciseKind.definition)
          : (_rand.nextBool() ? _ExerciseKind.definition : _ExerciseKind.spelling);
    } else {
      kind = _canDefine ? _ExerciseKind.definition : _ExerciseKind.spelling;
    }
    _kind = kind;
    _selectedOption = null;
    _defineOptions = null;
    _pickedLetterIndices.clear();

    if (kind == _ExerciseKind.spelling) {
      final letters = widget.card.headword.split('')..shuffle(_rand);
      // A shuffle can land back in the original order by chance — reshuffle
      // once so the puzzle isn't a no-op.
      if (letters.join() == widget.card.headword) letters.shuffle(_rand);
      _scrambledLetters = letters;
    } else {
      final gloss = widget.card.gloss!;
      ref
          .read(searchRepositoryProvider)
          .randomDistractorGlosses(widget.card.entryId, excludeGloss: gloss, count: 2)
          .then((distractors) {
        if (!mounted) return;
        setState(() => _defineOptions = [gloss, ...distractors]..shuffle(_rand));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_kind == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(minHeight: MediaQuery.of(context).size.height * 0.12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.bolt_outlined, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                _kind == _ExerciseKind.definition ? 'Which definition is right?' : 'Spell it',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.shuffle, size: 16),
                tooltip: 'Try a different exercise',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
                onPressed: () => setState(() => _pick(reroll: true)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_kind == _ExerciseKind.definition) _buildDefinitionMatch(scheme) else _buildSpelling(scheme),
        ],
      ),
    );
  }

  Widget _buildDefinitionMatch(ColorScheme scheme) {
    final options = _defineOptions;
    if (options == null) {
      return const SizedBox(height: 32, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    // Wrapped in IntrinsicHeight so CrossAxisAlignment.stretch has a finite
    // height to stretch to — this Row sits inside a SingleChildScrollView's
    // unbounded-height Column, so without it the Row gets unbounded cross-
    // axis constraints and silently fails to lay out any content at all
    // (no error, no crash, just an empty box).
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final opt in options) ...[
            if (opt != options.first) const SizedBox(width: 6),
            Expanded(child: _buildDefineOption(opt, scheme)),
          ],
        ],
      ),
    );
  }

  Widget _buildDefineOption(String opt, ColorScheme scheme) {
    final isSelected = _selectedOption == opt;
    final isCorrect = opt == widget.card.gloss;
    Color? bg;
    Color border = scheme.outlineVariant;
    if (isSelected) {
      bg = (isCorrect ? Colors.green : Colors.red).withValues(alpha: 0.15);
      border = isCorrect ? Colors.green : Colors.red;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _selectedOption != null ? null : () => setState(() => _selectedOption = opt),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          opt,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }

  Widget _buildSpelling(ColorScheme scheme) {
    final letters = _scrambledLetters!;
    final attempt = _pickedLetterIndices.map((i) => letters[i]).join();
    final target = widget.card.headword;
    final done = _pickedLetterIndices.length == letters.length;
    final correct = attempt.toLowerCase() == target.toLowerCase();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          attempt.isEmpty ? '·' * target.length : attempt,
          style: TextStyle(
            fontSize: 15,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
            color: done ? (correct ? Colors.green : Colors.red) : null,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < letters.length; i++)
              _LetterChip(
                letter: letters[i],
                used: _pickedLetterIndices.contains(i),
                onTap: done
                    ? null
                    : () => setState(() {
                          if (!_pickedLetterIndices.contains(i)) _pickedLetterIndices.add(i);
                        }),
              ),
            if (_pickedLetterIndices.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.backspace_outlined, size: 14),
                tooltip: 'Remove last letter',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(6),
                onPressed: () => setState(() => _pickedLetterIndices.removeLast()),
              ),
          ],
        ),
      ],
    );
  }
}

class _LetterChip extends StatelessWidget {
  final String letter;
  final bool used;
  final VoidCallback? onTap;

  const _LetterChip({required this.letter, required this.used, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: used ? null : onTap,
      child: Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: used ? scheme.surfaceContainerHighest.withValues(alpha: 0.3) : scheme.surface,
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          letter,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: used ? scheme.onSurfaceVariant.withValues(alpha: 0.4) : null,
          ),
        ),
      ),
    );
  }
}

class _SessionDone extends StatelessWidget {
  final int total;

  const _SessionDone({required this.total});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.celebration_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              total == 0 ? 'Nothing due.' : 'Session complete — $total card${total == 1 ? '' : 's'} reviewed.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

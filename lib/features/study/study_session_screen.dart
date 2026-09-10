import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models/study_card.dart';
import '../../domain/srs/sm2.dart';
import '../../services/feature_clues_service.dart';
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

/// Where a card currently sits in the flip sequence:
/// front (word only) -> ask ("did you know it?", word covered back up) ->
/// game (only on "no" - a blind recall jog, word still covered) -> back
/// (meaning revealed, grade buttons shown). "Yes" on the ask step skips
/// straight from ask to back.
enum _Stage { front, ask, game, back }

class _StudySessionScreenState extends ConsumerState<StudySessionScreen> {
  int _index = 0;
  _Stage _stage = _Stage.front;
  List<StudyCard>? _queue;
  final List<StudyCard> _missed = [];
  bool _missedRoundDone = false;

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
          if (_index >= cards.length) {
            if (_missed.length >= 2 && !_missedRoundDone) {
              return _MissedWordsRound(
                cards: _missed,
                onDone: () => setState(() => _missedRoundDone = true),
              );
            }
            return _SessionDone(total: cards.length);
          }
          return _CardView(
            card: cards[_index],
            index: _index,
            total: cards.length,
            stage: _stage,
            onReveal: () => setState(() => _stage = _Stage.ask),
            onKnewIt: () => setState(() => _stage = _Stage.back),
            onDidntKnowIt: () => setState(() => _stage = _Stage.game),
            onGameDone: () => setState(() => _stage = _Stage.back),
            onGrade: (grade) async {
              if (grade == Grade.again) _missed.add(cards[_index]);
              await ref.read(studyRepositoryProvider).grade(cards[_index], grade);
              ref.invalidate(dueCountProvider);
              setState(() {
                _index += 1;
                _stage = _Stage.front;
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
                _stage = _Stage.front;
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
  final _Stage stage;
  final VoidCallback onReveal;
  final VoidCallback onKnewIt;
  final VoidCallback onDidntKnowIt;
  final VoidCallback onGameDone;
  final void Function(Grade) onGrade;
  final VoidCallback onRemove;

  const _CardView({
    required this.card,
    required this.index,
    required this.total,
    required this.stage,
    required this.onReveal,
    required this.onKnewIt,
    required this.onDidntKnowIt,
    required this.onGameDone,
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
            onTap: switch (stage) {
              _Stage.front => onReveal,
              _Stage.back => () => showWordDetailSheet(context, card.headword),
              _Stage.ask || _Stage.game => null,
            },
            onVerticalDragEnd: stage == _Stage.back
                ? (details) {
                    final velocity = details.primaryVelocity ?? 0;
                    if (velocity < -250) showWordDetailSheet(context, card.headword);
                  }
                : null,
            // A faster alternative to tap-then-choose on the front: swipe
            // right to skip straight past the ask step and the game (same
            // as answering "Yes"), swipe left to skip straight into the
            // recall game (same as answering "No, jog my memory").
            onHorizontalDragEnd: stage == _Stage.front
                ? (details) {
                    final velocity = details.primaryVelocity ?? 0;
                    if (velocity > 250) {
                      onKnewIt();
                    } else if (velocity < -250) {
                      onDidntKnowIt();
                    }
                  }
                : null,
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
                        Text(
                          stage == _Stage.ask || stage == _Stage.game
                              ? _maskHeadword(card.headword)
                              : card.headword,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 6),
                        IpaLabel(card.ipa),
                        const SizedBox(height: 8),
                        PosTag(card.pos),
                        const SizedBox(height: 20),
                        switch (stage) {
                          _Stage.front => Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Tap to reveal',
                                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Swipe left to jog your memory, right to skip straight to the answer',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                  ),
                                ),
                              ],
                            ),
                          _Stage.ask => _KnowItPrompt(onKnewIt: onKnewIt, onDidntKnowIt: onDidntKnowIt),
                          _Stage.game => _PreRevealGame(
                              key: ValueKey(card.cardId),
                              card: card,
                              onDone: onGameDone,
                            ),
                          _Stage.back => Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
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
                            ),
                        },
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (stage == _Stage.back)
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

  /// Covers the headword back up once the "did you know it?" step starts —
  /// letters become underscores, spaces and punctuation stay put so a
  /// two-word headword still reads as two blanked words.
  static String _maskHeadword(String headword) => headword.replaceAll(RegExp(r'[A-Za-z]'), '_');
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

/// The "did you know it?" fork shown right after the front is tapped, before
/// anything about the meaning appears. "Yes" skips straight to the back;
/// "no" covers the word back up and runs [_PreRevealGame] first.
class _KnowItPrompt extends StatelessWidget {
  final VoidCallback onKnewIt;
  final VoidCallback onDidntKnowIt;

  const _KnowItPrompt({required this.onKnewIt, required this.onDidntKnowIt});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Did you know it?', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 14),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(onPressed: onKnewIt, child: const Text('Yes')),
            const SizedBox(width: 12),
            FilledButton.tonal(onPressed: onDidntKnowIt, child: const Text('Jog my memory')),
          ],
        ),
      ],
    );
  }
}

enum _RecallKind { cloze, reveal, rhyme, feature }

/// A blind, few-seconds recall game shown only after admitting you didn't
/// know the word — the headword stays covered the whole time. Never blocks
/// or affects grading; "Skip" (or finishing the game) both just move on to
/// the real back of the card. Picks randomly among whichever kinds this
/// card actually has the data for.
class _PreRevealGame extends StatefulWidget {
  final StudyCard card;
  final VoidCallback onDone;

  const _PreRevealGame({super.key, required this.card, required this.onDone});

  @override
  State<_PreRevealGame> createState() => _PreRevealGameState();
}

class _PreRevealGameState extends State<_PreRevealGame> {
  static final _pureAlpha = RegExp(r'^[A-Za-z]+$');
  // Wiktionary examples range from a short invented sentence to a full
  // quoted paragraph (seen live on "serendipity": Horace Walpole's ~1300-
  // character coinage letter) — fine as a citation, unusable as a few-
  // seconds recall game. Same cap concern as crosswordClueOptions' single-
  // line clues, just a little more generous since this is a full screen's
  // only content rather than one line among several options.
  static const _maxClozeLength = 220;

  late final _RecallKind _kind;
  RegExp? _clozePattern;

  @override
  void initState() {
    super.initState();
    final headword = widget.card.headword;
    final example = widget.card.example;
    if (example != null && example.length <= _maxClozeLength) {
      final pattern = RegExp(r'\b' + RegExp.escape(headword) + r'\b', caseSensitive: false);
      if (pattern.hasMatch(example)) _clozePattern = pattern;
    }

    final canRhyme = _pureAlpha.hasMatch(headword) && headword.length >= 3;
    // Only offered when an OpenAI key was baked in at build time (a debug
    // build run with --dart-define-from-file=.env) — see
    // FeatureCluesService.isConfigured. Absent that, this kind just never
    // enters the pool, the same as a card with no example sentence skipping
    // "cloze".
    final canFeature = widget.card.gloss != null && const FeatureCluesService().isConfigured;
    final kinds = [
      if (_clozePattern != null) _RecallKind.cloze,
      _RecallKind.reveal,
      if (canRhyme) _RecallKind.rhyme,
      if (canFeature) _RecallKind.feature,
    ];
    _kind = kinds[Random().nextInt(kinds.length)];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_outline, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                switch (_kind) {
                  _RecallKind.cloze => 'Fill in the blank',
                  _RecallKind.reveal => 'Letter by letter',
                  _RecallKind.rhyme => 'Sound it out',
                  _RecallKind.feature => 'Guess from the clues',
                },
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary),
              ),
              const Spacer(),
              TextButton(
                onPressed: widget.onDone,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Skip', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          switch (_kind) {
            _RecallKind.cloze =>
              _ClozeGame(card: widget.card, pattern: _clozePattern!, onDone: widget.onDone),
            _RecallKind.reveal => _RevealGame(card: widget.card, onDone: widget.onDone),
            _RecallKind.rhyme => _RhymeGame(card: widget.card, onDone: widget.onDone),
            _RecallKind.feature => _FeatureCluesGame(card: widget.card, onDone: widget.onDone),
          },
        ],
      ),
    );
  }
}

/// Blanks the headword out of its own example sentence and asks for it back
/// — recall grounded in real usage rather than an abstract definition.
class _ClozeGame extends StatelessWidget {
  final StudyCard card;
  final RegExp pattern;
  final VoidCallback onDone;

  const _ClozeGame({required this.card, required this.pattern, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blanked = card.example!.replaceAll(pattern, '_____');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '"$blanked"',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        _GuessField(target: card.headword, onDone: onDone, hintText: 'What goes in the blank?'),
      ],
    );
  }
}

/// Hangman-lite: starts fully blanked, a tap reveals one more letter (up to
/// all-but-the-last), turning the classic word-finding cueing hierarchy
/// into one continuous slider instead of a fixed hint.
class _RevealGame extends StatefulWidget {
  final StudyCard card;
  final VoidCallback onDone;

  const _RevealGame({required this.card, required this.onDone});

  @override
  State<_RevealGame> createState() => _RevealGameState();
}

class _RevealGameState extends State<_RevealGame> {
  static final _alpha = RegExp(r'[A-Za-z]');
  int _revealedCount = 0;

  @override
  Widget build(BuildContext context) {
    final word = widget.card.headword;
    final shown = StringBuffer();
    for (var i = 0; i < word.length; i++) {
      final ch = word[i];
      shown.write(!_alpha.hasMatch(ch) || i < _revealedCount ? ch : '_');
    }
    final alphaCount = word.replaceAll(RegExp('[^A-Za-z]'), '').length;
    final canRevealMore = _revealedCount < alphaCount - 1;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          shown.toString().split('').join(' '),
          style: const TextStyle(fontSize: 18, letterSpacing: 2, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: canRevealMore ? () => setState(() => _revealedCount++) : null,
          icon: const Icon(Icons.visibility_outlined, size: 14),
          label: Text(
            canRevealMore ? 'Reveal a letter' : 'No more hints',
            style: const TextStyle(fontSize: 11),
          ),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 4),
        _GuessField(target: word, onDone: widget.onDone, hintText: 'Type the word'),
      ],
    );
  }
}

/// Phonological cues only — syllable count, first letter, and (best-effort)
/// a common real word that sounds like it — deliberately nothing about
/// meaning. Tip-of-the-tongue research suggests this kind of cue resolves a
/// stuck recall better than another meaning-based hint would.
class _RhymeGame extends ConsumerStatefulWidget {
  final StudyCard card;
  final VoidCallback onDone;

  const _RhymeGame({required this.card, required this.onDone});

  @override
  ConsumerState<_RhymeGame> createState() => _RhymeGameState();
}

class _RhymeGameState extends ConsumerState<_RhymeGame> {
  String? _rhyme;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    ref
        .read(searchRepositoryProvider)
        .similarSoundingWord(widget.card.entryId, widget.card.headword)
        .then((word) {
      if (!mounted) return;
      setState(() {
        _rhyme = word;
        _loaded = true;
      });
    });
  }

  static int _estimateSyllables(String word) {
    final w = word.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
    if (w.isEmpty) return 1;
    var count = RegExp('[aeiouy]+').allMatches(w).length;
    if (w.endsWith('e') && !w.endsWith('le') && count > 1) count -= 1;
    return count < 1 ? 1 : count;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final word = widget.card.headword;
    final syllables = _estimateSyllables(word);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Starts with "${word[0].toUpperCase()}" • $syllables syllable${syllables == 1 ? '' : 's'}',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        if (!_loaded)
          const SizedBox(height: 20, child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        else if (_rhyme != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Rhymes with "$_rhyme"', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              IconButton(
                icon: const Icon(Icons.volume_up_outlined, size: 16),
                tooltip: 'Hear it',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.only(left: 4),
                onPressed: () => ref.read(ttsProvider).speak(_rhyme!),
              ),
            ],
          ),
        const SizedBox(height: 8),
        _GuessField(target: word, onDone: widget.onDone, hintText: 'Type the word'),
      ],
    );
  }
}

/// LLM-generated semantic-feature clues (see [FeatureCluesService]) — 2-3
/// short clues that circle the word's meaning (category, an association, a
/// near-synonym) without ever paraphrasing the definition or naming the
/// word, so answering genuinely requires recall rather than recognition.
/// Only reachable when [FeatureCluesService.isConfigured] gated this kind
/// into the pool in the first place, but the network call itself can still
/// fail — that's handled here, not upstream, since it's only known after
/// the request actually runs.
class _FeatureCluesGame extends StatefulWidget {
  final StudyCard card;
  final VoidCallback onDone;

  const _FeatureCluesGame({required this.card, required this.onDone});

  @override
  State<_FeatureCluesGame> createState() => _FeatureCluesGameState();
}

class _FeatureCluesGameState extends State<_FeatureCluesGame> {
  static const _service = FeatureCluesService();
  List<String>? _clues;

  @override
  void initState() {
    super.initState();
    _service
        .clues(headword: widget.card.headword, pos: widget.card.pos, gloss: widget.card.gloss ?? '')
        .then((clues) {
      if (!mounted) return;
      setState(() => _clues = clues);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clues = _clues;
    if (clues == null) {
      return const SizedBox(
        height: 60,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (clues.isEmpty) {
      // The call failed, timed out, or every clue it returned leaked the
      // headword and got filtered out — nothing usable to show, so hand
      // straight back to the real card rather than leave a dead end.
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "Couldn't load a hint for this one.",
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: widget.onDone,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Continue', style: TextStyle(fontSize: 12)),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final clue in clues)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text('• $clue', textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
          ),
        const SizedBox(height: 10),
        _GuessField(target: widget.card.headword, onDone: widget.onDone, hintText: 'What word is it?'),
      ],
    );
  }
}

/// Shared type-a-guess-and-check control used by every [_PreRevealGame]
/// variant — never gates anything, just gives a moment of generative recall
/// before the "Continue" hands back to the real card.
class _GuessField extends StatefulWidget {
  final String target;
  final VoidCallback onDone;
  final String hintText;

  const _GuessField({required this.target, required this.onDone, required this.hintText});

  @override
  State<_GuessField> createState() => _GuessFieldState();
}

class _GuessFieldState extends State<_GuessField> {
  final _controller = TextEditingController();
  bool _checked = false;
  bool _correct = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _check() {
    final guess = _controller.text.trim().toLowerCase();
    setState(() {
      _checked = true;
      _correct = guess.isNotEmpty && guess == widget.target.trim().toLowerCase();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _controller,
          enabled: !_checked,
          textAlign: TextAlign.center,
          onSubmitted: (_) {
            if (!_checked) _check();
          },
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.hintText,
            hintStyle: const TextStyle(fontSize: 12),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            filled: _checked,
            fillColor: _checked ? (_correct ? Colors.green : Colors.red).withValues(alpha: 0.12) : null,
          ),
          style: const TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 8),
        if (!_checked)
          FilledButton.tonal(
            onPressed: _check,
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Check', style: TextStyle(fontSize: 12)),
          )
        else
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Icon(
                _correct ? Icons.check_circle_outline : Icons.cancel_outlined,
                size: 16,
                color: _correct ? Colors.green : Colors.red,
              ),
              Text(
                _correct ? 'Got it!' : 'That\'s okay — it\'s next.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              TextButton(
                onPressed: widget.onDone,
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text('Continue', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
      ],
    );
  }
}

/// A session-end matching round pairing every word marked "Again" this
/// session against its definition — same mechanic as Quizlet's "Match"
/// mode. Only shown when there's more than one miss; capped at
/// [_maxPairs] so it stays a 20-30s round instead of growing with the
/// session.
class _MissedWordsRound extends StatefulWidget {
  final List<StudyCard> cards;
  final VoidCallback onDone;

  const _MissedWordsRound({required this.cards, required this.onDone});

  @override
  State<_MissedWordsRound> createState() => _MissedWordsRoundState();
}

class _MissedWordsRoundState extends State<_MissedWordsRound> {
  static const _maxPairs = 6;

  late final List<StudyCard> _pairs;
  late final List<StudyCard> _wordOrder;
  late final List<StudyCard> _glossOrder;
  final Set<int> _matched = {};
  int? _selectedWordId;
  int? _selectedGlossId;
  int? _wrongFlashWordId;
  int? _wrongFlashGlossId;

  @override
  void initState() {
    super.initState();
    final withGloss = widget.cards.where((c) => c.gloss != null && c.gloss!.trim().isNotEmpty).toList()
      ..shuffle();
    _pairs = withGloss.take(_maxPairs).toList();
    _wordOrder = List.of(_pairs)..shuffle();
    _glossOrder = List.of(_pairs)..shuffle();
  }

  void _tryMatch() {
    if (_selectedWordId == null || _selectedGlossId == null) return;
    if (_selectedWordId == _selectedGlossId) {
      final matchedId = _selectedWordId!;
      setState(() {
        _matched.add(matchedId);
        _selectedWordId = null;
        _selectedGlossId = null;
      });
      return;
    }
    final wrongWord = _selectedWordId;
    final wrongGloss = _selectedGlossId;
    setState(() {
      _wrongFlashWordId = wrongWord;
      _wrongFlashGlossId = wrongGloss;
    });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() {
        _selectedWordId = null;
        _selectedGlossId = null;
        _wrongFlashWordId = null;
        _wrongFlashGlossId = null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allMatched = _matched.length == _pairs.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        children: [
          Icon(Icons.grid_view_outlined, size: 32, color: scheme.primary),
          const SizedBox(height: 8),
          Text('Match what you missed', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'A quick round with the ${_pairs.length} word${_pairs.length == 1 ? '' : 's'} you marked '
            '"Again" this session.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        for (final c in _wordOrder)
                          _MatchTile(
                            text: c.headword,
                            matched: _matched.contains(c.cardId),
                            selected: _selectedWordId == c.cardId,
                            wrong: _wrongFlashWordId == c.cardId,
                            onTap: _matched.contains(c.cardId)
                                ? null
                                : () {
                                    setState(() => _selectedWordId = c.cardId);
                                    _tryMatch();
                                  },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        for (final c in _glossOrder)
                          _MatchTile(
                            text: c.gloss!,
                            matched: _matched.contains(c.cardId),
                            selected: _selectedGlossId == c.cardId,
                            wrong: _wrongFlashGlossId == c.cardId,
                            onTap: _matched.contains(c.cardId)
                                ? null
                                : () {
                                    setState(() => _selectedGlossId = c.cardId);
                                    _tryMatch();
                                  },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (allMatched)
            FilledButton(onPressed: widget.onDone, child: const Text('Done'))
          else
            TextButton(onPressed: widget.onDone, child: const Text('Skip')),
        ],
      ),
    );
  }
}

class _MatchTile extends StatelessWidget {
  final String text;
  final bool matched;
  final bool selected;
  final bool wrong;
  final VoidCallback? onTap;

  const _MatchTile({
    required this.text,
    required this.matched,
    required this.selected,
    required this.wrong,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color border = scheme.outlineVariant;
    Color? bg;
    if (matched) {
      border = Colors.green;
      bg = Colors.green.withValues(alpha: 0.1);
    } else if (wrong) {
      border = Colors.red;
      bg = Colors.red.withValues(alpha: 0.12);
    } else if (selected) {
      border = scheme.primary;
      bg = scheme.primary.withValues(alpha: 0.08);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: matched ? scheme.onSurfaceVariant.withValues(alpha: 0.5) : null,
            ),
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

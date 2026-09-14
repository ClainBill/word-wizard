import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models/study_card.dart';
import '../../domain/study/quiz_example.dart';
import '../../services/feature_clues_service.dart';

/// Which half of a card a mini-game makes you produce.
///
/// This is the whole point of the games, and what the first version got
/// wrong: a game is only a memory jog if it exercises *the thing you just
/// failed to retrieve*. On a word → meaning card you already have the word
/// in front of you — being asked to spell it is busywork, and asking you to
/// type it back is a typing test. What you're missing is the meaning, so the
/// games have to circle the meaning. On a meaning → word card it's exactly
/// the reverse: the meaning is on screen and the word is the gap, which is
/// where letter tiles, cloze, sound cues and anagrams belong.
enum RecallTarget {
  /// Produce the word. Phonological + orthographic cues are fair game;
  /// nothing may show the headword.
  word,

  /// Produce the meaning. The headword is visible throughout; nothing may
  /// show the definition until the game is answered.
  meaning,
}

/// The mini-games, split by which side they make you produce.
enum RecallGameKind {
  // --- produce the word -------------------------------------------------
  /// Wordle-style tiles that start blank and give up one letter at a time.
  letterTiles,

  /// The word's own example sentence with the word cut out of it.
  cloze,

  /// Syllable beats, opening letter and a rhyme — sound only, no meaning.
  soundShape,

  /// Scrambled letter tiles to drop back into place.
  anagram,

  /// LLM-written clues that circle the meaning without naming the word.
  featureClues,

  // --- produce the meaning ----------------------------------------------
  /// Three definitions; one of them is this word's.
  meaningCards,

  /// Three real sentences with a gap; only one of them is missing this word.
  sentenceFit,

  /// This word's definition, shattered into chips, rebuilt in order.
  meaningBuilder;

  RecallTarget get target => switch (this) {
        RecallGameKind.letterTiles ||
        RecallGameKind.cloze ||
        RecallGameKind.soundShape ||
        RecallGameKind.anagram ||
        RecallGameKind.featureClues =>
          RecallTarget.word,
        RecallGameKind.meaningCards ||
        RecallGameKind.sentenceFit ||
        RecallGameKind.meaningBuilder =>
          RecallTarget.meaning,
      };

  String get title => switch (this) {
        RecallGameKind.letterTiles => 'Crack the word',
        RecallGameKind.cloze => 'Fill the gap',
        RecallGameKind.soundShape => 'Sound it out',
        RecallGameKind.anagram => 'Unscramble it',
        RecallGameKind.featureClues => 'Guess from the clues',
        RecallGameKind.meaningCards => 'Which meaning is it?',
        RecallGameKind.sentenceFit => 'Where does it belong?',
        RecallGameKind.meaningBuilder => 'Rebuild the meaning',
      };

  IconData get icon => switch (this) {
        RecallGameKind.letterTiles => Icons.grid_view_rounded,
        RecallGameKind.cloze => Icons.short_text_rounded,
        RecallGameKind.soundShape => Icons.graphic_eq_rounded,
        RecallGameKind.anagram => Icons.shuffle_rounded,
        RecallGameKind.featureClues => Icons.lightbulb_outline_rounded,
        RecallGameKind.meaningCards => Icons.style_outlined,
        RecallGameKind.sentenceFit => Icons.format_quote_rounded,
        RecallGameKind.meaningBuilder => Icons.extension_outlined,
      };
}

final _pureAlpha = RegExp(r"^[A-Za-z][A-Za-z'\- ]*$");

// A definition long enough to need scrolling isn't a puzzle, it's reading.
const _maxBuildableGloss = 120;

/// Whether [card] carries the data a given game needs. A kind that isn't
/// available simply never enters the pool, the way a card with no example
/// sentence skips the cloze game.
bool _isAvailable(RecallGameKind kind, StudyCard card) {
  final headword = card.headword.trim();
  final gloss = card.gloss?.trim() ?? '';
  final alpha = _pureAlpha.hasMatch(headword);
  final letters = headword.replaceAll(RegExp('[^A-Za-z]'), '');

  return switch (kind) {
    RecallGameKind.letterTiles => alpha && letters.length >= 3,
    RecallGameKind.soundShape => alpha && letters.length >= 3,
    // Longer than this and the tray is a wall of tiles rather than a puzzle.
    RecallGameKind.anagram => alpha && letters.length >= 3 && letters.length <= 11,
    RecallGameKind.cloze => clozePattern(card) != null && letters.length >= 2,
    RecallGameKind.sentenceFit => clozePattern(card) != null,
    // Only offered when an OpenAI key was baked in at build time (a debug
    // build run with --dart-define-from-file=.env) — see
    // FeatureCluesService.isConfigured.
    RecallGameKind.featureClues =>
      gloss.isNotEmpty && letters.length >= 2 && const FeatureCluesService().isConfigured,
    RecallGameKind.meaningCards => gloss.isNotEmpty,
    RecallGameKind.meaningBuilder => glossChunks(gloss) != null,
  };
}

/// The pattern that finds [card]'s headword inside its own example sentence,
/// or null when the example can't carry a gap game — see [isQuizExample]:
/// no example, not a real sentence, too long to read at a glance, the word
/// not literally in it, or the word given away by an inflected form left
/// standing next to the gap ("thundered" beside a blank for "thunder").
RegExp? clozePattern(StudyCard card) {
  final example = card.example;
  if (example == null || !isQuizExample(card.headword, example)) return null;
  return headwordPattern(card.headword);
}

/// Splits a definition into 3–5 tappable chips for [RecallGameKind.
/// meaningBuilder], or null if it's too short to be a puzzle (nothing to
/// reorder) or too long to be a quick one.
///
/// Chips are whole runs of words, never fragments: "difficult to / understand
/// or / grasp" reads as language, whereas splitting mid-phrase turns it into
/// a jigsaw of nonsense.
List<String>? glossChunks(String gloss) {
  final text = gloss.trim();
  if (text.isEmpty || text.length > _maxBuildableGloss) return null;
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.length < 4) return null;
  final chunkCount = words.length <= 6
      ? 3
      : words.length <= 12
          ? 4
          : 5;
  final perChunk = (words.length / chunkCount).ceil();
  final chunks = <String>[];
  for (var i = 0; i < words.length; i += perChunk) {
    chunks.add(words.sublist(i, min(i + perChunk, words.length)).join(' '));
  }
  return chunks.length < 2 ? null : chunks;
}

/// Every game that can be built for [card] in the given [target] direction.
List<RecallGameKind> availableGames(StudyCard card, RecallTarget target) => [
      for (final kind in RecallGameKind.values)
        if (kind.target == target && _isAvailable(kind, card)) kind,
    ];

// ---------------------------------------------------------------------------
// The panel
// ---------------------------------------------------------------------------

/// One mini-game in a tinted panel, with its own title, a re-roll button and
/// (optionally) a skip.
///
/// Never gates anything: whatever the user does here, [onDone] hands control
/// straight back to the card, and no answer in here ever touches the SM-2
/// schedule. The grade the user gives themselves afterwards is the only
/// signal the scheduler gets — a game that fed into it would reward guessing
/// at letter tiles rather than knowing the word.
class RecallGamePanel extends ConsumerStatefulWidget {
  final StudyCard card;
  final RecallTarget target;
  final VoidCallback onDone;

  /// A skip link in the header. On, for the pre-reveal jog (where the game
  /// stands between the user and the answer); off for the post-reveal
  /// exercise, which the user can simply ignore.
  final bool showSkip;

  /// The post-reveal exercise sits under an already-full card, so it gets
  /// tighter padding and no minimum height.
  final bool dense;

  const RecallGamePanel({
    super.key,
    required this.card,
    required this.target,
    required this.onDone,
    this.showSkip = true,
    this.dense = false,
  });

  @override
  ConsumerState<RecallGamePanel> createState() => _RecallGamePanelState();
}

class _RecallGamePanelState extends ConsumerState<RecallGamePanel> {
  final _rand = Random();
  late List<RecallGameKind> _pool;
  RecallGameKind? _kind;
  int _round = 0;

  @override
  void initState() {
    super.initState();
    _pool = availableGames(widget.card, widget.target);
    _kind = _pool.isEmpty ? null : _pool[_rand.nextInt(_pool.length)];
  }

  void _reroll() {
    if (_pool.length < 2) return;
    final others = _pool.where((k) => k != _kind).toList();
    setState(() {
      _kind = others[_rand.nextInt(others.length)];
      _round++;
    });
  }

  /// Whether the panel stands between the user and the answer. When it
  /// does, finishing a game has somewhere to go ("Continue" reveals the
  /// card) and there is something to skip. The post-reveal exercise is a
  /// bonus sitting under an already-open card, so it offers neither — a
  /// "Continue" there would be a button that does nothing.
  VoidCallback? get _handOff => widget.showSkip ? widget.onDone : null;

  @override
  Widget build(BuildContext context) {
    final kind = _kind;
    final scheme = Theme.of(context).colorScheme;
    if (kind == null) {
      // No game can be built from this card's data at all. For the
      // pre-reveal jog that would be a dead end, so hand straight back.
      if (!widget.showSkip) return const SizedBox.shrink();
      return TextButton(onPressed: widget.onDone, child: const Text('Continue'));
    }

    return Container(
      width: double.infinity,
      constraints: widget.dense
          ? const BoxConstraints()
          : const BoxConstraints(minHeight: 180),
      padding: EdgeInsets.all(widget.dense ? 12 : 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(kind.icon, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  kind.title,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary),
                ),
              ),
              const Spacer(),
              if (_pool.length > 1)
                IconButton(
                  icon: const Icon(Icons.casino_outlined, size: 16),
                  tooltip: 'Try a different game',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                  onPressed: _reroll,
                ),
              if (widget.showSkip)
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
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: KeyedSubtree(
              key: ValueKey('${widget.card.cardId}-$kind-$_round'),
              child: switch (kind) {
                RecallGameKind.letterTiles =>
                  _LetterTilesGame(card: widget.card, onDone: _handOff),
                RecallGameKind.cloze => _ClozeGame(card: widget.card, onDone: _handOff),
                RecallGameKind.soundShape => _SoundShapeGame(card: widget.card, onDone: _handOff),
                RecallGameKind.anagram => _AnagramGame(card: widget.card, onDone: _handOff),
                RecallGameKind.featureClues =>
                  _FeatureCluesGame(card: widget.card, onDone: _handOff),
                RecallGameKind.meaningCards =>
                  _MeaningCardsGame(card: widget.card, onDone: _handOff),
                RecallGameKind.sentenceFit => _SentenceFitGame(card: widget.card, onDone: _handOff),
                RecallGameKind.meaningBuilder =>
                  _MeaningBuilderGame(card: widget.card, onDone: _handOff),
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Produce-the-word games
// ---------------------------------------------------------------------------

/// Hangman-lite, as tiles. Starts fully blank and gives up one letter at a
/// time, left to right, never the last one for free — the speech-therapy
/// cueing hierarchy (least-helpful cue first, escalating only as needed)
/// collapsed into a single slider the user controls.
class _LetterTilesGame extends StatefulWidget {
  final StudyCard card;
  final VoidCallback? onDone;

  const _LetterTilesGame({required this.card, required this.onDone});

  @override
  State<_LetterTilesGame> createState() => _LetterTilesGameState();
}

class _LetterTilesGameState extends State<_LetterTilesGame> {
  int _revealed = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final word = widget.card.headword.trim();
    final letterCount = word.replaceAll(RegExp('[^A-Za-z]'), '').length;
    final canRevealMore = _revealed < letterCount - 1;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$letterCount letters',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        TileWordInput(
          target: word,
          lockedLetterCount: _revealed,
          onDone: widget.onDone,
        ),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: canRevealMore ? () => setState(() => _revealed++) : null,
          icon: const Icon(Icons.lightbulb_outline, size: 14),
          label: Text(
            canRevealMore ? 'Give me a letter' : 'No more letters',
            style: const TextStyle(fontSize: 11),
          ),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ],
    );
  }
}

/// The word cut out of its own example sentence — recall grounded in real
/// usage instead of an abstract definition. The gap is drawn as a real slot
/// the width of the answer, so the sentence reads as a sentence with a hole
/// in it rather than a row of underscores.
class _ClozeGame extends StatelessWidget {
  final StudyCard card;
  final VoidCallback? onDone;

  const _ClozeGame({required this.card, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pattern = clozePattern(card)!;
    final example = card.example!.trim();
    final letters = card.headword.replaceAll(RegExp('[^A-Za-z]'), '').length;

    // Split around every occurrence so the gap can be a widget rather than a
    // run of underscores in a string.
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in pattern.allMatches(example)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: example.substring(cursor, match.start)));
      }
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: (letters * 7.0).clamp(36.0, 96.0),
          height: 16,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.14),
            border: Border(bottom: BorderSide(color: scheme.primary, width: 1.5)),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          ),
        ),
      ));
      cursor = match.end;
    }
    if (cursor < example.length) spans.add(TextSpan(text: example.substring(cursor)));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(children: spans),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        TileWordInput(target: card.headword.trim(), onDone: onDone),
      ],
    );
  }
}

/// Phonological cues only — how many beats the word has, what it opens with,
/// and something it rhymes with. Deliberately says nothing about meaning:
/// tip-of-the-tongue research (Meyer & Bock 1992, and a 2010 *Memory &
/// Cognition* replication) found sound cues break a stuck retrieval better
/// than more meaning cues do, because in a real TOT state the concept is
/// already there and it's the sound shell that's missing.
class _SoundShapeGame extends ConsumerStatefulWidget {
  final StudyCard card;
  final VoidCallback? onDone;

  const _SoundShapeGame({required this.card, required this.onDone});

  @override
  ConsumerState<_SoundShapeGame> createState() => _SoundShapeGameState();
}

class _SoundShapeGameState extends ConsumerState<_SoundShapeGame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _beat;
  String? _rhyme;
  bool _rhymeLoaded = false;

  static int estimateSyllables(String word) {
    final w = word.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
    if (w.isEmpty) return 1;
    var count = RegExp('[aeiouy]+').allMatches(w).length;
    if (w.endsWith('e') && !w.endsWith('le') && count > 1) count -= 1;
    return count < 1 ? 1 : count;
  }

  @override
  void initState() {
    super.initState();
    _beat = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 420 * estimateSyllables(widget.card.headword)),
    )..repeat();
    ref
        .read(searchRepositoryProvider)
        .similarSoundingWord(widget.card.entryId, widget.card.headword)
        .then((word) {
      if (!mounted) return;
      setState(() {
        _rhyme = word;
        _rhymeLoaded = true;
      });
    });
  }

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final word = widget.card.headword.trim();
    final syllables = estimateSyllables(word);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Syllables as beats that pulse in turn — the count read as rhythm
        // rather than as a number, which is how you actually search for a
        // word you can nearly say.
        AnimatedBuilder(
          animation: _beat,
          builder: (context, _) {
            final active = (_beat.value * syllables).floor().clamp(0, syllables - 1);
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < syllables; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == active ? 16 : 10,
                    height: i == active ? 16 : 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == active
                          ? scheme.primary
                          : scheme.primary.withValues(alpha: 0.25),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            _CuePill(label: 'starts with', value: word[0].toUpperCase()),
            _CuePill(
              label: 'syllable${syllables == 1 ? '' : 's'}',
              value: '$syllables',
            ),
            if (!_rhymeLoaded)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            else if (_rhyme != null)
              _CuePill(
                label: 'rhymes with',
                value: _rhyme!,
                onSpeak: () => ref.read(ttsProvider).speak(_rhyme!),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TileWordInput(target: word, onDone: widget.onDone),
      ],
    );
  }
}

class _CuePill extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onSpeak;

  const _CuePill({required this.label, required this.value, this.onSpeak});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
          const SizedBox(width: 6),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          if (onSpeak != null)
            IconButton(
              icon: const Icon(Icons.volume_up_outlined, size: 14),
              tooltip: 'Hear it',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.only(left: 4),
              onPressed: onSpeak,
            )
          else
            const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// The word's own letters, shuffled into a tray. Tap to drop them into the
/// slots, tap a slot to send its tile back. Checks itself the moment the
/// last slot fills.
class _AnagramGame extends StatefulWidget {
  final StudyCard card;
  final VoidCallback? onDone;

  const _AnagramGame({required this.card, required this.onDone});

  @override
  State<_AnagramGame> createState() => _AnagramGameState();
}

class _AnagramGameState extends State<_AnagramGame> {
  late final String _target;
  late final List<String> _tray;
  final List<int> _placed = [];
  bool? _correct;

  @override
  void initState() {
    super.initState();
    _target = widget.card.headword.trim().replaceAll(RegExp('[^A-Za-z]'), '');
    final letters = _target.split('')..shuffle(Random());
    // A shuffle can land back in the original order by chance — reshuffle
    // once so the puzzle isn't a no-op.
    if (letters.join() == _target && _target.length > 1) letters.shuffle(Random());
    _tray = letters;
  }

  void _place(int trayIndex) {
    if (_correct != null || _placed.contains(trayIndex)) return;
    HapticFeedback.selectionClick();
    setState(() => _placed.add(trayIndex));
    if (_placed.length == _tray.length) {
      final attempt = _placed.map((i) => _tray[i]).join();
      final ok = attempt.toLowerCase() == _target.toLowerCase();
      HapticFeedback.mediumImpact();
      setState(() => _correct = ok);
    }
  }

  void _takeBack() {
    if (_correct != null || _placed.isEmpty) return;
    setState(() => _placed.removeLast());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placedLetters = _placed.map((i) => _tray[i]).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 5,
          runSpacing: 5,
          children: [
            for (var i = 0; i < _target.length; i++)
              _LetterTile(
                letter: i < placedLetters.length ? placedLetters[i] : '',
                state: _correct == null
                    ? (i < placedLetters.length ? _TileState.filled : _TileState.empty)
                    : (_correct! ? _TileState.correct : _TileState.wrong),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_correct == null) ...[
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 5,
            runSpacing: 5,
            children: [
              for (var i = 0; i < _tray.length; i++)
                _LetterTile(
                  letter: _tray[i],
                  state: _placed.contains(i) ? _TileState.used : _TileState.tray,
                  onTap: () => _place(i),
                ),
            ],
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: _placed.isEmpty ? null : _takeBack,
            icon: const Icon(Icons.backspace_outlined, size: 14),
            label: const Text('Take one back', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ] else
          _ResultRow(
            correct: _correct!,
            answer: _correct! ? null : widget.card.headword,
            onDone: widget.onDone,
          ),
        if (_correct == null)
          Text(
            'Tap the letters in order',
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
          ),
      ],
    );
  }
}

/// LLM-written semantic-feature clues (see [FeatureCluesService]) — short
/// clues that circle the word's meaning (its category, an association, a
/// near-synonym) without ever paraphrasing the definition or naming the
/// word, so answering genuinely requires recall rather than recognition.
/// The clues arrive one at a time so the user gets a chance at the first
/// before the rest of the hint spends itself.
///
/// The kind only enters the pool when [FeatureCluesService.isConfigured],
/// but the network call itself can still fail — that's handled here, since
/// it's only known after the request actually runs.
class _FeatureCluesGame extends StatefulWidget {
  final StudyCard card;
  final VoidCallback? onDone;

  const _FeatureCluesGame({required this.card, required this.onDone});

  @override
  State<_FeatureCluesGame> createState() => _FeatureCluesGameState();
}

class _FeatureCluesGameState extends State<_FeatureCluesGame> {
  static const _service = FeatureCluesService();
  List<String>? _clues;
  int _shown = 1;

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
      return const SizedBox(height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (clues.isEmpty) {
      // The call failed, timed out, or every clue it returned leaked the
      // headword and got filtered out — nothing usable to show, so hand
      // straight back rather than leave a dead end.
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "Couldn't load a hint for this one.",
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          if (widget.onDone != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: widget.onDone,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('Continue', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < min(_shown, clues.length); i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(clues[i], textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
            ),
          ),
        if (_shown < clues.length)
          TextButton.icon(
            onPressed: () => setState(() => _shown++),
            icon: const Icon(Icons.add, size: 14),
            label: const Text('Another clue', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        const SizedBox(height: 8),
        TileWordInput(target: widget.card.headword.trim(), onDone: widget.onDone),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Produce-the-meaning games
// ---------------------------------------------------------------------------

/// Three definitions; one is this word's. Recognition rather than free
/// recall, which makes it the gentlest of the meaning games — its job is to
/// be the one that always works, since every card has a gloss.
class _MeaningCardsGame extends ConsumerStatefulWidget {
  final StudyCard card;
  final VoidCallback? onDone;

  const _MeaningCardsGame({required this.card, required this.onDone});

  @override
  ConsumerState<_MeaningCardsGame> createState() => _MeaningCardsGameState();
}

class _MeaningCardsGameState extends ConsumerState<_MeaningCardsGame> {
  List<String>? _options;
  String? _picked;

  @override
  void initState() {
    super.initState();
    final gloss = widget.card.gloss!.trim();
    ref
        .read(searchRepositoryProvider)
        .randomDistractorGlosses(widget.card.entryId, excludeGloss: gloss, count: 2)
        .then((distractors) {
      if (!mounted) return;
      setState(() => _options = [gloss, ...distractors]..shuffle(Random()));
    });
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    if (options == null) {
      return const SizedBox(height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final answer = widget.card.gloss!.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in options)
          _ChoiceCard(
            text: option,
            state: _picked == null
                ? _ChoiceState.idle
                : option == answer
                    ? _ChoiceState.correct
                    : option == _picked
                        ? _ChoiceState.wrong
                        : _ChoiceState.dimmed,
            onTap: _picked != null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    setState(() => _picked = option);
                  },
          ),
        if (_picked != null) ...[
          const SizedBox(height: 8),
          _ResultRow(correct: _picked == answer, onDone: widget.onDone),
        ],
      ],
    );
  }
}

/// Three real sentences, each with a word cut out of it; only one of them is
/// missing *this* word. Distractors are other entries' genuine examples, so
/// the wrong answers are real English that simply wants a different word —
/// which is what makes the choice a test of usage rather than of style.
/// They are picked to be *about the same things* as the real sentence
/// (`examples_fts`): three unrelated sentences can be told apart on topic
/// without knowing the word at all.
class _SentenceFitGame extends ConsumerStatefulWidget {
  final StudyCard card;
  final VoidCallback? onDone;

  const _SentenceFitGame({required this.card, required this.onDone});

  @override
  ConsumerState<_SentenceFitGame> createState() => _SentenceFitGameState();
}

class _SentenceFitGameState extends ConsumerState<_SentenceFitGame> {
  List<String>? _options;
  late final String _answer;
  String? _picked;

  @override
  void initState() {
    super.initState();
    _answer = blankHeadword(widget.card.headword, widget.card.example!);
    ref
        .read(searchRepositoryProvider)
        .similarDistractorExamples(
          widget.card.example!,
          excludeEntryId: widget.card.entryId,
          headword: widget.card.headword,
          count: 2,
        )
        .then((distractors) {
      if (!mounted) return;
      setState(() {
        // A dictionary-wide random sample can come back short (most rows are
        // filtered out for length or for not containing their own headword).
        // Two options is still a real choice; one is not, so fall through to
        // an unanswerable-but-harmless single card rather than crash.
        final unique = distractors.where((d) => d != _answer).toSet().toList();
        _options = [_answer, ...unique]..shuffle(Random());
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final options = _options;
    if (options == null) {
      return const SizedBox(height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (options.length < 2) {
      // The dictionary-wide random sample came back with nothing usable —
      // most rows get filtered out for length, age, or for not containing
      // their own headword. A single card isn't a choice, so say so rather
      // than offer a question with one answer.
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "Couldn't find sentences to compare this one against.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          if (widget.onDone != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: widget.onDone,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('Continue', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Which gap wants "${widget.card.headword}"?',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        for (final option in options)
          _ChoiceCard(
            text: option,
            italic: true,
            state: _picked == null
                ? _ChoiceState.idle
                : option == _answer
                    ? _ChoiceState.correct
                    : option == _picked
                        ? _ChoiceState.wrong
                        : _ChoiceState.dimmed,
            onTap: _picked != null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    setState(() => _picked = option);
                  },
          ),
        if (_picked != null) ...[
          const SizedBox(height: 8),
          _ResultRow(correct: _picked == _answer, onDone: widget.onDone),
        ],
      ],
    );
  }
}

/// The word's definition shattered into chips and rebuilt in order. Halfway
/// between recognition and free recall: the words are all in front of you,
/// but putting them back in order means holding the actual sense of the
/// definition in mind, not just spotting a familiar phrase.
class _MeaningBuilderGame extends StatefulWidget {
  final StudyCard card;
  final VoidCallback? onDone;

  const _MeaningBuilderGame({required this.card, required this.onDone});

  @override
  State<_MeaningBuilderGame> createState() => _MeaningBuilderGameState();
}

class _MeaningBuilderGameState extends State<_MeaningBuilderGame> {
  late final List<String> _chunks;
  late final List<String> _shuffled;

  /// Indices into [_shuffled], not the chip text: a definition can repeat a
  /// phrase ("of or relating to ..."), and matching by text would retire
  /// both copies the moment either one is tapped.
  final List<int> _placed = [];

  int? _wrongIndex;
  int _mistakes = 0;

  @override
  void initState() {
    super.initState();
    _chunks = glossChunks(widget.card.gloss!)!;
    final shuffled = List.of(_chunks)..shuffle(Random());
    if (shuffled.join('|') == _chunks.join('|')) shuffled.shuffle(Random());
    _shuffled = shuffled;
  }

  void _tap(int index) {
    if (_placed.length == _chunks.length) return;
    if (_shuffled[index] == _chunks[_placed.length]) {
      HapticFeedback.selectionClick();
      setState(() => _placed.add(index));
      if (_placed.length == _chunks.length) HapticFeedback.mediumImpact();
      return;
    }
    setState(() {
      _wrongIndex = index;
      _mistakes++;
    });
    Future.delayed(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _wrongIndex = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = _placed.length == _chunks.length;
    final built = _placed.map((i) => _shuffled[i]).join(' ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: done
                ? Colors.green.withValues(alpha: 0.12)
                : scheme.surface.withValues(alpha: 0.7),
            border: Border.all(
              color: done ? Colors.green : scheme.outlineVariant,
              style: done ? BorderStyle.solid : BorderStyle.solid,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            _placed.isEmpty ? 'Tap the pieces in the right order' : built,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontStyle: _placed.isEmpty ? FontStyle.italic : FontStyle.normal,
              color: _placed.isEmpty ? scheme.onSurfaceVariant.withValues(alpha: 0.7) : null,
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (!done)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < _shuffled.length; i++)
                if (!_placed.contains(i))
                  _Chip(
                    text: _shuffled[i],
                    wrong: _wrongIndex == i,
                    onTap: () => _tap(i),
                  ),
            ],
          )
        else
          // Always a success: the definition is on screen and correctly
          // ordered either way. How many wrong taps it took is the only
          // thing worth reflecting back, and it isn't worth a red cross.
          _ResultRow(
            correct: true,
            successLabel: _mistakes == 0 ? 'Straight through.' : 'Rebuilt it.',
            onDone: widget.onDone,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared visual controls
// ---------------------------------------------------------------------------

enum _TileState { empty, filled, tray, used, correct, wrong }

class _LetterTile extends StatelessWidget {
  final String letter;
  final _TileState state;
  final VoidCallback? onTap;

  const _LetterTile({required this.letter, required this.state, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color? bg, Color border, Color? fg) = switch (state) {
      _TileState.empty => (null, scheme.outlineVariant, null),
      _TileState.filled => (scheme.surface, scheme.primary, null),
      _TileState.tray => (scheme.surface, scheme.outlineVariant, null),
      _TileState.used => (
          scheme.surfaceContainerHighest.withValues(alpha: 0.3),
          scheme.outlineVariant.withValues(alpha: 0.4),
          scheme.onSurfaceVariant.withValues(alpha: 0.25),
        ),
      _TileState.correct => (Colors.green.withValues(alpha: 0.18), Colors.green, null),
      _TileState.wrong => (Colors.red.withValues(alpha: 0.15), Colors.red, null),
    };

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 30,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border, width: state == _TileState.empty ? 1 : 1.5),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          letter.toUpperCase(),
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: fg),
        ),
      ),
    );
  }
}

/// A separator drawn where the answer has a space, hyphen or apostrophe, so
/// a two-word or hyphenated headword still reads as one — and so the tile
/// count matches the letters you actually have to type.
class _TileSeparator extends StatelessWidget {
  final String character;

  const _TileSeparator({required this.character});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: character == ' ' ? 10 : 12,
      height: 34,
      child: Center(
        child: Text(
          character == ' ' ? '' : character,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// A row of letter tiles you type into.
///
/// The tiles are the interface; the real [TextField] sits invisibly behind
/// them purely to raise the keyboard and hold the buffer (the standard
/// PIN-field technique — a zero-sized field doesn't reliably take input on
/// every platform, and a visible one alongside the tiles would show the
/// answer twice). Letters given away as hints occupy the first
/// [lockedLetterCount] slots and can't be deleted.
class TileWordInput extends StatefulWidget {
  final String target;
  final int lockedLetterCount;

  /// Null when this input sits under an already-revealed card: there is
  /// nothing to continue to, so the verdict row omits its button.
  final VoidCallback? onDone;

  const TileWordInput({
    super.key,
    required this.target,
    this.lockedLetterCount = 0,
    required this.onDone,
  });

  @override
  State<TileWordInput> createState() => _TileWordInputState();
}

class _TileWordInputState extends State<TileWordInput> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  late final String _letters = widget.target.replaceAll(RegExp('[^A-Za-z]'), '');
  bool _checked = false;
  bool _correct = false;

  String get _lockedPrefix => _letters.substring(0, widget.lockedLetterCount.clamp(0, _letters.length));

  @override
  void didUpdateWidget(TileWordInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A newly revealed letter has to end up in the buffer, not just on the
    // tiles: the user carries on typing from where the hint left off.
    if (widget.lockedLetterCount != oldWidget.lockedLetterCount) _applyLock();
  }

  void _applyLock() {
    final prefix = _lockedPrefix;
    if (prefix.isEmpty) return;
    final text = _controller.text;
    if (text.toLowerCase().startsWith(prefix.toLowerCase()) && text.length >= prefix.length) return;
    _controller.value = TextEditingValue(
      text: prefix,
      selection: TextSelection.collapsed(offset: prefix.length),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final prefix = _lockedPrefix;
    if (prefix.isNotEmpty && !value.toLowerCase().startsWith(prefix.toLowerCase())) {
      _applyLock();
      return;
    }
    setState(() {});
    if (value.length == _letters.length) _check();
  }

  void _check() {
    if (_checked) return;
    final guess = _controller.text.trim().toLowerCase();
    HapticFeedback.mediumImpact();
    setState(() {
      _checked = true;
      _correct = guess.isNotEmpty && guess == _letters.toLowerCase();
    });
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final typed = _controller.text;
    // Walk the target and the buffer together so separators keep their place
    // and the tiles line up with the letters actually typed.
    final tiles = <Widget>[];
    var letterIndex = 0;
    for (final ch in widget.target.split('')) {
      if (!RegExp('[A-Za-z]').hasMatch(ch)) {
        tiles.add(_TileSeparator(character: ch));
        continue;
      }
      final i = letterIndex++;
      final typedChar = i < typed.length ? typed[i] : '';
      final locked = i < _lockedPrefix.length;
      tiles.add(_LetterTile(
        letter: _checked && !_correct ? ch : typedChar,
        state: _checked
            ? (_correct ? _TileState.correct : _TileState.wrong)
            : locked
                ? _TileState.filled
                : typedChar.isEmpty
                    ? _TileState.empty
                    : _TileState.filled,
      ));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _checked ? null : () => _focus.requestFocus(),
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                height: 34,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autocorrect: false,
                  enableSuggestions: false,
                  showCursor: false,
                  enabled: !_checked,
                  textInputAction: TextInputAction.done,
                  textCapitalization: TextCapitalization.none,
                  cursorColor: Colors.transparent,
                  style: const TextStyle(color: Colors.transparent, fontSize: 12),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z]')),
                    LengthLimitingTextInputFormatter(_letters.length),
                  ],
                  onChanged: _onChanged,
                  onSubmitted: (_) => _check(),
                ),
              ),
              IgnorePointer(
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: tiles,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (!_checked)
          FilledButton.tonal(
            onPressed: typed.length <= _lockedPrefix.length ? null : _check,
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Check', style: TextStyle(fontSize: 12)),
          )
        else
          _ResultRow(correct: _correct, onDone: widget.onDone),
      ],
    );
  }
}

/// The two-word verdict every game ends on. Deliberately gentle about a
/// miss: the answer is one tap away regardless, and nothing here changes the
/// card's schedule, so there is nothing to be graded down about.
class _ResultRow extends StatelessWidget {
  final bool correct;
  final String? answer;
  final String? successLabel;
  final VoidCallback? onDone;

  const _ResultRow({
    required this.correct,
    this.answer,
    this.successLabel,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Icon(
          correct ? Icons.check_circle_outline : Icons.cancel_outlined,
          size: 16,
          color: correct ? Colors.green : Colors.red,
        ),
        Text(
          correct
              ? (successLabel ?? 'Got it!')
              : answer != null
                  ? 'It was "$answer".'
                  // Without a hand-off this panel sits under an already-open
                  // card, where "it's next" would be nonsense — the answer is
                  // right there, highlighted.
                  : onDone == null
                      ? "The right one's marked."
                      : "That's okay — it's next.",
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        if (onDone != null)
          TextButton(
            onPressed: onDone,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Continue', style: TextStyle(fontSize: 12)),
          ),
      ],
    );
  }
}

enum _ChoiceState { idle, correct, wrong, dimmed }

class _ChoiceCard extends StatelessWidget {
  final String text;
  final _ChoiceState state;
  final bool italic;
  final VoidCallback? onTap;

  const _ChoiceCard({
    required this.text,
    required this.state,
    this.italic = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color? bg, Color border) = switch (state) {
      _ChoiceState.idle => (scheme.surface, scheme.outlineVariant),
      _ChoiceState.correct => (Colors.green.withValues(alpha: 0.15), Colors.green),
      _ChoiceState.wrong => (Colors.red.withValues(alpha: 0.13), Colors.red),
      _ChoiceState.dimmed => (null, scheme.outlineVariant.withValues(alpha: 0.4)),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border, width: state == _ChoiceState.idle ? 1 : 1.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontStyle: italic ? FontStyle.italic : FontStyle.normal,
              color: state == _ChoiceState.dimmed
                  ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final bool wrong;
  final VoidCallback onTap;

  const _Chip({required this.text, required this.wrong, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: wrong ? Colors.red.withValues(alpha: 0.15) : scheme.surface,
          border: Border.all(color: wrong ? Colors.red : scheme.outlineVariant),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}

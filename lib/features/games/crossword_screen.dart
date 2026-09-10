import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/repositories/crossword_repository.dart';
import '../../domain/crossword/crossword_models.dart';

String _cellKey(int row, int col) => '$row,$col';

/// How much of the grid a reveal hands over.
enum _RevealScope { letter, word, puzzle }

class CrosswordScreen extends ConsumerStatefulWidget {
  final CrosswordDifficulty difficulty;

  /// A specific past generation opened from history, or null for the current
  /// puzzle — the newest one generated for today.
  final int? puzzleId;

  const CrosswordScreen({super.key, required this.difficulty, this.puzzleId});

  @override
  ConsumerState<CrosswordScreen> createState() => _CrosswordScreenState();
}

class _CrosswordScreenState extends ConsumerState<CrosswordScreen> {
  /// The puzzle row currently on screen. Null until the session loads, since
  /// a puzzle for today may still be being generated.
  int? _puzzleId;
  String _date = CrosswordRepository.today();

  /// Whether this is the puzzle a "Start new" would replace — the newest one
  /// for today. Only that one gets the regenerate action and the editorial
  /// pass.
  bool _isCurrent = false;

  CrosswordSessionKey get _sessionKey =>
      (difficulty: widget.difficulty, puzzleId: widget.puzzleId);
  final _focusNode = FocusNode();
  // Kept at a single sentinel space so onChanged always fires on both a
  // keystroke (text becomes 2 chars) and backspace (text becomes empty) —
  // the standard trick for capturing per-cell input without raw key events.
  final _controller = TextEditingController(text: ' ');

  // Tracks the exact session object _prepare() last ran against — not a
  // bool — because Riverpod keeps serving the *previous* session (the same
  // object, isLoading=true) for a moment right after invalidate(), before
  // the freshly-generated one resolves. AsyncValue.when() calls `data:` for
  // that in-between state too, so a plain "have I prepared yet" flag would
  // fire once on the stale object and then refuse to fire again once the
  // real new puzzle arrives. Comparing object identity tells stale-reload
  // apart from genuinely-new.
  CrosswordSession? _preparedSession;
  Map<String, ({CrosswordWordPlacement? across, CrosswordWordPlacement? down})> _cellWords = {};
  Map<String, String> _answers = {};
  List<CrosswordWordPlacement> _clueOrder = [];

  final Map<String, String> _filled = {};
  final Set<String> _wrongCells = {};

  /// Grid-form answers with at least one cell the user was given rather than
  /// worked out. These are deliberately *not* held back from future puzzles:
  /// a revealed answer was not discovered, so it must come back, because the
  /// user still needs to learn it (PORTING_SPEC.md §6.2a).
  final Set<String> _revealedAnswers = {};

  /// Study words already credited to the SRS this session, so a card can't be
  /// graded twice for the same puzzle.
  final Set<int> _creditedEntryIds = {};

  /// The last solve event written, so a keystroke that changes nothing about
  /// what the user has worked out doesn't write one.
  Set<String> _recordedSolved = {};
  Set<String> _recordedRevealed = {};

  String? _selectedCell;
  CrosswordDirection _direction = CrosswordDirection.across;
  bool _completed = false;
  bool _reviewRequested = false;

  /// What the editorial pass is doing to *this* puzzle, for the status strip.
  /// Empty until the session has loaded and the decision has been made.
  String _reviewStatus = '';

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _prepare(CrosswordPuzzle puzzle, CrosswordSession session) {
    if (identical(_preparedSession, session)) return;
    _preparedSession = session;
    _puzzleId = session.id;
    _date = session.date;
    _isCurrent = widget.puzzleId == null;

    final cellWords = <String, ({CrosswordWordPlacement? across, CrosswordWordPlacement? down})>{};
    final answers = <String, String>{};
    for (final word in puzzle.words) {
      final cells = word.cells;
      for (var i = 0; i < cells.length; i++) {
        final key = _cellKey(cells[i].$1, cells[i].$2);
        answers[key] = word.answer[i];
        final existing = cellWords[key];
        cellWords[key] = word.direction == CrosswordDirection.across
            ? (across: word, down: existing?.down)
            : (across: existing?.across, down: word);
      }
    }
    _cellWords = cellWords;
    _answers = answers;
    _clueOrder = [...puzzle.across, ...puzzle.down];
    _filled.addAll(session.progress);
    _revealedAnswers
      ..clear()
      ..addAll(session.revealed);
    _completed = session.completed;
    if (puzzle.words.isNotEmpty) {
      final first = puzzle.words.first;
      _selectedCell = _cellKey(first.row, first.col);
      _direction = first.direction;
    }
    _maybeReview(puzzle);
  }

  /// Runs the editorial pass (PORTING_SPEC.md §9.3) off the click path.
  ///
  /// The puzzle on screen is already valid and playable; this only ever
  /// upgrades it. It is started **after** the grid is showing, and its result
  /// is applied only while the user hasn't entered anything — swapping clues
  /// under someone mid-solve would be worse than never improving them. If
  /// they start typing first, the revision is still saved and shows next time
  /// the puzzle is opened.
  void _maybeReview(CrosswordPuzzle puzzle) {
    final puzzleId = _puzzleId;
    if (_reviewRequested || puzzleId == null || !_isCurrent || _completed) return;
    if (_filled.isNotEmpty) return;
    _reviewRequested = true;

    if (puzzle.reviewed) {
      setState(() => _reviewStatus = 'already_reviewed');
      return;
    }
    setState(() => _reviewStatus = 'running');

    // Deliberately not awaited: ~15 seconds, measured, and flat in puzzle
    // size. Nothing on screen waits for it.
    () async {
      final report = await ref
          .read(crosswordRepositoryProvider)
          .reviewInBackground(puzzleId, widget.difficulty, _date, puzzle);
      if (!mounted) return;
      setState(() => _reviewStatus = report.status);

      // The history screen shows what the run cost, so refresh it either way
      // — a failed or edit-free review is a row too.
      ref.invalidate(crosswordHistoryProvider(widget.difficulty));
      ref.invalidate(crosswordReviewTotalsProvider(widget.difficulty));
      ref.invalidate(crosswordPuzzleReviewsProvider(puzzleId));

      if (report.revised == null || _filled.isNotEmpty || _completed) return;
      ref.invalidate(crosswordSessionProvider(_sessionKey));
      final run = report.run;
      if (run != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('AI editor rewrote ${run.cluesApplied + run.wordsApplied} '
              'clue${run.cluesApplied + run.wordsApplied == 1 ? '' : 's'}'),
          duration: const Duration(seconds: 3),
        ));
      }
    }();
  }

  CrosswordWordPlacement? get _activeWord {
    final cell = _selectedCell;
    if (cell == null) return null;
    final words = _cellWords[cell];
    if (words == null) return null;
    return _direction == CrosswordDirection.across ? (words.across ?? words.down) : (words.down ?? words.across);
  }

  void _selectCell(String key) {
    final words = _cellWords[key];
    if (words == null) return;
    setState(() {
      if (_selectedCell == key) {
        // Tapping the already-selected cell toggles direction, if the
        // other direction actually has a word through this cell.
        if (_direction == CrosswordDirection.across && words.down != null) {
          _direction = CrosswordDirection.down;
        } else if (_direction == CrosswordDirection.down && words.across != null) {
          _direction = CrosswordDirection.across;
        }
      } else {
        _selectedCell = key;
        _direction = words.across != null
            ? (words.down != null && _direction == CrosswordDirection.down
                ? CrosswordDirection.down
                : CrosswordDirection.across)
            : CrosswordDirection.down;
      }
      _wrongCells.clear();
    });
    _showKeyboard();
  }

  void _selectWord(CrosswordWordPlacement word) {
    setState(() {
      _selectedCell = _cellKey(word.row, word.col);
      _direction = word.direction;
      _wrongCells.clear();
    });
    _showKeyboard();
  }

  // Once the keyboard's been dismissed (system back, or its own dismiss
  // control), Flutter's FocusNode can still think it holds focus even
  // though the platform IME session is gone — so a plain requestFocus() on
  // an already-"focused" node is a no-op and the keyboard never comes back.
  // Explicitly asking the platform to show the IME sidesteps that.
  void _showKeyboard() {
    if (_focusNode.hasFocus) {
      SystemChannels.textInput.invokeMethod('TextInput.show');
    } else {
      _focusNode.requestFocus();
    }
  }

  void _advance({required bool backward}) {
    final word = _activeWord;
    final cell = _selectedCell;
    if (word == null || cell == null) return;
    final cells = word.cells;
    final index = cells.indexWhere((c) => _cellKey(c.$1, c.$2) == cell);
    if (index == -1) return;
    if (backward) {
      final prevIndex = index - 1;
      if (prevIndex >= 0) {
        setState(() => _selectedCell = _cellKey(cells[prevIndex].$1, cells[prevIndex].$2));
      }
      return;
    }
    // Skip past cells this word already has letters in (typically filled by
    // a crossing word already solved) and land on the next empty one, the
    // standard crossword "type-through" feel — jumps to the next word
    // entirely once every remaining cell in this one is already filled.
    for (var i = index + 1; i < cells.length; i++) {
      final key = _cellKey(cells[i].$1, cells[i].$2);
      if (_filled[key] == null) {
        setState(() => _selectedCell = key);
        return;
      }
    }
    _jumpToNextWord(word);
  }

  void _jumpToNextWord(CrosswordWordPlacement current) {
    final index = _clueOrder.indexOf(current);
    if (index == -1 || _clueOrder.length <= 1) return;
    _selectWord(_clueOrder[(index + 1) % _clueOrder.length]);
  }

  void _onTextChanged(String value) {
    if (value == ' ') return; // our own programmatic reset — ignore
    final cell = _selectedCell;
    if (cell == null) {
      _resetSentinel();
      return;
    }
    if (value.isEmpty) {
      // Backspace: clear the current cell if it has a letter, otherwise
      // step back a cell (standard "backspace through the word" feel).
      setState(() {
        if (_filled[cell] != null) {
          _filled.remove(cell);
        } else {
          _advance(backward: true);
        }
        _wrongCells.clear();
      });
    } else {
      final letter = value[value.length - 1].toUpperCase();
      if (RegExp(r'^[A-Z]$').hasMatch(letter)) {
        setState(() {
          _filled[cell] = letter;
          _wrongCells.clear();
        });
        _advance(backward: false);
        _checkCompletion();
      }
    }
    _saveProgress();
    _resetSentinel();
  }

  void _resetSentinel() {
    _controller.value = const TextEditingValue(text: ' ', selection: TextSelection.collapsed(offset: 1));
  }

  void _saveProgress() {
    final repository = ref.read(crosswordRepositoryProvider);
    final puzzleId = _puzzleId;
    if (puzzleId == null) return;
    repository.saveProgress(puzzleId, Map.of(_filled));
    // Recorded as they play, not only at completion: a puzzle they solve most
    // of and then abandon still taught them those answers, and the cooldown
    // is meant to reflect what they know (PORTING_SPEC.md §6.2a). Most
    // keystrokes finish no answer, so only a change is written.
    final solved = _correctAnswers();
    if (!setEquals(solved, _recordedSolved) ||
        !setEquals(_revealedAnswers, _recordedRevealed)) {
      _recordedSolved = solved;
      _recordedRevealed = Set.of(_revealedAnswers);
      repository.recordSolveState(
        puzzleId,
        widget.difficulty,
        _date,
        solved: _recordedSolved,
        revealed: _recordedRevealed,
      );
      _creditStudyWords();
    }
  }

  /// Whether this answer is finished, and so can be shown in its natural
  /// written form — solved, revealed, or the whole puzzle done.
  bool _showAnswerFor(CrosswordWordPlacement word) {
    if (_completed || _revealedAnswers.contains(word.answer)) return true;
    final cells = word.cells;
    for (var i = 0; i < cells.length; i++) {
      if (_filled[_cellKey(cells[i].$1, cells[i].$2)] != word.answer[i]) return false;
    }
    return true;
  }

  /// Answers whose every cell is filled in correctly.
  Set<String> _correctAnswers() {
    final solved = <String>{};
    for (final word in _clueOrder) {
      final cells = word.cells;
      var complete = true;
      for (var i = 0; i < cells.length; i++) {
        if (_filled[_cellKey(cells[i].$1, cells[i].$2)] != word.answer[i]) {
          complete = false;
          break;
        }
      }
      if (complete) solved.add(word.answer);
    }
    return solved;
  }

  /// Feeds an unaided crossword solve back to the SRS.
  ///
  /// Working a word out from a clue and its crossings is a genuine retrieval
  /// event for that word, which is exactly what the schedule wants to know
  /// (APP_INTEGRATION.md §3). A word with any revealed cell was not retrieved
  /// and is not credited.
  void _creditStudyWords() {
    final solved = _correctAnswers();
    final earned = <int>[];
    for (final word in _clueOrder) {
      if (!word.fromStudyPool || word.entryId < 0) continue;
      if (!solved.contains(word.answer)) continue;
      if (_revealedAnswers.contains(word.answer)) continue;
      if (!_creditedEntryIds.add(word.entryId)) continue;
      earned.add(word.entryId);
    }
    if (earned.isEmpty) return;
    ref.read(crosswordRepositoryProvider).creditStudyWords(earned);
  }

  void _checkCompletion() {
    if (_completed) return;
    if (_answers.isEmpty) return;
    final solved = _answers.entries.every((e) => _filled[e.key] == e.value);
    if (!solved) return;
    setState(() => _completed = true);
    final puzzleId = _puzzleId;
    if (puzzleId != null) ref.read(crosswordRepositoryProvider).markCompleted(puzzleId);
  }

  /// Fills in cells the user hasn't worked out, and records that they were
  /// given rather than solved.
  ///
  /// [scope] of `letter` fills the selected cell, `word` the selected entry,
  /// `puzzle` everything. Every answer touching a filled-in cell is marked
  /// revealed — a partially revealed answer was still not discovered unaided,
  /// so it is not held back from later puzzles.
  void _reveal(_RevealScope scope) {
    final targets = <(int, int)>[];
    switch (scope) {
      case _RevealScope.letter:
        final cell = _selectedCell;
        if (cell == null) return;
        final parts = cell.split(',');
        targets.add((int.parse(parts[0]), int.parse(parts[1])));
      case _RevealScope.word:
        final word = _activeWord;
        if (word == null) return;
        targets.addAll(word.cells);
      case _RevealScope.puzzle:
        for (final word in _clueOrder) {
          targets.addAll(word.cells);
        }
    }

    setState(() {
      for (final target in targets) {
        final key = _cellKey(target.$1, target.$2);
        final answer = _answers[key];
        if (answer == null) continue;
        if (_filled[key] == answer) continue; // already correct: no help given
        _filled[key] = answer;
        final words = _cellWords[key];
        for (final word in [words?.across, words?.down]) {
          if (word != null) _revealedAnswers.add(word.answer);
        }
      }
      _wrongCells.clear();
    });
    _saveProgress();
    _checkCompletion();
  }

  void _check() {
    setState(() {
      _wrongCells
        ..clear()
        ..addAll(_answers.entries.where((e) => _filled[e.key] != null && _filled[e.key] != e.value).map((e) => e.key));
    });
  }

  Future<void> _regenerate() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Start a new puzzle?'),
            content: const Text('This replaces today\'s puzzle. Any progress on it will be lost.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Start new')),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    await ref.read(crosswordRepositoryProvider).regenerate(widget.difficulty);
    if (!mounted) return;
    ref.invalidate(crosswordSessionProvider(_sessionKey));
    // _prepare() re-runs on its own once the freshly generated session
    // actually arrives (see _preparedSession) — this just clears leftover
    // local state so nothing from the old puzzle briefly shows through.
    setState(() {
      _filled.clear();
      _wrongCells.clear();
      _revealedAnswers.clear();
      _creditedEntryIds.clear();
      _recordedSolved = {};
      _recordedRevealed = {};
      _reviewRequested = false;
      _completed = false;
      _selectedCell = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessionAsync = ref.watch(crosswordSessionProvider(_sessionKey));

    return Scaffold(
      // The grid's size is driven by screen width, not by whatever height
      // is left after the keyboard opens — letting the Scaffold resize for
      // the keyboard would squeeze that fixed-size content below the
      // available height and overflow. The real input target is the
      // invisible TextField, not something the user needs to see above the
      // keyboard, so keeping the body full-height and letting the keyboard
      // simply overlay the clue list is the correct fix, not a workaround.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(widget.puzzleId == null
            ? '${widget.difficulty.label} Crossword'
            : '${widget.difficulty.label} · $_date'),
        actions: [
          if (sessionAsync.valueOrNull != null) _StudyPoolBadge(puzzle: sessionAsync.valueOrNull!.puzzle),
          if (sessionAsync.valueOrNull != null)
            IconButton(icon: const Icon(Icons.fact_check_outlined), tooltip: 'Check', onPressed: _check),
          if (sessionAsync.valueOrNull != null)
            PopupMenuButton<_RevealScope>(
              icon: const Icon(Icons.visibility_outlined),
              tooltip: 'Reveal',
              onSelected: _reveal,
              itemBuilder: (context) => const [
                PopupMenuItem(value: _RevealScope.letter, child: Text('Reveal letter')),
                PopupMenuItem(value: _RevealScope.word, child: Text('Reveal word')),
                PopupMenuItem(value: _RevealScope.puzzle, child: Text('Reveal puzzle')),
              ],
            ),
          if (widget.puzzleId == null)
            IconButton(icon: const Icon(Icons.refresh), tooltip: 'New puzzle', onPressed: _regenerate),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: () => context.push('/games/crossword/${widget.difficulty.storageKey}/history'),
          ),
        ],
      ),
      body: sessionAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t build a puzzle: $e')),
        data: (session) {
          if (session == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.extension_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 16),
                    Text(
                      widget.puzzleId == null ? 'Not enough words yet' : 'Puzzle not found',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.puzzleId == null
                          ? 'Add more words to your study pool to unlock this puzzle size.'
                          : 'This puzzle has been deleted.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            );
          }
          _prepare(session.puzzle, session);
          return _PuzzleBody(state: this, puzzle: session.puzzle);
        },
      ),
    );
  }
}

/// Corner counter showing how many of today's words came from the user's
/// SRS study pool rather than generic dictionary filler.
class _StudyPoolBadge extends StatelessWidget {
  final CrosswordPuzzle puzzle;

  const _StudyPoolBadge({required this.puzzle});

  @override
  Widget build(BuildContext context) {
    final count = puzzle.words.where((w) => w.fromStudyPool).length;
    if (count == 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(
        message: '$count word${count == 1 ? '' : 's'} from your study list',
        child: Chip(
          avatar: Icon(Icons.school_outlined, size: 16, color: scheme.primary),
          label: Text('$count', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
          visualDensity: VisualDensity.compact,
          backgroundColor: scheme.primaryContainer.withValues(alpha: 0.5),
          side: BorderSide.none,
        ),
      ),
    );
  }
}

class _PuzzleBody extends StatelessWidget {
  final _CrosswordScreenState state;
  final CrosswordPuzzle puzzle;

  const _PuzzleBody({required this.state, required this.puzzle});

  @override
  Widget build(BuildContext context) {
    final activeWord = state._activeWord;
    return Column(
      children: [
        if (state._completed)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.primaryContainer,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'Solved it! 🎉',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        _ReviewStrip(state: state, puzzle: puzzle),
        if (activeWord != null) _ClueBar(state: state, word: activeWord),
        Padding(
          padding: const EdgeInsets.all(12),
          child: _CrosswordGrid(state: state, puzzle: puzzle),
        ),
        // Off-screen but focusable/visible-to-IME field that drives all
        // keyboard input for the selected cell — see _onTextChanged.
        SizedBox(
          width: 1,
          height: 1,
          child: Opacity(
            opacity: 0,
            child: TextField(
              controller: state._controller,
              focusNode: state._focusNode,
              onChanged: state._onTextChanged,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
            ),
          ),
        ),
        Expanded(child: _ClueLists(state: state, puzzle: puzzle)),
      ],
    );
  }
}

class _ClueBar extends StatelessWidget {
  final _CrosswordScreenState state;
  final CrosswordWordPlacement word;

  const _ClueBar({required this.state, required this.word});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => state._jumpToNextWord(_previousOf(word)),
          ),
          Expanded(
            child: Text(
              '${word.number}${word.direction == CrosswordDirection.across ? 'A' : 'D'}. ${word.clue}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => state._jumpToNextWord(word)),
        ],
      ),
    );
  }

  CrosswordWordPlacement _previousOf(CrosswordWordPlacement current) {
    final order = state._clueOrder;
    final index = order.indexOf(current);
    if (index <= 0) return order.isEmpty ? current : order.last;
    return order[(index - 1 + order.length) % order.length];
  }
}

class _CrosswordGrid extends StatelessWidget {
  final _CrosswordScreenState state;
  final CrosswordPuzzle puzzle;

  const _CrosswordGrid({required this.state, required this.puzzle});

  @override
  Widget build(BuildContext context) {
    final numbers = <String, int>{};
    for (final w in puzzle.words) {
      numbers[_cellKey(w.row, w.col)] = w.number;
    }
    final activeWordCells = state._activeWord?.cells.map((c) => _cellKey(c.$1, c.$2)).toSet() ?? {};

    return LayoutBuilder(
      builder: (context, constraints) {
        final cellSize = constraints.maxWidth / puzzle.width;
        return SizedBox(
          width: cellSize * puzzle.width,
          height: cellSize * puzzle.height,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var r = 0; r < puzzle.height; r++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var c = 0; c < puzzle.width; c++)
                      _Cell(
                        size: cellSize,
                        letter: state._answers.containsKey(_cellKey(r, c)) ? state._filled[_cellKey(r, c)] : null,
                        number: numbers[_cellKey(r, c)],
                        blocked: !state._answers.containsKey(_cellKey(r, c)),
                        selected: state._selectedCell == _cellKey(r, c),
                        inActiveWord: activeWordCells.contains(_cellKey(r, c)),
                        wrong: state._wrongCells.contains(_cellKey(r, c)),
                        onTap: () => state._selectCell(_cellKey(r, c)),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Cell extends StatelessWidget {
  final double size;
  final String? letter;
  final int? number;
  final bool blocked;
  final bool selected;
  final bool inActiveWord;
  final bool wrong;
  final VoidCallback onTap;

  const _Cell({
    required this.size,
    required this.letter,
    required this.number,
    required this.blocked,
    required this.selected,
    required this.inActiveWord,
    required this.wrong,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (blocked) {
      return SizedBox(width: size, height: size, child: ColoredBox(color: scheme.onSurface.withValues(alpha: 0.85)));
    }
    Color background = scheme.surface;
    if (selected) {
      background = scheme.primary.withValues(alpha: 0.35);
    } else if (inActiveWord) {
      background = scheme.primary.withValues(alpha: 0.12);
    }
    if (wrong) background = Colors.red.withValues(alpha: 0.25);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: background, border: Border.all(color: scheme.outlineVariant, width: 0.5)),
        child: Stack(
          children: [
            if (number != null)
              Positioned(
                left: 2,
                top: 1,
                child: Text('$number', style: TextStyle(fontSize: size * 0.22, color: scheme.onSurfaceVariant)),
              ),
            Center(
              child: Text(
                letter ?? '',
                style: TextStyle(fontSize: size * 0.5, fontWeight: FontWeight.w600, color: scheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClueLists extends StatelessWidget {
  final _CrosswordScreenState state;
  final CrosswordPuzzle puzzle;

  const _ClueLists({required this.state, required this.puzzle});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _ClueSection(title: 'Across', words: puzzle.across, state: state),
        _ClueSection(title: 'Down', words: puzzle.down, state: state),
      ],
    );
  }
}

class _ClueSection extends StatelessWidget {
  final String title;
  final List<CrosswordWordPlacement> words;
  final _CrosswordScreenState state;

  const _ClueSection({required this.title, required this.words, required this.state});

  @override
  Widget build(BuildContext context) {
    if (words.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.labelLarge),
        ),
        for (final w in words)
          ListTile(
            dense: true,
            selected: state._activeWord == w,
            onTap: () => state._selectWord(w),
            title: Text('${w.number}. ${w.clue}'),
            // The natural form of a finished answer, once it can't help:
            // the grid can only spell IDOS, and a solver shown that alone
            // has been told less than the clue assumed.
            subtitle: state._showAnswerFor(w) && w.display.toUpperCase() != w.answer
                ? Text(w.display, style: Theme.of(context).textTheme.bodySmall)
                : null,
          ),
      ],
    );
  }
}

/// **Debug.** A one-line account of what the AI editor is doing to this
/// puzzle.
///
/// Without it the pass is invisible: it runs in the background, takes ~15
/// seconds, and either silently improves the clues or silently does nothing —
/// so "is it even switched on?" was unanswerable from the screen you are
/// looking at. Tapping opens the history, where the tokens and cost are.
/// Remove this with the rest of the debug affordances before release.
class _ReviewStrip extends ConsumerWidget {
  final _CrosswordScreenState state;
  final CrosswordPuzzle puzzle;

  const _ReviewStrip({required this.state, required this.puzzle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final puzzleId = state._puzzleId;
    if (puzzleId == null) return const SizedBox.shrink();

    // A past puzzle reports what was recorded against it; the current one
    // reports what is happening now.
    final runs = ref.watch(crosswordPuzzleReviewsProvider(puzzleId)).valueOrNull;
    final latest = (runs == null || runs.isEmpty) ? null : runs.first;
    final status = state._reviewStatus;

    final running = status == 'running';
    String text;
    IconData icon = Icons.auto_fix_high_outlined;

    if (running) {
      text = 'AI editor reviewing this puzzle…';
    } else if (latest != null) {
      final edits = latest.cluesApplied + latest.wordsApplied;
      text = switch (latest.outcome) {
        'applied' => 'AI editor rewrote $edits clue${edits == 1 ? '' : 's'} '
            '· ${(latest.costUsd * 100).toStringAsFixed(2)}¢',
        'no_edits' => 'AI editor reviewed it and changed nothing',
        'all_rejected' => 'AI editor\'s edits all failed verification',
        'not_applied' => 'AI editor finished too late to apply',
        'failed' => 'AI editor failed: ${latest.error}',
        _ => 'AI editor: ${latest.outcome}',
      };
      if (latest.outcome == 'failed') icon = Icons.error_outline;
    } else {
      text = switch (status) {
        'off' => 'AI editor is off — Settings › Developer',
        'no_key' => 'AI editor unavailable: no API key in this build',
        'unsupported' => 'AI editor can\'t review a puzzle this old',
        'already_reviewed' => 'AI editor has already reviewed this puzzle',
        '' => '',
        _ => 'AI editor: $status',
      };
      if (status == 'off' || status == 'no_key') icon = Icons.auto_fix_off_outlined;
    }

    if (text.isEmpty) return const SizedBox.shrink();

    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: InkWell(
        onTap: () => context.push(
            '/games/crossword/${state.widget.difficulty.storageKey}/history'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            children: [
              if (running)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(icon, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              Icon(Icons.chevron_right, size: 15, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

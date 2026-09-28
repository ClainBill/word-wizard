import 'dart:math' show max, min;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/games/active_clock.dart';
import '../../domain/games/daily_limit.dart';
import 'daily_limit_dialog.dart';
import '../../data/repositories/crossword_repository.dart';
import '../../domain/crossword/crossword_models.dart';
import '../../domain/premium/premium.dart' show sampleWithoutEditorNote;
import '../premium/paywall_screen.dart' show showPaywall;
import '../progress/progress_format.dart';

String _cellKey(int row, int col) => '$row,$col';

/// What the help menu can do. Checks only point out wrong letters; reveals
/// fill letters in and mark the puzzle as helped.
enum _Help { checkLetter, checkWord, checkPuzzle, revealLetter, revealWord, revealPuzzle }

class CrosswordScreen extends ConsumerStatefulWidget {
  final CrosswordDifficulty difficulty;

  /// A specific past generation opened from history, or null for the current
  /// puzzle — the newest one generated for today.
  final int? puzzleId;

  const CrosswordScreen({super.key, required this.difficulty, this.puzzleId});

  @override
  ConsumerState<CrosswordScreen> createState() => _CrosswordScreenState();
}

class _CrosswordScreenState extends ConsumerState<CrosswordScreen>
    with WidgetsBindingObserver {
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
  /// worked out — through the help menu's reveals. Any at all marks the
  /// puzzle as helped: it scores nothing on either leaderboard and is left
  /// out of best times. Those answers are deliberately *not* held back
  /// from future puzzles: a
  /// revealed answer was not discovered, so it must come back, because the
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

  /// How the cursor moves after a letter is typed. Tapping a cell that
  /// already has a letter means "I'm changing this word": the cursor steps
  /// through every box in turn, filled or not. Tapping an empty cell means
  /// "I'm filling this in": the cursor skips boxes crossings have already
  /// filled and lands on the next empty one.
  bool _overwrite = false;
  bool _completed = false;
  bool _reviewRequested = false;

  /// Active solving time. [_bankedMs] is what earlier sittings already
  /// recorded; [_clock] runs only while the grid is on screen and the app
  /// is in front, so a puzzle left open overnight doesn't clock the night.
  /// Together they are what gets written to the play record.
  int _bankedMs = 0;
  final ActiveClock _clock = ActiveClock();

  int get _activeMs => _bankedMs + _clock.elapsedMilliseconds;

  /// The board's pan/zoom. The grid always spans the full width — never
  /// letterboxed — and is taller than its viewport when the puzzle is big
  /// or the keyboard is up, so at scale 1 it scrolls vertically; pinching
  /// zooms in on a region. [_followSelection] keeps the cell being typed
  /// into on screen either way.
  final TransformationController _board = TransformationController();

  /// The grid's cell size and the viewport it's shown through, in scene
  /// coordinates — set by [_BoardViewport] on layout, read when following
  /// the selection.
  ({double cell, Size grid, Size viewport, double hiddenBottom})? _boardMetrics;

  /// Where the board viewport's bottom edge sits on screen, measured after
  /// layout. The body never resizes for the keyboard (see `build`), so this
  /// is stable and lets the keyboard's overlap with the board be worked out
  /// from the view insets alone.
  final GlobalKey _viewportKey = GlobalKey();
  double? _viewportBottomOnScreen;

  /// The viewport's screen position just changed; rebuild so the keyboard
  /// overlap is recomputed from it.
  void _remeasured() {
    if (mounted) setState(() {});
  }

  /// What the last follow was for, so a rebuild that changes neither the
  /// selection nor the viewport doesn't pan the board around under a
  /// finger that is dragging it.
  ({String cell, Size viewport, double hiddenBottom})? _followed;

  /// Pans the board so the selected cell is in view — after a tap on a
  /// cell or a clue, after typing advances the cursor, and after the
  /// keyboard shrinks the viewport. Only moves when the cell is actually
  /// out of view, and then centres it, so the board stays put while a word
  /// is typed across the visible part. Runs after the frame that changed
  /// things, so it never fights the layout.
  void _followSelection() {
    final metrics = _boardMetrics;
    final cell = _selectedCell;
    if (metrics == null || cell == null) return;
    final key = (cell: cell, viewport: metrics.viewport, hiddenBottom: metrics.hiddenBottom);
    if (_followed == key) return;
    _followed = key;

    // The part of the viewport the keyboard isn't covering. The board keeps
    // its size when the keyboard comes up; it is panned so the cell being
    // typed into sits in this strip instead.
    final visibleHeight = max(metrics.cell, metrics.viewport.height - metrics.hiddenBottom);

    final scale = _board.value.getMaxScaleOnAxis();
    final parts = cell.split(',');
    final r = int.parse(parts[0]);
    final c = int.parse(parts[1]);
    final target = Rect.fromLTWH(c * metrics.cell, r * metrics.cell, metrics.cell, metrics.cell);
    final t = _board.value.getTranslation();
    final visible = Rect.fromLTWH(
      -t.x / scale,
      -t.y / scale,
      metrics.viewport.width / scale,
      visibleHeight / scale,
    );
    if (visible.contains(target.topLeft) && visible.contains(target.bottomRight)) return;

    // Centre the cell in the visible strip, clamped so the board never pans
    // past its own edge — the lower bound is how far the scaled grid
    // overhangs the strip, which with the keyboard up lets a board that
    // fits the screen slide up under the app bar by up to the overlap.
    final minX = min(0.0, metrics.viewport.width - metrics.grid.width * scale);
    final minY = min(0.0, visibleHeight - metrics.grid.height * scale);
    final dx = (metrics.viewport.width / 2 - target.center.dx * scale).clamp(minX, 0.0);
    final dy = (visibleHeight / 2 - target.center.dy * scale).clamp(minY, 0.0);
    _board.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// Read once: `ref` can't be used from `dispose`, and that is exactly
  /// when the last play time has to be written.
  late final CrosswordRepository _repo;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(crosswordRepositoryProvider);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_completed && _puzzleId != null) _clock.start();
    } else {
      // Bank the time on the way out rather than the way back in: a killed
      // app never comes back to write it.
      _clock.stop();
      _flushPlayTime();
    }
  }

  void _flushPlayTime() {
    final puzzleId = _puzzleId;
    if (puzzleId == null || _completed) return;
    _repo.recordPlayTime(puzzleId, _activeMs, aided: _revealedAnswers.isNotEmpty);
  }

  /// What the editorial pass is doing to *this* puzzle, for the status strip.
  /// Empty until the session has loaded and the decision has been made.
  String _reviewStatus = '';

  @override
  void dispose() {
    _clock.stop();
    _clock.dispose();
    _flushPlayTime();
    WidgetsBinding.instance.removeObserver(this);
    _board.dispose();
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
    _bankedMs = session.activeMs;
    _clock
      ..stop()
      ..reset();
    if (!_completed) {
      // The clock starts when the clues are in front of them, not on the
      // first keystroke — reading the clues is solving too.
      ref.read(crosswordRepositoryProvider).startPlay(session.id, widget.difficulty);
      _clock.start();
    }
    if (_clueOrder.isNotEmpty) {
      // Start where the next letter belongs: the first clue with an empty
      // box (a resumed puzzle shouldn't open on an answer already in), or
      // the first clue if the grid is full.
      final start = _clueOrder.firstWhere(
        (w) => _firstEmptyCell(w) != null,
        orElse: () => _clueOrder.first,
      );
      _selectedCell = _firstEmptyCell(start) ?? _cellKey(start.row, start.col);
      _direction = start.direction;
      _overwrite = _firstEmptyCell(start) == null;
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

    // The free sample is played without the editorial pass — that's part
    // of what Premium buys, and the strip says so.
    if (!ref.read(isPremiumProvider)) {
      setState(() => _reviewStatus = 'sample');
      return;
    }

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
      _overwrite = _filled[key] != null;
      _wrongCells.clear();
    });
    _showKeyboard();
  }

  /// Selects [word] at the box that makes sense to type into: its first
  /// empty one, or — when it's already full — its first box, in overwrite
  /// mode.
  void _selectWord(CrosswordWordPlacement word) {
    final firstEmpty = _firstEmptyCell(word);
    setState(() {
      _selectedCell = firstEmpty ?? _cellKey(word.row, word.col);
      _direction = word.direction;
      _overwrite = firstEmpty == null;
      _wrongCells.clear();
    });
    _showKeyboard();
  }

  String? _firstEmptyCell(CrosswordWordPlacement word) {
    for (final c in word.cells) {
      final key = _cellKey(c.$1, c.$2);
      if (_filled[key] == null) return key;
    }
    return null;
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
    if (_overwrite) {
      // Changing a word: every box in turn, whatever it holds.
      if (index + 1 < cells.length) {
        setState(() => _selectedCell = _cellKey(cells[index + 1].$1, cells[index + 1].$2));
        return;
      }
    } else {
      // Filling a word in: skip past boxes crossings have already filled
      // (the standard "type-through" feel) and land on the next empty one.
      for (var i = index + 1; i < cells.length; i++) {
        final key = _cellKey(cells[i].$1, cells[i].$2);
        if (_filled[key] == null) {
          setState(() => _selectedCell = key);
          return;
        }
      }
    }
    // Off the end of this word: on to the next one that still needs
    // letters, rather than the next clue regardless — a finished word is
    // not where the next keystroke belongs.
    _jumpToNextUnfinishedWord(word);
  }

  /// The next clue in order — the clue bar's arrows, where "next" means
  /// the neighbour whether or not it's done.
  void _jumpToNextWord(CrosswordWordPlacement current) {
    final index = _clueOrder.indexOf(current);
    if (index == -1 || _clueOrder.length <= 1) return;
    _selectWord(_clueOrder[(index + 1) % _clueOrder.length]);
  }

  /// The next clue in order with an empty box, searching all the way round;
  /// falls back to the plain next clue when the grid is full.
  void _jumpToNextUnfinishedWord(CrosswordWordPlacement current) {
    final index = _clueOrder.indexOf(current);
    if (index == -1 || _clueOrder.length <= 1) return;
    for (var step = 1; step < _clueOrder.length; step++) {
      final candidate = _clueOrder[(index + step) % _clueOrder.length];
      if (_firstEmptyCell(candidate) != null) {
        _selectWord(candidate);
        return;
      }
    }
    _jumpToNextWord(current);
  }

  void _onTextChanged(String value) {
    _clock.touch();
    if (value == ' ') return; // our own programmatic reset — ignore
    final cell = _selectedCell;
    if (cell == null) {
      _resetSentinel();
      return;
    }
    if (value.isEmpty) {
      // Backspace: clear the current cell and step back one, so holding it
      // walks back through the word erasing as it goes. On an already
      // empty cell, step back and clear the one landed on.
      setState(() {
        final hadLetter = _filled.remove(cell) != null;
        _advance(backward: true);
        if (!hadLetter) _filled.remove(_selectedCell);
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
    _flushPlayTime();
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
    _clock.stop();
    final puzzleId = _puzzleId;
    if (puzzleId != null) {
      final repository = ref.read(crosswordRepositoryProvider);
      // Finish the play record before flipping _completed: the record's
      // writes are guarded on completed_at being null, and _flushPlayTime
      // on _completed, so the order keeps the finishing time exact.
      repository.completePlay(puzzleId, _activeMs, aided: _revealedAnswers.isNotEmpty);
      repository.markCompleted(puzzleId);
    }
    setState(() => _completed = true);
  }

  void _check() => _checkCells(_answers.keys);

  /// Marks the wrong letters among [cells]. A check never fills anything
  /// in, so it doesn't count as help.
  void _checkCells(Iterable<String> cells) {
    final wrong = [
      for (final key in cells)
        if (_filled[key] != null && _answers[key] != null && _filled[key] != _answers[key]) key,
    ];
    setState(() {
      _wrongCells
        ..clear()
        ..addAll(wrong);
    });
    if (wrong.isEmpty && mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing wrong so far.'), duration: Duration(seconds: 2)),
      );
    }
  }

  Future<void> _help(_Help action) async {
    final cell = _selectedCell;
    final word = _activeWord;
    switch (action) {
      case _Help.checkLetter:
        if (cell != null) _checkCells([cell]);
      case _Help.checkWord:
        if (word != null) _checkCells([for (final c in word.cells) _cellKey(c.$1, c.$2)]);
      case _Help.checkPuzzle:
        _check();
      case _Help.revealLetter:
        if (cell == null) return;
        final parts = cell.split(',');
        await _reveal('Reveal letter', [(int.parse(parts[0]), int.parse(parts[1]))]);
      case _Help.revealWord:
        if (word == null) return;
        await _reveal('Reveal word', word.cells);
      case _Help.revealPuzzle:
        await _reveal('Reveal puzzle', [for (final w in _clueOrder) ...w.cells]);
    }
  }

  /// Asks once, before the first reveal on a puzzle, whether to give up
  /// its score. Returns true when it's fine to go ahead — immediately if
  /// the puzzle is already helped or finished.
  Future<bool> _confirmHelp(String action) async {
    if (_revealedAnswers.isNotEmpty || _completed) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$action?'),
        content: const Text(
          'Revealing marks this puzzle as helped. It won\'t score any points on the '
          'leaderboards — yours or your group\'s — it\'s left out of your best times, '
          'and revealed answers aren\'t counted as learned.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep going')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(action)),
        ],
      ),
    );
    return ok == true && mounted;
  }

  /// Fills in the answer at each of [targets] the user hasn't already got
  /// right, and records that it was given rather than solved: every answer
  /// touching a filled-in cell is marked revealed — a partly revealed
  /// answer was still not discovered unaided.
  Future<void> _reveal(String action, List<(int, int)> targets) async {
    final needed = [
      for (final t in targets)
        if (_answers[_cellKey(t.$1, t.$2)] case final answer?
            when _filled[_cellKey(t.$1, t.$2)] != answer)
          _cellKey(t.$1, t.$2),
    ];
    if (needed.isEmpty) return; // already right: no help needed or given
    if (!await _confirmHelp(action)) return;
    setState(() {
      for (final key in needed) {
        _filled[key] = _answers[key]!;
        final words = _cellWords[key];
        for (final w in [words?.across, words?.down]) {
          if (w != null) _revealedAnswers.add(w.answer);
        }
      }
      _wrongCells.clear();
    });
    _saveProgress();
    _flushPlayTime();
    _checkCompletion();
  }

  /// A new seed, without the "replaces today's puzzle" confirmation:
  /// there is no puzzle to lose.
  Future<void> _retryGeneration() async {
    try {
      await ref.read(crosswordRepositoryProvider).regenerate(widget.difficulty);
    } on DailyPuzzleLimitReached catch (e) {
      if (mounted) await showDailyLimitDialog(context, e);
      return;
    }
    if (!mounted) return;
    ref.invalidate(crosswordSessionProvider(_sessionKey));
  }

  Future<void> _regenerate() async {
    final repo = ref.read(crosswordRepositoryProvider);
    final made = await repo.puzzlesToday(widget.difficulty);
    if (!mounted) return;
    if (made >= puzzlesPerDay) {
      await showDailyLimitDialog(context, DailyPuzzleLimitReached(widget.difficulty.label));
      return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Start a new puzzle?'),
            content: Text(
              'Today\'s puzzle stays in history with its progress. '
              '${made + 1 >= puzzlesPerDay ? 'This is your last new ${widget.difficulty.label} today.' : ''}',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Start new')),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    try {
      await repo.regenerate(widget.difficulty);
    } on DailyPuzzleLimitReached catch (e) {
      if (mounted) await showDailyLimitDialog(context, e);
      return;
    }
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
      _bankedMs = 0;
      _clock
        ..stop()
        ..reset();
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessionAsync = ref.watch(crosswordSessionProvider(_sessionKey));

    WidgetsBinding.instance.addPostFrameCallback((_) => _followSelection());

    return Scaffold(
      // The keyboard overlays the body rather than shrinking it, so the
      // board never changes size or gets cropped when typing starts. The
      // part of the board the keys cover is worked out in _BoardViewport and
      // the board is panned so the cell being typed into stays in view; the
      // clue bar above it stays visible throughout. Dismiss the keyboard to
      // get back to the clue list underneath.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(widget.puzzleId == null
            ? widget.difficulty.label
            : '${widget.difficulty.label} · $_date'),
        actions: [
          if (sessionAsync.valueOrNull != null) _StudyPoolBadge(puzzle: sessionAsync.valueOrNull!.puzzle),
          if (sessionAsync.valueOrNull != null)
            PopupMenuButton<_Help>(
              icon: Icon(
                _revealedAnswers.isEmpty ? Icons.lightbulb_outline : Icons.lightbulb,
              ),
              tooltip: _revealedAnswers.isEmpty ? 'Check and reveal' : 'Check and reveal (helped)',
              onSelected: _help,
              itemBuilder: (context) => [
                const PopupMenuItem(value: _Help.checkLetter, child: Text('Check letter')),
                const PopupMenuItem(value: _Help.checkWord, child: Text('Check word')),
                const PopupMenuItem(value: _Help.checkPuzzle, child: Text('Check puzzle')),
                const PopupMenuDivider(),
                PopupMenuItem(
                  enabled: false,
                  height: 28,
                  child: Text(
                    'Revealing marks the puzzle as helped — no points',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                const PopupMenuItem(value: _Help.revealLetter, child: Text('Reveal letter')),
                const PopupMenuItem(value: _Help.revealWord, child: Text('Reveal word')),
                const PopupMenuItem(value: _Help.revealPuzzle, child: Text('Reveal puzzle')),
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
      // Any touch or keystroke counts as activity for the play clock.
      body: Listener(
        onPointerDown: (_) => _clock.touch(),
        behavior: HitTestBehavior.translucent,
        child: sessionAsync.when(
        loading: () => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                widget.puzzleId == null
                    ? 'Building today\'s ${widget.difficulty.label}…'
                    : 'Loading…',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        error: (e, _) => Center(child: Text('Couldn\'t build a puzzle: $e')),
        data: (session) {
          if (session == null) {
            // A null from generation means the search ran out of time
            // before it found a fill — it never means the study pool is
            // short, since a puzzle needs no study words at all. Another
            // seed usually succeeds, so offer one.
            final fresh = widget.puzzleId == null;
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.extension_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 16),
                    Text(
                      fresh ? 'Couldn\'t build a puzzle' : 'Puzzle not found',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      fresh
                          ? 'The ${widget.difficulty.label} grid didn\'t fill in time. '
                              'Try again — a different grid usually works.'
                          : 'This puzzle has been deleted.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    if (fresh) ...[
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _retryGeneration,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }
          _prepare(session.puzzle, session);
          return _PuzzleBody(state: this, puzzle: session.puzzle);
        },
      ),
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
              state._activeMs > 0
                  ? 'Solved it in ${formatClock(Duration(milliseconds: state._activeMs))}'
                      '${state._revealedAnswers.isEmpty ? ' 🎉' : ' — with help, so no points'}'
                  : 'Solved it! 🎉',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        _ReviewStrip(state: state, puzzle: puzzle),
        if (activeWord != null) _ClueBar(state: state, word: activeWord),
        // The board and the clues share what's left, board first. A Mini
        // never needs all of its share and gives the rest back; a Mega
        // scrolls inside its share, following the cell being typed into.
        Flexible(
          flex: 11,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _BoardViewport(state: state, puzzle: puzzle),
          ),
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
        Flexible(flex: 9, child: _ClueLists(state: state, puzzle: puzzle)),
      ],
    );
  }
}

/// The grid as a board you look down on. Always the full width of the
/// screen — the cells are sized from it, so there is never blank space
/// either side — and shown through a viewport no taller than the space
/// left, so a big puzzle, or any puzzle with the keyboard up, scrolls
/// vertically. Pinch to zoom in, drag to pan; the selection is followed
/// automatically (see `_followSelection`).
class _BoardViewport extends StatelessWidget {
  final _CrosswordScreenState state;
  final CrosswordPuzzle puzzle;

  const _BoardViewport({required this.state, required this.puzzle});

  @override
  Widget build(BuildContext context) {
    // Read here so the keyboard's arrival rebuilds this widget: the body
    // doesn't resize for it, so nothing else would.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final screenHeight = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = constraints.maxWidth / puzzle.width;
        final grid = Size(constraints.maxWidth, cell * puzzle.height);
        final viewport = Size(constraints.maxWidth, min(constraints.maxHeight, grid.height));
        // How much of the viewport the keyboard covers. The bottom edge is
        // measured after the first layout and is stable, since the body
        // never resizes; until it's known the keyboard is assumed to cover
        // nothing, which is right for the first frame (no keyboard yet).
        final bottom = state._viewportBottomOnScreen;
        final hiddenBottom = bottom == null || keyboard == 0
            ? 0.0
            : (bottom - (screenHeight - keyboard)).clamp(0.0, viewport.height);
        state._boardMetrics =
            (cell: cell, grid: grid, viewport: viewport, hiddenBottom: hiddenBottom);
        // Scheduled from here, not only from the screen's build: the
        // keyboard's arrival changes these metrics without rebuilding the
        // screen, and that is exactly when the cell being typed into needs
        // bringing back into view.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final box = state._viewportKey.currentContext?.findRenderObject() as RenderBox?;
          if (box != null && box.hasSize) {
            final measured = box.localToGlobal(Offset(0, box.size.height)).dy;
            if (state._viewportBottomOnScreen != measured) {
              state._viewportBottomOnScreen = measured;
              // The overlap depends on it; with the keyboard already up
              // (opened before the first measurement landed) this is what
              // makes the first follow use the right strip.
              if (keyboard > 0) state._remeasured();
            }
          }
          state._followSelection();
        });
        return SizedBox(
          key: state._viewportKey,
          width: viewport.width,
          height: viewport.height,
          child: InteractiveViewer(
            transformationController: state._board,
            // The grid is bigger than the viewport, not fitted into it.
            constrained: false,
            minScale: 1,
            maxScale: 4,
            // Let the board be dragged up by as much as the keyboard hides,
            // so a pan doesn't snap the followed cell back under the keys.
            boundaryMargin: EdgeInsets.only(bottom: hiddenBottom),
            clipBehavior: Clip.hardEdge,
            child: _CrosswordGrid(state: state, puzzle: puzzle, cellSize: cell),
          ),
        );
      },
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
  final double cellSize;

  const _CrosswordGrid({required this.state, required this.puzzle, required this.cellSize});

  @override
  Widget build(BuildContext context) {
    final numbers = <String, int>{};
    for (final w in puzzle.words) {
      numbers[_cellKey(w.row, w.col)] = w.number;
    }
    final activeWordCells = state._activeWord?.cells.map((c) => _cellKey(c.$1, c.$2)).toSet() ?? {};

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

    if (status == 'sample') {
      // Tapping this strip opens the paywall, not the history.
      return _SampleStrip(text: sampleWithoutEditorNote);
    }
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

/// The free sample's version of the strip: what the AI editor would have
/// done, and the way to it.
class _SampleStrip extends StatelessWidget {
  final String text;

  const _SampleStrip({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: InkWell(
        onTap: () => showPaywall(context, source: 'crossword_sample'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            children: [
              Icon(Icons.auto_fix_off_outlined, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
              const SizedBox(width: 8),
              Text('Premium', style: TextStyle(fontSize: 12, color: scheme.primary)),
            ],
          ),
        ),
      ),
    );
  }
}

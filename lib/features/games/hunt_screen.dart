import 'dart:async';
import 'dart:math' show min, pi;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/repositories/hunt_repository.dart';
import '../../domain/hunt/hunt_models.dart';
import '../../domain/hunt/hunt_solver.dart' show huntNeighbours;
import '../progress/progress_format.dart';

/// The Word Hunt: trace words through a 4x4 letter board.
///
/// Everything the screen needs to judge a trace is in the puzzle's stored
/// answer sets — no dictionary lookup happens at play time, so a word the
/// board was certified with is accepted instantly and a word it wasn't is
/// refused just as fast, offline.
class HuntScreen extends ConsumerStatefulWidget {
  /// A past generation opened from history, or null for today's board.
  final int? puzzleId;

  const HuntScreen({super.key, this.puzzleId});

  @override
  ConsumerState<HuntScreen> createState() => _HuntScreenState();
}

enum _Verdict { required, bonus, duplicate, unknown, short }

class _HuntScreenState extends ConsumerState<HuntScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int? _puzzleId;
  String _date = '';
  HuntSession? _preparedSession;
  HuntPuzzle? _puzzle;

  final Set<String> _found = {};
  final Set<String> _revealed = {};
  bool _completed = false;

  /// The trace in progress, as board indices.
  final List<int> _path = [];
  bool _dragging = false;

  /// What the last submission was told, shown where the trace was.
  ({String text, _Verdict verdict})? _feedback;
  Timer? _feedbackTimer;

  /// Hint mode: per-tile counts of remaining required words starting there,
  /// and dimming of tiles no remaining word needs.
  bool _hints = false;

  /// Whether hints were ever used on this board. Persisted: like a reveal
  /// it makes the solve assisted, and that has to survive a restart.
  bool _hinted = false;

  bool get _aided => _hinted || _revealed.isNotEmpty;

  /// Quarter turns clockwise. View-only: paths and answers are stored in
  /// board coordinates.
  int _rotation = 0;

  /// The turn in progress: the grid spins through a quarter turn, then the
  /// permutation is applied and the angle snaps back to zero — which is
  /// visually the same frame, so nothing jumps.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  int _spinDirection = 1;

  void _rotate(int direction) {
    if (_spin.isAnimating) return;
    _spinDirection = direction;
    setState(() => _path.clear());
    _spin.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      setState(() {
        _rotation = (_rotation + direction) % 4;
        _spin.value = 0;
      });
    });
  }

  /// A word just revealed, drawn on the board for a moment.
  List<int>? _flashPath;
  Timer? _flashTimer;

  int _bankedMs = 0;
  final Stopwatch _clock = Stopwatch();
  int get _activeMs => _bankedMs + _clock.elapsedMilliseconds;

  /// Read once: `ref` can't be used from `dispose`, and that is exactly
  /// when the last play time has to be written.
  late final HuntRepository _repo;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(huntRepositoryProvider);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_completed && _puzzleId != null) _clock.start();
    } else {
      _clock.stop();
      _flushPlayTime();
    }
  }

  void _flushPlayTime() {
    final puzzleId = _puzzleId;
    if (puzzleId == null || _completed) return;
    _repo.recordPlayTime(puzzleId, _activeMs, aided: _aided);
  }

  @override
  void dispose() {
    _clock.stop();
    _flushPlayTime();
    _feedbackTimer?.cancel();
    _flashTimer?.cancel();
    _spin.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _prepare(HuntSession session) {
    if (identical(_preparedSession, session)) return;
    _preparedSession = session;
    _puzzleId = session.id;
    _date = session.date;
    _puzzle = session.puzzle;
    _found
      ..clear()
      ..addAll(session.found);
    _revealed
      ..clear()
      ..addAll(session.revealed);
    _hinted = session.hinted;
    _completed = session.completed;
    _bankedMs = session.activeMs;
    _path.clear();
    _feedback = null;
    _clock
      ..stop()
      ..reset();
    if (!_completed) {
      _repo.startPlay(session.id);
      _clock.start();
    }
  }

  // -------------------------------------------------------------------
  // Progress
  // -------------------------------------------------------------------

  Iterable<String> get _required sync* {
    final puzzle = _puzzle!;
    yield* puzzle.anchorWords.keys;
    yield* puzzle.main.keys;
  }

  int get _requiredFound => _required.where(_found.contains).length;

  int get _score => huntScore(_puzzle!, _found);

  int get _bonusFound => _found.where(_puzzle!.bonus.containsKey).length;

  Iterable<String> get _remaining => _required.where((w) => !_found.contains(w));

  void _save() {
    final puzzleId = _puzzleId;
    if (puzzleId == null) return;
    _repo.saveProgress(
      puzzleId,
      found: _found,
      revealed: _revealed,
      hinted: _hinted,
      completed: _completed,
    );
  }

  void _checkCompletion() {
    if (_completed || _remaining.isNotEmpty) return;
    _completed = true;
    _clock.stop();
    final puzzleId = _puzzleId;
    if (puzzleId != null) {
      _repo.completePlay(puzzleId, _activeMs, aided: _aided);
    }
    _save();
    HapticFeedback.heavyImpact();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showCompletion();
    });
  }

  void _showCompletion() {
    final puzzle = _puzzle!;
    final themeFound = puzzle.themeWords.where(_found.contains).length;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Board complete'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$_score points · ${formatClock(Duration(milliseconds: _activeMs))}'),
            const SizedBox(height: 6),
            Text(
              '${puzzle.requiredCount} words found'
              '${_bonusFound > 0 ? ', plus $_bonusFound bonus' : ''}'
              '${_revealed.isNotEmpty ? ' (${_revealed.length} revealed)' : ''}',
            ),
            if (puzzle.themeLabel != null) ...[
              const SizedBox(height: 6),
              Text('${puzzle.themeLabel}: $themeFound of ${puzzle.themeWords.length} theme words'),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // Tracing
  // -------------------------------------------------------------------

  String get _traced => [for (final c in _path) _puzzle!.board[c]].join();

  void _setFeedback(String text, _Verdict verdict) {
    _feedbackTimer?.cancel();
    _feedback = (text: text, verdict: verdict);
    _feedbackTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _feedback = null);
    });
  }

  void _submit() {
    final puzzle = _puzzle!;
    final word = _traced;
    _path.clear();
    _dragging = false;
    // A single tile is a slipped finger, not an attempt.
    if (word.length < 2) return;
    if (word.length < huntMinWordLength) {
      _setFeedback('Too short', _Verdict.short);
      return;
    }
    if (_found.contains(word)) {
      _setFeedback('Already found', _Verdict.duplicate);
      return;
    }
    final wordClass = puzzle.classify(word);
    if (wordClass == null) {
      _setFeedback('Not in word list', _Verdict.unknown);
      return;
    }
    _found.add(word);
    _revealed.remove(word);
    switch (wordClass) {
      case HuntWordClass.anchor:
        final anchor = puzzle.anchors.firstWhere((a) => a.text == word);
        HapticFeedback.mediumImpact();
        _setFeedback(
          '${anchor.kind == HuntAnchorKind.study ? 'Study word' : 'Theme word'}! +${word.length}',
          _Verdict.required,
        );
        if (anchor.kind == HuntAnchorKind.study) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showAnchor(anchor, found: true);
          });
        }
      case HuntWordClass.main:
        HapticFeedback.lightImpact();
        _setFeedback(
          puzzle.themeWords.contains(word) ? 'Theme word! +${word.length}' : '+${word.length}',
          _Verdict.required,
        );
      case HuntWordClass.bonus:
        _setFeedback('Bonus +1', _Verdict.bonus);
    }
    _save();
    _checkCompletion();
  }

  /// Extends the trace to [cell] if that is a legal next step; stepping
  /// back onto the previous cell retracts the last one.
  void _extend(int cell) {
    if (_path.isEmpty) {
      _path.add(cell);
      return;
    }
    if (_path.last == cell) return;
    if (_path.length >= 2 && _path[_path.length - 2] == cell) {
      _path.removeLast();
      return;
    }
    if (_path.contains(cell)) return;
    if (!huntNeighbours[_path.last].contains(cell)) return;
    _path.add(cell);
    HapticFeedback.selectionClick();
  }

  void _tap(int cell) {
    if (_completed) return;
    setState(() {
      _feedback = null;
      if (_path.isNotEmpty && _path.last == cell) {
        _submit();
      } else if (_path.isEmpty ||
          (!_path.contains(cell) && huntNeighbours[_path.last].contains(cell))) {
        _extend(cell);
      } else {
        _path
          ..clear()
          ..add(cell);
      }
    });
  }

  // -------------------------------------------------------------------
  // Hints and reveals
  // -------------------------------------------------------------------

  /// Asks once, before the first hint or reveal on a board, whether to
  /// give up the clean solve. Returns true when it's fine to go ahead —
  /// immediately if the board is already assisted or finished.
  Future<bool> _confirmAssist(String action) async {
    if (_aided || _completed) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$action?'),
        content: const Text(
          'Using hints or reveals marks this board as assisted: it won\'t count '
          'as a clean solve, and it\'s left out of your best times and scores.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep going'),
          ),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(action)),
        ],
      ),
    );
    return ok == true && mounted;
  }

  Future<void> _toggleHints() async {
    if (_hints) {
      setState(() => _hints = false);
      return;
    }
    if (!await _confirmAssist('Show hints')) return;
    setState(() {
      _hints = true;
      _hinted = true;
    });
    _save();
  }

  Future<void> _revealOne() async {
    if (!await _confirmAssist('Reveal a word')) return;
    final puzzle = _puzzle!;
    // Anchors first — they're the words the board exists for and the ones a
    // stuck player most wants to see — then the longest remaining word.
    final remaining = _remaining.toList();
    if (remaining.isEmpty) return;
    remaining.sort((a, b) {
      final aAnchor = puzzle.anchorWords.containsKey(a) ? 0 : 1;
      final bAnchor = puzzle.anchorWords.containsKey(b) ? 0 : 1;
      if (aAnchor != bAnchor) return aAnchor - bAnchor;
      return b.length - a.length;
    });
    final word = remaining.first;
    setState(() {
      _path.clear();
      _found.add(word);
      _revealed.add(word);
      _setFeedback(word, _Verdict.duplicate);
      _flash(puzzle.wordInfo(word)!.path);
    });
    _save();
    _checkCompletion();
  }

  Future<void> _revealAll() async {
    if (!await _confirmAssist('Reveal everything')) return;
    setState(() {
      _path.clear();
      for (final word in _remaining.toList()) {
        _found.add(word);
        _revealed.add(word);
      }
    });
    _save();
    _checkCompletion();
  }

  void _flash(List<int> path) {
    _flashTimer?.cancel();
    _flashPath = path;
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _flashPath = null);
    });
  }

  Future<void> _regenerate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New board?'),
        content: const Text('Today\'s board stays in history with its progress.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('New board'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _clock.stop();
    _flushPlayTime();
    await _repo.regenerate();
    ref.invalidate(huntSessionProvider(null));
    ref.invalidate(huntHistoryProvider);
  }

  void _showAnchor(HuntAnchor anchor, {required bool found}) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  anchor.kind == HuntAnchorKind.study
                      ? Icons.school_outlined
                      : Icons.category_outlined,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  anchor.kind == HuntAnchorKind.study
                      ? 'Study word'
                      : 'Theme word · ${_puzzle!.themeLabel ?? ''}',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.primary),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              found ? anchor.display : '${anchor.text.length} letters',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              anchor.clue ??
                  (anchor.kind == HuntAnchorKind.study
                      ? 'One of the words you\'re studying.'
                      : 'A word from today\'s theme.'),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (found && anchor.kind == HuntAnchorKind.study) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    this.context.push('/entry/${Uri.encodeComponent(anchor.display)}');
                  },
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('Open entry'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final sessionAsync = ref.watch(huntSessionProvider(widget.puzzleId));
    final loaded = sessionAsync.valueOrNull != null;
    // Back arrow + title + four compact icons + menu fits from about 380dp.
    final roomForHistory = MediaQuery.sizeOf(context).width >= 380;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.puzzleId == null ? 'Word Hunt' : 'Word Hunt · $_date'),
        titleSpacing: 0,
        actions: [
          if (loaded)
            IconButton(
              icon: const Icon(Icons.rotate_left),
              tooltip: 'Rotate left',
              visualDensity: VisualDensity.compact,
              onPressed: () => _rotate(-1),
            ),
          if (loaded)
            IconButton(
              icon: const Icon(Icons.rotate_right),
              tooltip: 'Rotate right',
              visualDensity: VisualDensity.compact,
              onPressed: () => _rotate(1),
            ),
          if (loaded)
            IconButton(
              icon: Icon(_hints ? Icons.lightbulb : Icons.lightbulb_outline),
              tooltip: 'Hints',
              visualDensity: VisualDensity.compact,
              onPressed: _toggleHints,
            ),
          // History gets its own button when the bar has room for it; on
          // a narrow phone it drops into the menu rather than squeezing the
          // title down to "Word …".
          if (roomForHistory)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'History',
              visualDensity: VisualDensity.compact,
              onPressed: () => context.push('/games/hunt/history'),
            ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) => switch (value) {
              'one' => _revealOne(),
              'all' => _revealAll(),
              'new' => _regenerate(),
              _ => context.push('/games/hunt/history'),
            },
            itemBuilder: (context) => [
              if (loaded && !_completed)
                const PopupMenuItem(value: 'one', child: Text('Reveal a word')),
              if (loaded && !_completed)
                const PopupMenuItem(value: 'all', child: Text('Reveal everything')),
              if (widget.puzzleId == null)
                const PopupMenuItem(value: 'new', child: Text('New board')),
              if (!roomForHistory) const PopupMenuItem(value: 'history', child: Text('History')),
            ],
          ),
        ],
      ),
      body: sessionAsync.when(
        loading: () => const _Loading(),
        error: (e, _) => Center(child: Text('Couldn\'t build a board: $e')),
        data: (session) {
          if (session == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No board could be built today. Try again in a moment.'),
              ),
            );
          }
          _prepare(session);
          return _body(context, session.puzzle);
        },
      ),
    );
  }

  Widget _body(BuildContext context, HuntPuzzle puzzle) {
    final scheme = Theme.of(context).colorScheme;
    final requiredTotal = puzzle.requiredCount;
    final requiredFound = _requiredFound;

    return LayoutBuilder(
      builder: (context, constraints) {
        // The board takes the width, capped so a tablet doesn't get tiles
        // the size of coasters, and never more than half the height so the
        // found-word list keeps room.
        final boardSize = min(constraints.maxWidth - 32, constraints.maxHeight * 0.5);
        return Column(
          children: [
            _TargetsStrip(
              puzzle: puzzle,
              found: _found,
              onTap: (anchor) => _showAnchor(anchor, found: _found.contains(anchor.text)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$requiredFound / $requiredTotal words'
                          '${_bonusFound > 0 ? '  ·  $_bonusFound bonus' : ''}',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: requiredTotal == 0 ? 0 : requiredFound / requiredTotal,
                            minHeight: 6,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    '$_score pts',
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 44,
              child: Center(
                child: _TraceLabel(traced: _traced, feedback: _feedback),
              ),
            ),
            SizedBox(
              width: boardSize,
              height: boardSize,
              child: AnimatedBuilder(
                animation: _spin,
                builder: (context, _) => _Board(
                  puzzle: puzzle,
                  path: _path,
                  flashPath: _flashPath,
                  rotation: _rotation,
                  // Quarter turn in progress, in turns: positive is clockwise.
                  spin: Curves.easeInOutCubic.transform(_spin.value) * 0.25 * _spinDirection,
                  hints: _hints,
                  remaining: _hints ? _remaining.toList() : const [],
                  enabled: !_completed && !_spin.isAnimating,
                  onTap: _tap,
                  onPanStart: (cell) => setState(() {
                    _feedback = null;
                    _dragging = true;
                    _path
                      ..clear()
                      ..add(cell);
                  }),
                  onPanMove: (cell) => setState(() => _extend(cell)),
                  onPanEnd: () => setState(() {
                    if (_dragging) _submit();
                    _dragging = false;
                  }),
                ),
              ),
            ),
            if (_hints)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: _RemainingByLength(remaining: _remaining.toList()),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: _FoundList(puzzle: puzzle, found: _found, revealed: _revealed),
            ),
            if (_completed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Completed in ${formatClock(Duration(milliseconds: _activeMs))}'
                  '${_aided ? ' with help' : ''}',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Building today\'s board…',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// The words the board was built around — study words and the theme —
/// as chips that show a hint on tap and the word once it's found.
class _TargetsStrip extends StatelessWidget {
  final HuntPuzzle puzzle;
  final Set<String> found;
  final void Function(HuntAnchor) onTap;

  const _TargetsStrip({required this.puzzle, required this.found, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = puzzle.themeLabel;
    if (puzzle.anchors.isEmpty && theme == null) return const SizedBox(height: 8);
    final themeFound = puzzle.themeWords.where(found.contains).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (theme != null)
            Chip(
              avatar: Icon(Icons.category_outlined, size: 16, color: scheme.secondary),
              label: Text('$theme  $themeFound/${puzzle.themeWords.length}'),
              visualDensity: VisualDensity.compact,
              side: BorderSide.none,
              backgroundColor: scheme.secondaryContainer.withValues(alpha: 0.5),
            ),
          for (final anchor in puzzle.anchors)
            ActionChip(
              avatar: Icon(
                found.contains(anchor.text)
                    ? Icons.check_circle
                    : anchor.kind == HuntAnchorKind.study
                    ? Icons.school_outlined
                    : Icons.category_outlined,
                size: 16,
                color: scheme.primary,
              ),
              label: Text(
                found.contains(anchor.text)
                    ? anchor.display
                    : '${anchor.kind == HuntAnchorKind.study ? 'Study' : 'Theme'} · ${anchor.text.length} letters',
                style: TextStyle(
                  fontWeight: found.contains(anchor.text) ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              visualDensity: VisualDensity.compact,
              side: BorderSide.none,
              backgroundColor: scheme.primaryContainer.withValues(
                alpha: found.contains(anchor.text) ? 0.7 : 0.35,
              ),
              onPressed: () => onTap(anchor),
            ),
        ],
      ),
    );
  }
}

class _TraceLabel extends StatelessWidget {
  final String traced;
  final ({String text, _Verdict verdict})? feedback;

  const _TraceLabel({required this.traced, required this.feedback});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fb = feedback;
    if (traced.isEmpty && fb != null) {
      final color = switch (fb.verdict) {
        _Verdict.required => scheme.primary,
        _Verdict.bonus => scheme.secondary,
        _Verdict.duplicate || _Verdict.short => scheme.onSurfaceVariant,
        _Verdict.unknown => scheme.error,
      };
      return Text(
        fb.text,
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: color),
      );
    }
    return Text(
      traced,
      style: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: 3,
        color: traced.isEmpty ? scheme.onSurfaceVariant : scheme.onSurface,
      ),
    );
  }
}

/// The 4x4 grid with its trace line. Input is a pan across the tiles (or
/// taps); the trace lives in the parent's state and comes in as [path].
class _Board extends StatelessWidget {
  final HuntPuzzle puzzle;
  final List<int> path;
  final List<int>? flashPath;
  final int rotation;

  /// Extra rotation being animated, in turns (0 when idle). The grid turns
  /// as a whole while each tile's letter counter-turns, so the letters
  /// stay upright throughout.
  final double spin;
  final bool hints;
  final List<String> remaining;
  final bool enabled;
  final void Function(int cell) onTap;
  final void Function(int cell) onPanStart;
  final void Function(int cell) onPanMove;
  final VoidCallback onPanEnd;

  const _Board({
    required this.puzzle,
    required this.path,
    required this.flashPath,
    required this.rotation,
    required this.spin,
    required this.hints,
    required this.remaining,
    required this.enabled,
    required this.onTap,
    required this.onPanStart,
    required this.onPanMove,
    required this.onPanEnd,
  });

  /// Board index shown at display (row, col) under the current rotation.
  int _boardIndexAt(int row, int col) => switch (rotation) {
    1 => (huntSize - 1 - col) * huntSize + row,
    2 => (huntSize - 1 - row) * huntSize + (huntSize - 1 - col),
    3 => col * huntSize + (huntSize - 1 - row),
    _ => row * huntSize + col,
  };

  /// Display (row, col) of a board index — the inverse of [_boardIndexAt].
  (int, int) _displayOf(int index) {
    final row = index ~/ huntSize;
    final col = index % huntSize;
    return switch (rotation) {
      1 => (col, huntSize - 1 - row),
      2 => (huntSize - 1 - row, huntSize - 1 - col),
      3 => (huntSize - 1 - col, row),
      _ => (row, col),
    };
  }

  /// The tile under a pointer, if the pointer is near enough its centre:
  /// a diagonal swipe through a corner shouldn't grab the corner tile.
  int? _hit(Offset local, double cell) {
    final col = (local.dx / cell).floor();
    final row = (local.dy / cell).floor();
    if (row < 0 || row >= huntSize || col < 0 || col >= huntSize) return null;
    final centre = Offset((col + 0.5) * cell, (row + 0.5) * cell);
    if ((local - centre).distance > cell * 0.42) return null;
    return _boardIndexAt(row, col);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Hint data: how many remaining required words start on each tile, and
    // which tiles any remaining word still needs. Both use the certified
    // start/use masks, which union every route of every word.
    final startCounts = List<int>.filled(huntCells, 0);
    var stillUsed = 0;
    if (hints) {
      for (final word in remaining) {
        final info = puzzle.wordInfo(word)!;
        stillUsed |= info.uses;
        for (var c = 0; c < huntCells; c++) {
          if (info.starts >> c & 1 == 1) startCounts[c]++;
        }
      }
    }
    final onPath = {for (final c in path) c};
    final onFlash = {for (final c in flashPath ?? const <int>[]) c};

    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = constraints.maxWidth / huntSize;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // The pan starts where the finger went *down*, not where it had
          // travelled far enough to count as a drag — otherwise a quick
          // swipe skips its first tile.
          dragStartBehavior: DragStartBehavior.down,
          onTapUp: enabled
              ? (d) {
                  final c = _hit(d.localPosition, cell);
                  if (c != null) onTap(c);
                }
              : null,
          onPanStart: enabled
              ? (d) {
                  final c = _hit(d.localPosition, cell);
                  if (c != null) onPanStart(c);
                }
              : null,
          onPanUpdate: enabled
              ? (d) {
                  final c = _hit(d.localPosition, cell);
                  if (c != null) onPanMove(c);
                }
              : null,
          onPanEnd: enabled ? (_) => onPanEnd() : null,
          onPanCancel: enabled ? onPanEnd : null,
          child: Transform.rotate(
            angle: spin * 2 * pi,
            child: Stack(
              children: [
                GridView.count(
                  crossAxisCount: huntSize,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  children: [
                    for (var row = 0; row < huntSize; row++)
                      for (var col = 0; col < huntSize; col++)
                        _Tile(
                          letter: puzzle.board[_boardIndexAt(row, col)],
                          selected: onPath.contains(_boardIndexAt(row, col)),
                          flashed: onFlash.contains(_boardIndexAt(row, col)),
                          dimmed:
                              hints &&
                              remaining.isNotEmpty &&
                              (stillUsed >> _boardIndexAt(row, col) & 1) == 0,
                          badge: hints ? startCounts[_boardIndexAt(row, col)] : null,
                          size: cell,
                          counterSpin: -spin,
                        ),
                  ],
                ),
                IgnorePointer(
                  child: CustomPaint(
                    size: Size.square(constraints.maxWidth),
                    painter: _TracePainter(
                      points: [for (final c in path) _centre(_displayOf(c), cell)],
                      color: scheme.primary.withValues(alpha: 0.55),
                      width: cell * 0.16,
                    ),
                  ),
                ),
                if (flashPath != null)
                  IgnorePointer(
                    child: CustomPaint(
                      size: Size.square(constraints.maxWidth),
                      painter: _TracePainter(
                        points: [for (final c in flashPath!) _centre(_displayOf(c), cell)],
                        color: scheme.tertiary.withValues(alpha: 0.6),
                        width: cell * 0.14,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Offset _centre((int, int) display, double cell) =>
      Offset((display.$2 + 0.5) * cell, (display.$1 + 0.5) * cell);
}

class _Tile extends StatelessWidget {
  final String letter;
  final bool selected;
  final bool flashed;
  final bool dimmed;
  final int? badge;
  final double size;

  /// Turns to rotate the tile's contents by, cancelling the grid's spin.
  final double counterSpin;

  const _Tile({
    required this.letter,
    required this.selected,
    required this.flashed,
    required this.dimmed,
    required this.badge,
    required this.size,
    this.counterSpin = 0,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = selected
        ? scheme.primaryContainer
        : flashed
        ? scheme.tertiaryContainer
        : scheme.surface;
    return Padding(
      padding: EdgeInsets.all(size * 0.06),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(size * 0.18),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Transform.rotate(
          angle: counterSpin * 2 * pi,
          child: Stack(
            children: [
              Center(
                child: Text(
                  letter,
                  style: TextStyle(
                    fontSize: size * 0.42,
                    fontWeight: FontWeight.w700,
                    color: dimmed ? scheme.onSurface.withValues(alpha: 0.25) : scheme.onSurface,
                  ),
                ),
              ),
              if (badge != null && badge! > 0)
                Positioned(
                  top: size * 0.06,
                  right: size * 0.08,
                  child: Text(
                    '$badge',
                    style: TextStyle(
                      fontSize: size * 0.16,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TracePainter extends CustomPainter {
  final List<Offset> points;
  final Color color;
  final double width;

  const _TracePainter({required this.points, required this.color, required this.width});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TracePainter old) =>
      old.color != color || old.width != width || !_same(old.points, points);

  static bool _same(List<Offset> a, List<Offset> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Hint: how many required words are left at each length.
class _RemainingByLength extends StatelessWidget {
  final List<String> remaining;

  const _RemainingByLength({required this.remaining});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (remaining.isEmpty) return const SizedBox.shrink();
    final byLength = <int, int>{};
    for (final w in remaining) {
      byLength[w.length] = (byLength[w.length] ?? 0) + 1;
    }
    final lengths = byLength.keys.toList()..sort();
    return Text(
      'Left: ${[for (final l in lengths) '$l letters ×${byLength[l]}'].join('  ·  ')}',
      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      textAlign: TextAlign.center,
    );
  }
}

/// Everything found so far: required words by length, then bonus words.
class _FoundList extends StatelessWidget {
  final HuntPuzzle puzzle;
  final Set<String> found;
  final Set<String> revealed;

  const _FoundList({required this.puzzle, required this.found, required this.revealed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final required = [
      for (final w in found)
        if (puzzle.classify(w) != HuntWordClass.bonus) w,
    ]..sort((a, b) => a.length != b.length ? b.length - a.length : a.compareTo(b));
    final bonus = [
      for (final w in found)
        if (puzzle.classify(w) == HuntWordClass.bonus) w,
    ]..sort();

    if (required.isEmpty && bonus.isEmpty) {
      return Center(
        child: Text(
          'Drag through adjacent letters to make words of 4 or more.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
      );
    }

    Widget chip(String word, {required bool bonus}) {
      final isAnchor = puzzle.anchorWords.containsKey(word);
      final isTheme = puzzle.themeWords.contains(word);
      final wasRevealed = revealed.contains(word);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: bonus
              ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
              : isAnchor
              ? scheme.primaryContainer.withValues(alpha: 0.7)
              : isTheme
              ? scheme.secondaryContainer.withValues(alpha: 0.6)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isAnchor) ...[
              Icon(Icons.school_outlined, size: 13, color: scheme.primary),
              const SizedBox(width: 4),
            ] else if (isTheme) ...[
              Icon(Icons.category_outlined, size: 13, color: scheme.secondary),
              const SizedBox(width: 4),
            ],
            Text(
              word.toLowerCase(),
              style: TextStyle(
                fontSize: bonus ? 12 : 14,
                fontWeight: bonus ? FontWeight.w400 : FontWeight.w600,
                color: bonus
                    ? scheme.onSurfaceVariant
                    : wasRevealed
                    ? scheme.onSurfaceVariant
                    : scheme.onSurface,
                decoration: wasRevealed ? TextDecoration.underline : null,
                decorationStyle: TextDecorationStyle.dotted,
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final w in required) chip(w, bonus: false)],
        ),
        if (bonus.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Bonus', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 6, children: [for (final w in bonus) chip(w, bonus: true)]),
        ],
      ],
    );
  }
}

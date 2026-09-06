import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/repositories/crossword_repository.dart';
import '../../domain/crossword/crossword_models.dart';

String _cellKey(int row, int col) => '$row,$col';

class CrosswordScreen extends ConsumerStatefulWidget {
  final CrosswordDifficulty difficulty;
  // A specific past day from history ('YYYY-MM-DD'), or null for today.
  final String? date;

  const CrosswordScreen({super.key, required this.difficulty, this.date});

  @override
  ConsumerState<CrosswordScreen> createState() => _CrosswordScreenState();
}

class _CrosswordScreenState extends ConsumerState<CrosswordScreen> {
  String get _date => widget.date ?? CrosswordRepository.today();
  bool get _isToday => _date == CrosswordRepository.today();
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
  String? _selectedCell;
  CrosswordDirection _direction = CrosswordDirection.across;
  bool _completed = false;

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _prepare(CrosswordPuzzle puzzle, CrosswordSession session) {
    if (identical(_preparedSession, session)) return;
    _preparedSession = session;

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
    _completed = session.completed;
    if (puzzle.words.isNotEmpty) {
      final first = puzzle.words.first;
      _selectedCell = _cellKey(first.row, first.col);
      _direction = first.direction;
    }
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
    ref.read(crosswordRepositoryProvider).saveProgress(widget.difficulty, _date, Map.of(_filled));
  }

  void _checkCompletion() {
    if (_completed) return;
    if (_answers.isEmpty) return;
    final solved = _answers.entries.every((e) => _filled[e.key] == e.value);
    if (!solved) return;
    setState(() => _completed = true);
    ref.read(crosswordRepositoryProvider).markCompleted(widget.difficulty, _date);
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
    ref.invalidate(crosswordSessionProvider((difficulty: widget.difficulty, date: _date)));
    // _prepare() re-runs on its own once the freshly generated session
    // actually arrives (see _preparedSession) — this just clears leftover
    // local state so nothing from the old puzzle briefly shows through.
    setState(() {
      _filled.clear();
      _wrongCells.clear();
      _completed = false;
      _selectedCell = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessionAsync = ref.watch(crosswordSessionProvider((difficulty: widget.difficulty, date: _date)));

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
        title: Text(_isToday ? '${widget.difficulty.label} Crossword' : '${widget.difficulty.label} · $_date'),
        actions: [
          if (sessionAsync.valueOrNull != null) _StudyPoolBadge(puzzle: sessionAsync.valueOrNull!.puzzle),
          if (sessionAsync.valueOrNull != null)
            IconButton(icon: const Icon(Icons.fact_check_outlined), tooltip: 'Check', onPressed: _check),
          if (_isToday)
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
                      _isToday ? 'Not enough words yet' : 'No puzzle for this day',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isToday
                          ? 'Add more words to your study pool to unlock this puzzle size.'
                          : 'This difficulty wasn\'t played on $_date.',
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
          ),
      ],
    );
  }
}

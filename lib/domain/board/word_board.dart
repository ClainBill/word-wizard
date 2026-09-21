import 'dart:math';

/// How well the person knows a word on the board — what decides a tile's
/// colour. Looked up by headword at paint time, so a word added to the
/// Lexery from the board is tinted the moment they come back to it.
enum Familiarity { unknown, studying, mastered }

/// One placed word: where it starts and which way it runs.
class PlacedWord {
  final String word;
  final int row;
  final int col;
  final bool across;

  /// Placement order, from 0 for the seed: what the entry animation is
  /// staggered by.
  final int order;

  const PlacedWord({
    required this.word,
    required this.row,
    required this.col,
    required this.across,
    required this.order,
  });

  int get length => word.length;

  int rowAt(int i) => across ? row : row + i;
  int colAt(int i) => across ? col + i : col;
}

/// A crossword-style board that grows outward from a seed word: every
/// later word crosses one already on the board, and the usual crossword
/// rules hold — no two letters side by side unless they belong to the same
/// word, nothing touching a word's ends.
///
/// Pure model, no rendering: the search screen's landing board paints it
/// and grows it one word per tick.
class WordBoard {
  /// Cells per side. Words that would run off the edge aren't placed.
  final int size;

  final Map<int, String> _letters = {};
  final Map<int, List<PlacedWord>> _owners = {};
  final List<PlacedWord> _words = [];

  WordBoard({this.size = 41});

  List<PlacedWord> get words => List.unmodifiable(_words);
  bool get isEmpty => _words.isEmpty;

  int _key(int row, int col) => row * size + col;

  bool _inside(int row, int col) => row >= 0 && col >= 0 && row < size && col < size;

  String? letterAt(int row, int col) => _inside(row, col) ? _letters[_key(row, col)] : null;

  /// The words through a cell: none, one, or the across and the down.
  List<PlacedWord> wordsAt(int row, int col) =>
      _inside(row, col) ? (_owners[_key(row, col)] ?? const []) : const [];

  /// The seed goes across through the middle. Only on an empty board.
  bool placeSeed(String word) {
    if (_words.isNotEmpty || word.length > size) return false;
    final row = size ~/ 2;
    final col = (size - word.length) ~/ 2;
    _commit(PlacedWord(word: word, row: row, col: col, across: true, order: 0));
    return true;
  }

  /// Whether [word] could start at ([row], [col]) running [across] and
  /// cross [anchor] legally. Public for the tests; [tryPlace] finds such a
  /// spot on its own.
  bool canPlace(String word, {required int row, required int col, required bool across}) {
    if (word.isEmpty) return false;
    final endRow = across ? row : row + word.length - 1;
    final endCol = across ? col + word.length - 1 : col;
    if (!_inside(row, col) || !_inside(endRow, endCol)) return false;
    // Nothing touching either end.
    if (letterAt(across ? row : row - 1, across ? col - 1 : col) != null) return false;
    if (letterAt(across ? endRow : endRow + 1, across ? endCol + 1 : endCol) != null) return false;

    var crossings = 0;
    for (var i = 0; i < word.length; i++) {
      final r = across ? row : row + i;
      final c = across ? col + i : col;
      final existing = letterAt(r, c);
      if (existing != null) {
        if (existing != word[i]) return false;
        // Overlapping a word running the same way is not a crossing.
        if (wordsAt(r, c).any((w) => w.across == across)) return false;
        crossings++;
      } else {
        // An empty cell must not sit beside a letter of another word, or
        // the two would read as one.
        if (across) {
          if (letterAt(r - 1, c) != null || letterAt(r + 1, c) != null) return false;
        } else {
          if (letterAt(r, c - 1) != null || letterAt(r, c + 1) != null) return false;
        }
      }
    }
    return crossings >= 1;
  }

  /// Finds a legal spot for [word] crossing one of the words already on
  /// the board — trying [anchors] in the order given, and the possible
  /// crossings of each in random order — and places it. Null if nowhere
  /// fits.
  PlacedWord? tryPlace(String word, {required Random random, Iterable<PlacedWord>? anchors}) {
    for (final anchor in anchors ?? _words) {
      final options = <(int, int)>[];
      for (var i = 0; i < anchor.length; i++) {
        for (var j = 0; j < word.length; j++) {
          if (anchor.word[i] == word[j]) options.add((i, j));
        }
      }
      options.shuffle(random);
      for (final (i, j) in options) {
        final across = !anchor.across;
        final row = across ? anchor.rowAt(i) : anchor.rowAt(i) - j;
        final col = across ? anchor.colAt(i) - j : anchor.colAt(i);
        if (canPlace(word, row: row, col: col, across: across)) {
          final placed = PlacedWord(
            word: word,
            row: row,
            col: col,
            across: across,
            order: _words.length,
          );
          _commit(placed);
          return placed;
        }
      }
    }
    return null;
  }

  void _commit(PlacedWord w) {
    _words.add(w);
    for (var i = 0; i < w.length; i++) {
      final k = _key(w.rowAt(i), w.colAt(i));
      _letters[k] = w.word[i];
      (_owners[k] ??= []).add(w);
    }
  }

  /// How many other words cross [w].
  int crossings(PlacedWord w) {
    var n = 0;
    for (var i = 0; i < w.length; i++) {
      if (wordsAt(w.rowAt(i), w.colAt(i)).length > 1) n++;
    }
    return n;
  }

  /// The smallest rectangle holding every tile: (top, left, bottom, right),
  /// inclusive. Null when empty.
  ({int top, int left, int bottom, int right})? get bounds {
    if (_words.isEmpty) return null;
    var top = size, left = size, bottom = -1, right = -1;
    for (final w in _words) {
      top = min(top, w.row);
      left = min(left, w.col);
      bottom = max(bottom, w.rowAt(w.length - 1));
      right = max(right, w.colAt(w.length - 1));
    }
    return (top: top, left: left, bottom: bottom, right: right);
  }
}

/// Grows a [WordBoard] from a pool of candidate words, one word per
/// [next] call, branching outward: anchors with few crossings are tried
/// first so the board spreads rather than knotting up around the seed.
class WordBoardGrower {
  final WordBoard board;
  final Random random;
  final List<String> _pool;

  /// Words that fit nowhere the last time they were tried. Retried once
  /// the board has changed shape — cheap, and they often fit later.
  final List<String> _parked = [];

  /// Whether anything was placed since the parked words were last put
  /// back in play: a full pass over them with no placement means the
  /// board is done.
  bool _placedSinceRefill = true;
  bool _done = false;

  WordBoardGrower(this.board, {required List<String> pool, Random? random})
    : random = random ?? Random(),
      _pool = List.of(pool);

  /// True once nothing left in the pool fits anywhere.
  bool get exhausted => _done || (_pool.isEmpty && _parked.isEmpty);

  /// Places one more word, or returns null when nothing in the pool fits
  /// anywhere any more.
  PlacedWord? next() {
    if (board.isEmpty || _done) return null;
    if (_pool.isEmpty) {
      if (!_placedSinceRefill || _parked.isEmpty) {
        _done = true;
        return null;
      }
      _pool.addAll(_parked);
      _parked.clear();
      _placedSinceRefill = false;
    }
    final anchors = board.words.toList()
      ..shuffle(random)
      ..sort((a, b) => board.crossings(a).compareTo(board.crossings(b)));
    // A bounded number of tries per tick so a pool full of misfits can't
    // stall the animation.
    var tries = 0;
    while (_pool.isNotEmpty && tries < 24) {
      final word = _pool.removeAt(0);
      tries++;
      final placed = board.tryPlace(word, random: random, anchors: anchors);
      if (placed != null) {
        _placedSinceRefill = true;
        return placed;
      }
      _parked.add(word);
    }
    return null;
  }
}

/// Scrabble's letter values, for the little number on each tile.
const Map<String, int> letterValues = {
  'a': 1,
  'e': 1,
  'i': 1,
  'o': 1,
  'u': 1,
  'l': 1,
  'n': 1,
  's': 1,
  't': 1,
  'r': 1,
  'd': 2,
  'g': 2,
  'b': 3,
  'c': 3,
  'm': 3,
  'p': 3,
  'f': 4,
  'h': 4,
  'v': 4,
  'w': 4,
  'y': 4,
  'k': 5,
  'j': 8,
  'x': 8,
  'q': 10,
  'z': 10,
};

/// Whether a headword can be laid on the board: plain lowercase letters,
/// long enough to cross something and short enough to fit.
bool isBoardable(String headword) =>
    headword.length >= 3 && headword.length <= 12 && RegExp(r'^[a-z]+$').hasMatch(headword);

/// The exhaustive board scanner — research `engine.solve_checked`.
///
/// Walks every simple path on the board that is a prefix in the trie,
/// merging identical `(node, used-cells, start, cell)` states so a board of
/// repeated letters doesn't explode, and **raises rather than truncates**
/// when the state budget runs out: a partial answer set would tell the
/// player "not a word" for a word that is there, and there is no recovering
/// from that mid-game. A candidate board that exhausts the budget is simply
/// rejected and another tried (research contract §6).
library;

import 'dart:typed_data';

import 'hunt_models.dart';
import 'hunt_trie.dart';

/// Thrown when a scan exceeds its state budget. Never carries partial
/// results.
class HuntIncompleteSearch implements Exception {
  final int states;
  const HuntIncompleteSearch(this.states);

  @override
  String toString() => 'HuntIncompleteSearch: state budget exceeded after $states states';
}

/// The eight-neighbourhood of each cell, row-major on a 4x4 board.
final List<Int32List> huntNeighbours = List.unmodifiable([
  for (var i = 0; i < huntCells; i++)
    Int32List.fromList([
      for (var j = 0; j < huntCells; j++)
        if (j != i &&
            ((i ~/ huntSize - j ~/ huntSize).abs() <= 1) &&
            ((i % huntSize - j % huntSize).abs() <= 1))
          j,
    ]),
]);

/// Letter codes (0-25) for a board of single uppercase letters.
Uint8List huntBoardCodes(List<String> board) {
  if (board.length != huntCells) {
    throw ArgumentError('Expected $huntCells cells, got ${board.length}');
  }
  final codes = Uint8List(huntCells);
  for (var i = 0; i < huntCells; i++) {
    final cell = board[i];
    if (cell.length != 1) throw ArgumentError('Cell $i is not one letter: "$cell"');
    final c = cell.codeUnitAt(0) - 0x41;
    if (c < 0 || c > 25) throw ArgumentError('Cell $i is not A-Z: "$cell"');
    codes[i] = c;
  }
  return codes;
}

/// Everything in [trie] with a legal path on [board], keyed by word, with
/// one representative path and the union of all routes' start/use masks.
///
/// [maxStates] bounds distinct DFS states visited; exceeding it throws
/// [HuntIncompleteSearch]. The research measured a complete scan of a
/// typical board at under a millisecond against a 169,000-word trie, with
/// the million-state default only ever reached by pathological
/// repeated-letter boards.
Map<String, HuntWord> huntSolveChecked(
  List<String> board,
  HuntTrie trie, {
  int maxStates = 1000000,
}) {
  final codes = huntBoardCodes(board);
  final found = <String, HuntWord>{};
  final seen = <int>{};
  var states = 0;

  // Explicit stacks rather than recursion for the path so a found word can
  // be copied out without allocating on every step.
  final path = Int32List(huntCells);

  void visit(int cell, int node, int used, int depth, int start) {
    final next = trie.child(node, codes[cell]);
    if (next == -1) return;
    used |= 1 << cell;
    path[depth] = cell;
    // node < 2^30, used < 2^16, start/cell < 2^4: fits a 54-bit key.
    final key = (next << 24) | (used << 8) | (start << 4) | cell;
    if (!seen.add(key)) return;
    states++;
    if (states > maxStates) throw HuntIncompleteSearch(states);

    if (trie.isTerminal(next)) {
      final length = depth + 1;
      final chars = Uint8List(length);
      for (var i = 0; i < length; i++) {
        chars[i] = codes[path[i]] + 0x41;
      }
      final word = String.fromCharCodes(chars);
      final existing = found[word];
      if (existing == null) {
        found[word] = HuntWord(
          path: List<int>.unmodifiable(path.sublist(0, length)),
          starts: 1 << start,
          uses: used,
        );
      } else {
        found[word] = HuntWord(
          path: existing.path,
          starts: existing.starts | (1 << start),
          uses: existing.uses | used,
        );
      }
    }

    final neighbours = huntNeighbours[cell];
    for (var i = 0; i < neighbours.length; i++) {
      final n = neighbours[i];
      if (used >> n & 1 == 0) visit(n, next, used, depth + 1, start);
    }
  }

  for (var cell = 0; cell < huntCells; cell++) {
    visit(cell, HuntTrie.root, 0, 0, cell);
  }
  return found;
}

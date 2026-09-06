import 'dart:math';

import 'crossword_models.dart';

/// One blank run in the grid a word needs to fill — a slot, in crossword-
/// construction terms.
class CrosswordSlot {
  final int row;
  final int col;
  final int length;
  final CrosswordDirection direction;

  const CrosswordSlot({required this.row, required this.col, required this.length, required this.direction});
}

/// A North-American-style symmetric (180°-rotation) black-square pattern:
/// blocks are placed one mirrored pair at a time, skipping any placement
/// that would leave a run (row or column) of white cells shorter than
/// [minRun] — the standard rule that also guarantees every white cell ends
/// up "checked" (part of both an across and a down entry), since a cell
/// can never end up with a 1- or 2-cell run in either direction. Also
/// rejects any placement that would split the grid into disconnected
/// regions — real crossword grids are always one connected piece.
Set<(int, int)> generateBlackPattern(
  int width,
  int height,
  double blackRatio,
  Random rng, {
  int minRun = 3,
}) {
  final black = <(int, int)>{};
  final total = width * height;
  final targetBlack = (total * blackRatio).round();

  final cells = [for (var r = 0; r < height; r++) for (var c = 0; c < width; c++) (r, c)]..shuffle(rng);

  bool whiteRunsOk(Set<(int, int)> candidate) {
    for (var r = 0; r < height; r++) {
      var run = 0;
      for (var c = 0; c < width; c++) {
        if (candidate.contains((r, c))) {
          if (run > 0 && run < minRun) return false;
          run = 0;
        } else {
          run++;
        }
      }
      if (run > 0 && run < minRun) return false;
    }
    for (var c = 0; c < width; c++) {
      var run = 0;
      for (var r = 0; r < height; r++) {
        if (candidate.contains((r, c))) {
          if (run > 0 && run < minRun) return false;
          run = 0;
        } else {
          run++;
        }
      }
      if (run > 0 && run < minRun) return false;
    }
    return true;
  }

  bool isConnected(Set<(int, int)> candidate) {
    final white = [
      for (var r = 0; r < height; r++)
        for (var c = 0; c < width; c++)
          if (!candidate.contains((r, c))) (r, c),
    ];
    if (white.isEmpty) return true;
    final seen = <(int, int)>{white.first};
    final stack = [white.first];
    while (stack.isNotEmpty) {
      final (r, c) = stack.removeLast();
      for (final (dr, dc) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final next = (r + dr, c + dc);
        if (next.$1 >= 0 &&
            next.$1 < height &&
            next.$2 >= 0 &&
            next.$2 < width &&
            !candidate.contains(next) &&
            seen.add(next)) {
          stack.add(next);
        }
      }
    }
    return seen.length == white.length;
  }

  for (final (r, c) in cells) {
    if (black.length >= targetBlack) break;
    final mirror = (height - 1 - r, width - 1 - c);
    if (black.contains((r, c)) || black.contains(mirror)) continue;
    final candidate = {...black, (r, c), mirror};
    if (whiteRunsOk(candidate) && isConnected(candidate)) {
      black.addAll(candidate);
    }
  }

  return black;
}

/// Across and down slots of length >= 3 extracted from a black-square
/// pattern.
List<CrosswordSlot> extractSlots(int width, int height, Set<(int, int)> black) {
  final slots = <CrosswordSlot>[];
  for (var r = 0; r < height; r++) {
    var c = 0;
    while (c < width) {
      if (black.contains((r, c))) {
        c++;
        continue;
      }
      final start = c;
      while (c < width && !black.contains((r, c))) {
        c++;
      }
      final length = c - start;
      if (length >= 3) {
        slots.add(CrosswordSlot(row: r, col: start, length: length, direction: CrosswordDirection.across));
      }
    }
  }
  for (var c = 0; c < width; c++) {
    var r = 0;
    while (r < height) {
      if (black.contains((r, c))) {
        r++;
        continue;
      }
      final start = r;
      while (r < height && !black.contains((r, c))) {
        r++;
      }
      final length = r - start;
      if (length >= 3) {
        slots.add(CrosswordSlot(row: start, col: c, length: length, direction: CrosswordDirection.down));
      }
    }
  }
  return slots;
}

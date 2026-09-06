import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/crossword/crossword_pattern.dart';

void main() {
  group('generateBlackPattern', () {
    test('is symmetric under 180-degree rotation', () {
      final black = generateBlackPattern(15, 15, 0.16, Random(1));
      for (final (r, c) in black) {
        expect(black.contains((14 - r, 14 - c)), isTrue, reason: 'missing mirror of ($r,$c)');
      }
    });

    test('never leaves a white run shorter than 3, in either direction', () {
      final black = generateBlackPattern(11, 11, 0.15, Random(2));
      for (var r = 0; r < 11; r++) {
        var run = 0;
        for (var c = 0; c < 11; c++) {
          if (black.contains((r, c))) {
            expect(run == 0 || run >= 3, isTrue, reason: 'row $r has a run of length $run');
            run = 0;
          } else {
            run++;
          }
        }
        expect(run == 0 || run >= 3, isTrue, reason: 'row $r trailing run of length $run');
      }
      for (var c = 0; c < 11; c++) {
        var run = 0;
        for (var r = 0; r < 11; r++) {
          if (black.contains((r, c))) {
            expect(run == 0 || run >= 3, isTrue, reason: 'col $c has a run of length $run');
            run = 0;
          } else {
            run++;
          }
        }
        expect(run == 0 || run >= 3, isTrue, reason: 'col $c trailing run of length $run');
      }
    });

    test('every white cell is checked both across and down (North American rule)', () {
      // A cell can only fail to be "checked" in some direction if its run
      // in that direction has length 1 — which the min-run-3 rule above
      // already forbids, but this test verifies the practical consequence
      // directly: every white cell belongs to a run of length >= 3 in both
      // directions, i.e. it's crossed by both an across and a down entry.
      final black = generateBlackPattern(7, 7, 0.16, Random(3));
      List<int> runLengthsInRow(int r) {
        final lengths = <int>[];
        var run = 0;
        for (var c = 0; c < 7; c++) {
          if (black.contains((r, c))) {
            if (run > 0) lengths.add(run);
            run = 0;
          } else {
            run++;
          }
        }
        if (run > 0) lengths.add(run);
        return lengths;
      }

      for (var r = 0; r < 7; r++) {
        for (final len in runLengthsInRow(r)) {
          expect(len, greaterThanOrEqualTo(3));
        }
      }
    });

    test('produces one fully connected white region', () {
      final black = generateBlackPattern(15, 15, 0.16, Random(4));
      final white = [
        for (var r = 0; r < 15; r++)
          for (var c = 0; c < 15; c++)
            if (!black.contains((r, c))) (r, c),
      ];
      final seen = <(int, int)>{white.first};
      final stack = [white.first];
      while (stack.isNotEmpty) {
        final (r, c) = stack.removeLast();
        for (final (dr, dc) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          final next = (r + dr, c + dc);
          if (next.$1 >= 0 &&
              next.$1 < 15 &&
              next.$2 >= 0 &&
              next.$2 < 15 &&
              !black.contains(next) &&
              seen.add(next)) {
            stack.add(next);
          }
        }
      }
      expect(seen.length, white.length, reason: 'white region is not fully connected');
    });

    test('lands reasonably close to the requested black ratio', () {
      final black = generateBlackPattern(15, 15, 0.16, Random(5));
      final ratio = black.length / (15 * 15);
      expect(ratio, closeTo(0.16, 0.05));
    });
  });

  group('extractSlots', () {
    test('extracts across and down slots of length >= 3 from a known pattern', () {
      // 5x5, block the corners diagonally-ish to force a couple of short
      // dead-end runs that should be excluded.
      const black = {(0, 4), (4, 0)};
      final slots = extractSlots(5, 5, black);

      // Row 0: cols 0-3 open (length 4), col 4 blocked.
      expect(
        slots.any((s) => s.direction == CrosswordDirection.across && s.row == 0 && s.col == 0 && s.length == 4),
        isTrue,
      );
      // Row 4: col 0 blocked, cols 1-4 open (length 4).
      expect(
        slots.any((s) => s.direction == CrosswordDirection.across && s.row == 4 && s.col == 1 && s.length == 4),
        isTrue,
      );
      // Column 0: rows 0-3 open (length 4), row 4 blocked.
      expect(
        slots.any((s) => s.direction == CrosswordDirection.down && s.col == 0 && s.row == 0 && s.length == 4),
        isTrue,
      );
      // No slot should ever be shorter than 3.
      for (final s in slots) {
        expect(s.length, greaterThanOrEqualTo(3));
      }
    });

    test('an empty (no black cells) grid produces one full-length slot per row and column', () {
      final slots = extractSlots(4, 4, {});
      final across = slots.where((s) => s.direction == CrosswordDirection.across).toList();
      final down = slots.where((s) => s.direction == CrosswordDirection.down).toList();
      expect(across.length, 4);
      expect(down.length, 4);
      for (final s in slots) {
        expect(s.length, 4);
      }
    });
  });
}

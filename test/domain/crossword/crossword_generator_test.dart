import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/crossword/crossword_generator.dart';
import 'package:word_wizard/domain/crossword/crossword_models.dart';

/// A large synthetic word pool with realistic-ish letter frequency —
/// standing in for the ~460k-word real dictionary pool a real generation
/// pulls from (verified separately, in Python, against the actual
/// dictionary — see the crossword feature's implementation notes). A unit
/// test can't ship the real 400MB dictionary, but a big, letter-diverse
/// synthetic pool exercises the same solver code path realistically.
List<CrosswordCandidate> _syntheticCandidates({int count = 20000, int seed = 42}) {
  final rand = Random(seed);
  const letters = 'EEEEAAAARRRRIIIIOOOOTTTNNNSSSSLLLLCCCUUUDDDDPPPMMMHHHGGGBBBFFFYYYWWWKKKVVVXZJQ';
  String randomWord(int len) => List.generate(len, (_) => letters[rand.nextInt(letters.length)]).join();

  final seen = <String>{};
  final result = <CrosswordCandidate>[];
  var id = 0;
  while (result.length < count) {
    final len = 3 + rand.nextInt(10); // 3..12
    final w = randomWord(len);
    if (!seen.add(w)) continue;
    result.add(CrosswordCandidate(entryId: id++, headword: w, isDueToday: false, fromStudyPool: false));
  }
  return result;
}

// Fast-but-real parameters for tests — same algorithm, smaller retry budget
// so the suite doesn't take as long as a worst-case production run.
CrosswordPuzzle? _generate(List<CrosswordCandidate> candidates, CrosswordDifficulty difficulty) {
  return generateCrossword(
    CrosswordGenerationRequest(candidates: candidates, difficulty: difficulty),
    patternAttemptsPerTier: 6,
    perAttemptBudget: const Duration(milliseconds: 1500),
  );
}

void main() {
  group('generateCrossword', () {
    test('returns null when the candidate pool has almost no usable words', () {
      final tiny = [
        CrosswordCandidate(entryId: 1, headword: 'cat', isDueToday: false, fromStudyPool: false),
        CrosswordCandidate(entryId: 2, headword: 'dog', isDueToday: false, fromStudyPool: false),
      ];
      final puzzle = _generate(tiny, CrosswordDifficulty.mega);
      expect(puzzle, isNull);
    });

    test('fully solves a grid with a rich enough candidate pool (mini)', () {
      final puzzle = _generate(_syntheticCandidates(), CrosswordDifficulty.mini);
      expect(puzzle, isNotNull);
      expect(puzzle!.width, CrosswordDifficulty.mini.maxWidth);
      expect(puzzle.height, CrosswordDifficulty.mini.maxHeight);
      expect(puzzle.words, isNotEmpty);
    });

    test('fully solves a grid with a rich enough candidate pool (midi)', () {
      final puzzle = _generate(_syntheticCandidates(), CrosswordDifficulty.midi);
      expect(puzzle, isNotNull);
      expect(puzzle!.width, CrosswordDifficulty.midi.maxWidth);
      expect(puzzle.height, CrosswordDifficulty.midi.maxHeight);
    });

    test('every word respects the difficulty\'s length range', () {
      final puzzle = _generate(_syntheticCandidates(), CrosswordDifficulty.midi);
      expect(puzzle, isNotNull);
      for (final w in puzzle!.words) {
        expect(w.answer.length, greaterThanOrEqualTo(CrosswordDifficulty.midi.minWordLength));
        expect(w.answer.length, lessThanOrEqualTo(CrosswordDifficulty.midi.maxWordLength));
      }
    });

    test('never places the same answer twice', () {
      final puzzle = _generate(_syntheticCandidates(), CrosswordDifficulty.midi);
      expect(puzzle, isNotNull);
      final answers = puzzle!.words.map((w) => w.answer).toList();
      expect(answers.toSet().length, answers.length);
    });

    test('places every accepted word without any letter conflicts, and the grid is one connected piece', () {
      final puzzle = _generate(_syntheticCandidates(), CrosswordDifficulty.mini);
      expect(puzzle, isNotNull);

      final grid = <(int, int), String>{};
      for (final w in puzzle!.words) {
        final cells = w.cells;
        for (var i = 0; i < cells.length; i++) {
          final existing = grid[cells[i]];
          if (existing != null) {
            expect(existing, w.answer[i], reason: 'conflicting letters at ${cells[i]}');
          }
          grid[cells[i]] = w.answer[i];
        }
      }

      for (final w in puzzle.words) {
        final crossesAnother =
            w.cells.any((cell) => puzzle.words.where((other) => other != w).any((other) => other.cells.contains(cell)));
        expect(crossesAnother, isTrue, reason: '${w.answer} is disconnected from the rest of the grid');
      }
    });

    test('every placed word gets a positive clue number, following the standard start-of-word rule', () {
      final puzzle = _generate(_syntheticCandidates(), CrosswordDifficulty.mini);
      expect(puzzle, isNotNull);

      final grid = <(int, int), String>{};
      for (final w in puzzle!.words) {
        final cells = w.cells;
        for (var i = 0; i < cells.length; i++) {
          grid[cells[i]] = w.answer[i];
        }
      }
      for (final w in puzzle.words) {
        expect(w.number, greaterThan(0));
        final (r, c) = (w.row, w.col);
        final startsAcross =
            w.direction == CrosswordDirection.across && !grid.containsKey((r, c - 1)) && grid.containsKey((r, c + 1));
        final startsDown =
            w.direction == CrosswordDirection.down && !grid.containsKey((r - 1, c)) && grid.containsKey((r + 1, c));
        expect(startsAcross || startsDown, isTrue, reason: '${w.answer} should start a word at its own cell');
      }
    });

    test('fills the grid close to the requested density, not just a sparse scaffold', () {
      final puzzle = _generate(_syntheticCandidates(), CrosswordDifficulty.mini);
      expect(puzzle, isNotNull);
      final filledCells = {for (final w in puzzle!.words) ...w.cells}.length;
      final totalCells = puzzle.width * puzzle.height;
      expect(filledCells / totalCells, greaterThan(0.65));
    });

    test('a study-pool word mixed into the filler pool is included when it fits', () {
      final candidates = [
        CrosswordCandidate(entryId: 999, headword: 'CAT', isDueToday: true, fromStudyPool: true),
        ..._syntheticCandidates(),
      ];
      final puzzle = _generate(candidates, CrosswordDifficulty.mini);
      expect(puzzle, isNotNull);
      expect(puzzle!.words.any((w) => w.answer == 'CAT' && w.entryId == 999), isTrue);
    });
  });
}

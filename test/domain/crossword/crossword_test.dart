import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/crossword/clues.dart';
import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/crossword/generator.dart';
import 'package:word_wizard/domain/crossword/skeleton.dart';
import 'package:word_wizard/domain/crossword/solver.dart';
import 'package:word_wizard/domain/crossword/themes.dart';
import 'package:word_wizard/domain/crossword/word_list.dart';

/// PORTING_SPEC.md §11 lists seven invariants worth asserting; all seven are
/// covered here, plus unit tests for the pieces that have a right answer
/// independent of the search.

final List<CrosswordEntry> _entries = parseWordList(
  File('assets/crossword/wordlist.tsv').readAsStringSync(),
);

/// §11.1's reference 9x9 skeleton — "use these ... as fixed inputs to test
/// the solver independently of generation".
const _reference9x9 = [
  '...###...',
  '....##...',
  '....#....',
  '......###',
  '##.....##',
  '###......',
  '....#....',
  '...##....',
  '...###...',
];

List<List<bool>> _parseGrid(List<String> rows) =>
    [for (final row in rows) [for (final ch in row.split('')) ch == '#']];

void main() {
  group('skeleton (§4)', () {
    for (final difficulty in CrosswordDifficulty.values) {
      test('${difficulty.label} grids satisfy every structural rule', () {
        final n = difficulty.size;
        final rng = Random(42);
        var produced = 0;

        for (var attempt = 0; attempt < 6; attempt++) {
          final black = generateSkeletonCapped(
            n,
            difficulty.maxEntryLen,
            difficulty.whiteTarget,
            rng,
          );
          expect(black, isNotNull, reason: 'skeleton generation should not give up');
          produced++;

          // Invariant 1: 180 degree rotational symmetry.
          for (var r = 0; r < n; r++) {
            for (var c = 0; c < n; c++) {
              expect(black![r][c], black[n - 1 - r][n - 1 - c],
                  reason: 'symmetry at ($r,$c)');
            }
          }

          // Invariant 3: one connected white component.
          expect(isConnected(black!, n), isTrue);

          // Invariant 2: every entry is 3..maxEntryLen long.
          final slots = extractSlots(black, n);
          expect(slots, isNotEmpty);
          for (final slot in slots) {
            expect(slot.length, greaterThanOrEqualTo(3));
            expect(slot.length, lessThanOrEqualTo(difficulty.maxEntryLen));
          }

          // Rule 3, full checking: every white cell is in both an across and
          // a down entry, which for these shapes means every cell of every
          // slot has a crossing.
          for (final slot in slots) {
            expect(slot.crossings.length, slot.length,
                reason: 'every cell of ${slot.slotId} should be checked');
          }
        }
        expect(produced, 6);
      });
    }

    test('achieved white percentage lands in the measured band (§4.3)', () {
      // The target is a floor on black squares, not an exact figure, so this
      // asserts the band §4.3 measured rather than the target itself.
      final bands = {
        CrosswordDifficulty.mini: (0.78, 0.88),
        CrosswordDifficulty.midi: (0.66, 0.82),
        CrosswordDifficulty.mega: (0.66, 0.78),
      };
      for (final entry in bands.entries) {
        final difficulty = entry.key;
        final n = difficulty.size;
        final rng = Random(7);
        final black = generateSkeletonCapped(
            n, difficulty.maxEntryLen, difficulty.whiteTarget, rng)!;
        var white = 0;
        for (var r = 0; r < n; r++) {
          for (var c = 0; c < n; c++) {
            if (!black[r][c]) white++;
          }
        }
        final ratio = white / (n * n);
        expect(ratio, greaterThanOrEqualTo(entry.value.$1), reason: '${difficulty.label} white %');
        expect(ratio, lessThanOrEqualTo(entry.value.$2), reason: '${difficulty.label} white %');
      }
    });

    test('numbering and crossings agree with the grid (§4.4)', () {
      final black = _parseGrid(_reference9x9);
      final slots = extractSlots(black, 9);

      // Both directions starting at one cell share a number.
      final numbersByCell = <(int, int), Set<int>>{};
      for (final slot in slots) {
        numbersByCell.putIfAbsent((slot.row, slot.col), () => {}).add(slot.number);
      }
      for (final numbers in numbersByCell.values) {
        expect(numbers.length, 1);
      }

      // Numbers ascend in raster order.
      final starts = [for (final s in slots) (s.row * 9 + s.col, s.number)];
      starts.sort((a, b) => a.$1.compareTo(b.$1));
      var previous = 0;
      for (final (_, number) in starts) {
        expect(number, greaterThanOrEqualTo(previous));
        previous = number;
      }

      // Every crossing is mutual and points at the same cell from both ends.
      final byId = {for (final s in slots) s.slotId: s};
      for (final slot in slots) {
        slot.crossings.forEach((i, crossing) {
          final other = byId[crossing.$1]!;
          expect(other.direction, isNot(slot.direction));
          expect(slot.cells()[i], other.cells()[crossing.$2]);
          expect(other.crossings[crossing.$2], (slot.slotId, i));
        });
      }
    });
  });

  group('pattern index (§5)', () {
    test('candidates match the pattern and honour the exclusion set', () {
      final index = CrosswordPatternIndex.build(_entries.where(inFillPool));

      final matches = index.candidates('C.T', const {});
      expect(matches, isNotEmpty);
      for (final entry in matches) {
        expect(entry.text.length, 3);
        expect(entry.text[0], 'C');
        expect(entry.text[2], 'T');
      }

      final excluded = matches.first.text;
      final without = index.candidates('C.T', {excluded});
      expect(without.map((e) => e.text), isNot(contains(excluded)));
      expect(without.length, matches.length - 1);

      // An unconstrained pattern returns the whole length bucket.
      expect(index.candidates('...', const {}).length,
          _entries.where((e) => e.length == 3 && inFillPool(e)).length);

      // A pattern nothing can match short-circuits to empty.
      expect(index.candidates('QQQQQ', const {}), isEmpty);
    });
  });

  group('solver (§6)', () {
    test('fills the reference 9x9 skeleton', () {
      final black = _parseGrid(_reference9x9);
      final slots = extractSlots(black, 9);
      final index = CrosswordPatternIndex.build(_entries.where(inFillPool));

      final solver = CrosswordSolver(
        slots: slots,
        index: index,
        rng: Random(1),
        preAssigned: const {},
        timeBudget: const Duration(seconds: 20),
      );
      final fill = solver.solve();

      expect(fill, isNotNull);
      expect(fill!.length, slots.length);

      // Invariant 4: crossings agree.
      final byId = {for (final s in slots) s.slotId: s};
      for (final slot in slots) {
        slot.crossings.forEach((i, crossing) {
          expect(fill[slot.slotId]![i], fill[crossing.$1]![crossing.$2]);
        });
      }
      // Invariant 5: no word appears twice.
      expect(fill.values.toSet().length, fill.length);
      expect(byId.length, slots.length);
    });

    test('recent answers never reappear in the fill (§A.2 requirement 10)', () {
      final black = _parseGrid(_reference9x9);
      final slots = extractSlots(black, 9);
      final index = CrosswordPatternIndex.build(_entries.where(inFillPool));

      // Bar a first fill's own answers, then solve the same grid again.
      final first = CrosswordSolver(
        slots: slots,
        index: index,
        rng: Random(2),
        preAssigned: const {},
        timeBudget: const Duration(seconds: 20),
      ).solve()!;

      final banned = first.values.toSet();
      final second = CrosswordSolver(
        slots: slots,
        index: index,
        rng: Random(3),
        preAssigned: const {},
        recentUsage: banned,
        timeBudget: const Duration(seconds: 20),
      ).solve();

      expect(second, isNotNull);
      for (final answer in second!.values) {
        expect(banned, isNot(contains(answer)));
      }
    });
  });

  group('anchors and themes (§7)', () {
    test('day of week maps to the right category', () {
      expect(themeCategoryFor(DateTime.monday), 'random');
      expect(themeCategoryFor(DateTime.tuesday), 'pop_culture');
      expect(themeCategoryFor(DateTime.wednesday), 'general_knowledge');
      expect(themeCategoryFor(DateTime.thursday), 'random');
      expect(themeCategoryFor(DateTime.friday), 'random');
      expect(themeCategoryFor(DateTime.saturday), 'pop_culture');
      expect(themeCategoryFor(DateTime.sunday), 'distinctive');
    });

    test('fitAnchors never lets two anchors disagree at a shared cell', () {
      final black = _parseGrid(_reference9x9);
      final slots = extractSlots(black, 9);

      // Two four-letter anchors that cannot both be placed on crossing slots
      // without conflicting: they share no letter in any position.
      final anchors = [
        CrosswordEntry.synthetic(text: 'AAAA', display: 'aaaa', entryId: 1),
        CrosswordEntry.synthetic(text: 'BBBB', display: 'bbbb', entryId: 2),
      ];
      final (preAssigned, used) = fitAnchors(anchors, slots);

      final letters = <(int, int), String>{};
      final byId = {for (final s in slots) s.slotId: s};
      preAssigned.forEach((slotId, word) {
        final cells = byId[slotId]!.cells();
        for (var i = 0; i < cells.length; i++) {
          final existing = letters[cells[i]];
          expect(existing == null || existing == word[i], isTrue,
              reason: 'anchors disagree at ${cells[i]}');
          letters[cells[i]] = word[i];
        }
      });
      expect(used.length, preAssigned.length);
    });

    test('degradation drops the lowest-priority anchor rather than failing', () {
      final black = _parseGrid(_reference9x9);
      final slots = extractSlots(black, 9);
      // The reference 9x9 has no slot longer than 6, so the 7-letter anchor
      // can never be placed; the 3-letter one still should be.
      final anchors = [
        CrosswordEntry.synthetic(text: 'ARK', display: 'ark', entryId: 1),
        CrosswordEntry.synthetic(text: 'PROBLEM', display: 'problem', entryId: 2),
      ];
      final (preAssigned, used) = fitAnchors(anchors, slots);
      expect(preAssigned.values, contains('ARK'));
      expect(preAssigned.values, isNot(contains('PROBLEM')));
      expect(used.map((e) => e.text), ['ARK']);
    });

    test('the Sunday mechanism hides a category word inside every anchor', () {
      final theme = buildSundayTheme(_entries, 3, Random(5));
      expect(theme, isNotNull);
      expect(theme!.kind, 'hidden_word');
      final words = hiddenCategories[theme.name]!;
      for (final anchor in theme.anchors) {
        expect(anchor.length, greaterThanOrEqualTo(6));
        expect(words.any((w) => anchor.text != w && anchor.text.contains(w)), isTrue,
            reason: '${anchor.text} should hide a ${theme.name} word');
      }
    });
  });

  group('clue vetting (§8)', () {
    test('rejects a clue that leaks its answer', () {
      expect(isGiveaway('A landslide of rock and mud', 'LANDSLIDE'), isTrue);
      // Inflections of the answer count.
      expect(isGiveaway('Having been surfeited', 'SURFEIT'), isTrue);
      // The answer inside a longer clue word.
      expect(isGiveaway('Relating to a propeller', 'PROPEL'), isTrue);
    });

    test('the two length guards keep innocent clues', () {
      // §8's own example: without the answer-length guard, "domesticated"
      // flags CAT.
      expect(isGiveaway('A domesticated feline', 'CAT'), isFalse);
      expect(isGiveaway('An overwhelming electoral victory', 'LANDSLIDE'), isFalse);
      // Tokens shorter than three characters are ignored.
      expect(isGiveaway('One of a pair', 'ONE'), isTrue);
    });

    test('difficulty rises as clue vocabulary gets rarer', () {
      final zipf = {for (final e in _entries) e.text.toLowerCase(): e.freqZipf};
      double? lookup(String word) => zipf[word];
      final easy = clueDifficulty('The first day of the week', lookup);
      final hard = clueDifficulty('Pertaining to a lacustrine sediment', lookup);
      expect(hard, greaterThan(easy));
      expect(easy, inInclusiveRange(1, 5));
      expect(hard, inInclusiveRange(1, 5));
    });
  });

  group('word list (§2)', () {
    test('parses the asset into the documented schema', () {
      expect(_entries.length, greaterThan(20000));
      for (final entry in _entries.take(500)) {
        expect(entry.text, matches(RegExp(r'^[A-Z]+$')));
        expect(entry.length, inInclusiveRange(3, 17));
        expect(entry.entryId, greaterThan(0));
        expect(entry.freqZipf, greaterThanOrEqualTo(0));
      }
    });

    test('the fill pool clears the short-length floors', () {
      for (final entry in _entries.where(inFillPool)) {
        expect(entry.freqZipf,
            greaterThanOrEqualTo(fillMinZipfByLength[entry.length] ?? fillMinZipf));
      }
    });
  });

  group('isolate boundary', () {
    // The app never calls generateCrossword directly: CrosswordRepository
    // hands a CrosswordIsolateRequest to Isolate.run, which refuses anything
    // unsendable. Worth an actual round trip rather than trusting that every
    // field happens to be a plain value.
    test('a request survives Isolate.run and comes back as a puzzle', () async {
      final source = File('assets/crossword/wordlist.tsv').readAsStringSync();
      final request = CrosswordIsolateRequest(
        wordListSource: source,
        difficulty: CrosswordDifficulty.mini,
        srsWords: const [('SPARE', 'spare', 12345)],
        recentUsage: const {'OTHER'},
        weekday: DateTime.wednesday,
        seed: 4242,
      );

      final puzzle = await Isolate.run(() => generateCrosswordFromSource(request));

      expect(puzzle, isNotNull);
      expect(puzzle!.words, isNotEmpty);
      expect(puzzle.words.map((w) => w.answer), contains('SPARE'));
      expect(puzzle.words.map((w) => w.answer), isNot(contains('OTHER')));
      // Every placed word resolves to a dictionary row so a clue can be
      // fetched for it, except a synthesized SRS anchor, which carries the
      // entry id the caller supplied.
      for (final word in puzzle.words) {
        expect(word.entryId, greaterThan(0));
      }
    });
  });

  group('end to end (§9, §11)', () {
    // Mega is exercised by `dart run tool/crossword_bench.dart`; a full 17x17
    // solve takes seconds and has no place in a unit test run.
    for (final difficulty in [CrosswordDifficulty.mini, CrosswordDifficulty.midi]) {
      test('${difficulty.label} puzzles satisfy invariants 1-7', () {
        for (var seed = 0; seed < 3; seed++) {
          final srs = CrosswordEntry.synthetic(
            text: 'SPARE',
            display: 'spare',
            entryId: 12345,
          );
          final puzzle = generateCrossword(CrosswordGenerationRequest(
            difficulty: difficulty,
            entries: _entries,
            srsAnchors: [srs],
            recentUsage: const {},
            weekday: (seed % 7) + 1,
            seed: 900 + seed,
          ));

          expect(puzzle, isNotNull, reason: 'seed $seed should produce a puzzle');
          expect(puzzle!.width, difficulty.size);

          // Invariant 4: across and down agree on every shared cell.
          final letters = <(int, int), String>{};
          for (final word in puzzle.words) {
            final cells = word.cells;
            for (var i = 0; i < cells.length; i++) {
              final existing = letters[cells[i]];
              expect(existing == null || existing == word.answer[i], isTrue,
                  reason: 'cells ${cells[i]} disagree');
              letters[cells[i]] = word.answer[i];
            }
          }

          // Invariants 1-3, rebuilt from the presentation grid.
          final n = difficulty.size;
          final black = [
            for (var r = 0; r < n; r++)
              [for (var c = 0; c < n; c++) !letters.containsKey((r, c))],
          ];
          for (var r = 0; r < n; r++) {
            for (var c = 0; c < n; c++) {
              expect(black[r][c], black[n - 1 - r][n - 1 - c]);
            }
          }
          expect(isConnected(black, n), isTrue);
          for (final word in puzzle.words) {
            expect(word.answer.length, inInclusiveRange(3, difficulty.maxEntryLen));
          }

          // Invariant 5: no repeated answers.
          expect(puzzle.words.map((w) => w.answer).toSet().length, puzzle.words.length);

          // Invariant 6: the SRS anchor survived into the final fill, and is
          // flagged so the study-pool badge can count it.
          expect(puzzle.words.map((w) => w.answer), contains('SPARE'));
          expect(puzzle.words.where((w) => w.fromStudyPool).map((w) => w.answer), ['SPARE']);

          // Invariant 7: every non-anchor entry clears its length's floor.
          final index = CrosswordPatternIndex.build(_entries.where(inFillPool));
          for (final word in puzzle.words) {
            if (word.answer == 'SPARE') continue;
            final floor = qualityFloorByLength[word.answer.length];
            if (floor == null) continue;
            final entry = index.byText[word.answer];
            expect(entry, isNotNull, reason: '${word.answer} should be in the fill pool');
            expect(entry!.score, greaterThanOrEqualTo(floor),
                reason: '${word.answer} scores ${entry.score}, floor $floor');
          }
        }
      });
    }
  });
}

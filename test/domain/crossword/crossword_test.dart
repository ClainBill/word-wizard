import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/crossword/clues.dart';
import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/crossword/editorial.dart';
import 'package:word_wizard/domain/crossword/generator.dart';
import 'package:word_wizard/domain/crossword/history.dart';
import 'package:word_wizard/domain/crossword/skeleton.dart';
import 'package:word_wizard/domain/crossword/solver.dart';
import 'package:word_wizard/domain/crossword/themes.dart';
import 'package:word_wizard/domain/crossword/word_list.dart';
import 'package:word_wizard/services/crossword_review_service.dart';

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
        blockedAnswers: const {},
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

    test('blocked answers never reappear in the fill (§6.2, §A.2 req. 10)', () {
      final black = _parseGrid(_reference9x9);
      final slots = extractSlots(black, 9);
      final index = CrosswordPatternIndex.build(_entries.where(inFillPool));

      // Bar a first fill's own answers, then solve the same grid again.
      final first = CrosswordSolver(
        slots: slots,
        index: index,
        rng: Random(2),
        preAssigned: const {},
        blockedAnswers: const {},
        timeBudget: const Duration(seconds: 20),
      ).solve()!;

      final banned = first.values.toSet();
      final second = CrosswordSolver(
        slots: slots,
        index: index,
        rng: Random(3),
        preAssigned: const {},
        blockedAnswers: banned,
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
        expect(entry.freqZipf, greaterThanOrEqualTo(0));
        expect(entry.familiarity, inInclusiveRange(1, 5));
        expect(entry.display, isNotEmpty);
      }
      // §2: 100% of the asset carries at least one clue, 64% carry two.
      expect(_entries.every((e) => e.clues.isNotEmpty), isTrue);
      final withTwo = _entries.where((e) => e.clues.length >= 2).length;
      expect(withTwo / _entries.length, greaterThan(0.5));
    });

    test('every one of the fill pool\'s four bars is enforced (§6.3)', () {
      for (final entry in _entries.where(inFillPool)) {
        expect(entry.freqZipf, greaterThanOrEqualTo(fillMinZipf));
        expect(entry.clues, isNotEmpty);
        expect(entry.editorTier, isNot(lastResortTier));
        expect(entry.familiarity, greaterThanOrEqualTo(familiarityFloor(entry.length)));
        expect(entry.isCrosswordese, isFalse);
      }
      // The bars are what keep the words readers rejected by name out of the
      // pool, and every one of them clears at least one of the others.
      for (final junk in ['ERG', 'PAP', 'ABA', 'DES', 'AIN', 'NEE']) {
        final entry = _entries.where((e) => e.text == junk).firstOrNull;
        if (entry == null) continue;
        expect(inFillPool(entry), isFalse, reason: '$junk should not be fill');
      }
    });
  });

  group('saved puzzle compatibility', () {
    // Real installs carry rows written by app versions that predate fields
    // the model now has. Generation reads the last ten stored puzzles back to
    // avoid repeating answers, so a row it cannot parse stops the user
    // getting a crossword at all — which is what shipped, until an
    // `entryId`-less row from an older build threw "type 'Null' is not a
    // subtype of type 'int'" on a phone that had been running the app for a
    // week.
    test('a row written before entryId existed still parses', () {
      final legacy = {
        'width': 7,
        'height': 7,
        'words': [
          {
            'number': 1,
            'direction': 'across',
            'row': 0,
            'col': 0,
            'answer': 'PEDDLER',
            'clue': 'A travelling seller.',
          },
        ],
      };

      final puzzle = CrosswordPuzzle.fromJson(legacy);

      expect(puzzle.width, 7);
      expect(puzzle.words.single.answer, 'PEDDLER');
      // -1 is the generator's own "no dictionary row behind this word" value,
      // and clue lookup skips it.
      expect(puzzle.words.single.entryId, -1);
      expect(puzzle.words.single.fromStudyPool, isFalse);
      // Likewise for the fields the Crosswordler engine added: a puzzle with
      // no slot ids simply cannot be reviewed, which the repository checks.
      expect(puzzle.words.single.slotId, -1);
      expect(puzzle.words.single.display, 'PEDDLER');
    });

    test('a round trip through toJson preserves every field', () {
      const original = CrosswordPuzzle(
        width: 5,
        height: 5,
        words: [
          CrosswordWordPlacement(
            number: 1,
            slotId: 3,
            direction: CrosswordDirection.down,
            row: 0,
            col: 0,
            answer: 'MUSE',
            display: 'muse',
            entryId: 10206,
            clue: 'A source of inspiration',
            clueType: CrosswordClueType.synonym,
            freqZipf: 4.1,
            fromStudyPool: true,
          ),
        ],
        themeName: 'animals',
        themeKind: 'hidden_word',
        qualityScore: 13.5,
        anchors: ['MUSE'],
        seed: 77,
      );

      final restored = CrosswordPuzzle.fromJson(original.toJson());

      expect(restored.themeName, 'animals');
      expect(restored.themeKind, 'hidden_word');
      expect(restored.qualityScore, 13.5);
      expect(restored.anchors, ['MUSE']);
      expect(restored.seed, 77);
      final word = restored.words.single;
      expect(word.entryId, 10206);
      expect(word.slotId, 3);
      expect(word.display, 'muse');
      expect(word.clueType, CrosswordClueType.synonym);
      expect(word.freqZipf, 4.1);
      expect(word.fromStudyPool, isTrue);
      expect(word.direction, CrosswordDirection.down);
      expect(word.clue, 'A source of inspiration');
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
        srsWords: const [
          (text: 'SPARE', display: 'spare', entryId: 12345, clue: 'Not in use'),
        ],
        blockedAnswers: const {'OTHER'},
        weekday: DateTime.wednesday,
        seed: 4242,
      );

      final puzzle = await Isolate.run(() => generateCrosswordFromSource(request));

      expect(puzzle, isNotNull);
      expect(puzzle!.words, isNotEmpty);
      expect(puzzle.words.map((w) => w.answer), contains('SPARE'));
      expect(puzzle.words.map((w) => w.answer), isNot(contains('OTHER')));
      // Clues are baked into the asset, so every word arrives clued (§6.3
      // makes an unclued word unselectable), and the study anchor carries the
      // dictionary row it came from so a solve can be credited back to it.
      for (final word in puzzle.words) {
        expect(word.clue, isNotEmpty);
      }
      final anchor = puzzle.words.firstWhere((w) => w.answer == 'SPARE');
      expect(anchor.entryId, 12345);
      expect(anchor.fromStudyPool, isTrue);
    });

    // The repository scales the budgets up in debug builds, where the JIT
    // makes the same search several times slower. A scale of zero is the
    // cheapest proof the scale is applied at all: no time, no puzzle.
    test('the time budgets scale with the request', () {
      CrosswordPuzzle? generate(double scale) => generateCrossword(CrosswordGenerationRequest(
            difficulty: CrosswordDifficulty.mini,
            entries: _entries,
            srsAnchors: const [],
            blockedAnswers: const {},
            weekday: DateTime.friday,
            seed: 5150,
            budgetScale: scale,
          ));
      expect(generate(0), isNull);
      expect(generate(1), isNotNull);
      expect(generate(5), isNotNull);
    });

    // A verdict's word edits re-solve the grid, which needs the index, so the
    // revision crosses the same boundary as generation — with a puzzle and a
    // verdict in the request this time.
    test('a revision survives Isolate.run', () async {
      final source = File('assets/crossword/wordlist.tsv').readAsStringSync();
      final puzzle = generateCrossword(CrosswordGenerationRequest(
        difficulty: CrosswordDifficulty.mini,
        entries: _entries,
        srsAnchors: const [],
        blockedAnswers: const {},
        weekday: DateTime.friday,
        seed: 5150,
      ))!;
      final target = puzzle.words.first;

      final request = CrosswordRevisionRequest(
        wordListSource: source,
        puzzle: puzzle,
        verdict: EditorialVerdict(
          clueEdits: {target.slotId: 'A replacement clue that breaks no rules'},
        ),
        blockedAnswers: const {},
        seed: puzzle.seed,
      );
      final revision = await Isolate.run(() => reviseCrosswordFromSource(request));

      expect(revision.cluesApplied, 1);
      expect(
        revision.puzzle.words.firstWhere((w) => w.slotId == target.slotId).clue,
        'A replacement clue that breaks no rules',
      );
      expect(revision.puzzle.reviewed, isTrue);
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
            clue: 'Not in use',
          );
          final puzzle = generateCrossword(CrosswordGenerationRequest(
            difficulty: difficulty,
            entries: _entries,
            srsAnchors: [srs],
            blockedAnswers: const {},
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

  group('bitset domains (§5.2)', () {
    final index = CrosswordPatternIndex.build(_entries.where(inFillPool));

    test('maskFor agrees with the candidate set it replaces', () {
      for (final pattern in ['C.T', 'S..RE', '....', 'B.T.', 'ZZ.ZZ']) {
        final fromMask = index.entriesIn(pattern.length, index.maskFor(pattern));
        final expected = [
          for (final entry in _entries)
            if (inFillPool(entry) &&
                entry.length == pattern.length &&
                _matches(entry.text, pattern))
              entry.text,
        ];
        expect(fromMask.map((e) => e.text).toSet(), expected.toSet(),
            reason: 'pattern $pattern');
      }
    });

    test('set bits come out in score order, best first', () {
      final entries = index.entriesIn(5, index.maskFor('.....'));
      expect(entries, isNotEmpty);
      for (var i = 1; i < entries.length; i++) {
        expect(entries[i - 1].score, greaterThanOrEqualTo(entries[i].score));
      }
    });

    test('a domain reports its own size', () {
      final mask = index.maskFor('C.T');
      expect(maskPopCount(mask), index.entriesIn(3, mask).length);
      expect(maskIsEmpty(index.maskFor('QQQ')), isTrue);
    });

    test("the solver reaches §11's node counts, not thousands", () {
      // A port with a bug in propagation or undo still solves — slowly, and
      // by brute force. Node count is what tells the two apart, because it is
      // a property of the search rather than of the machine: §11 measures
      // 11 / 32 / 115 nodes for the three sizes, and says a port taking
      // thousands has a bug however fast it runs.
      final black = _parseGrid(_reference9x9);
      final slots = extractSlots(black, 9);
      final solver = CrosswordSolver(
        slots: slots,
        index: index,
        rng: Random(7),
        preAssigned: const {},
        blockedAnswers: const {},
        timeBudget: const Duration(seconds: 20),
      );
      expect(solver.solve(), isNotNull);
      expect(solver.steps, lessThan(400),
          reason: 'the reference 9x9 solves in ~32 nodes; ${solver.steps} '
              'means propagation or undo is wrong');
    });
  });

  group('clue selection (§8)', () {
    test('weighting favours crossword register over an encyclopedic gloss', () {
      const terse = CrosswordClue('A pair', CrosswordClueType.curated);
      const gloss = CrosswordClue(
        'The cardinal number that is the sum of one and one and one more',
        CrosswordClueType.definition,
      );
      expect(clueOptionWeight(terse), greaterThan(clueOptionWeight(gloss)));
      // Every option keeps a real chance, so variety survives.
      expect(clueOptionWeight(gloss), greaterThan(0));
    });

    test('a seed reproduces the same clue', () {
      final entry = _entries.firstWhere((e) => e.clues.length >= 2);
      final first = pickClue(entry, Random(11)).text;
      expect(pickClue(entry, Random(11)).text, first);
    });

    test('a clue that leaks its answer is replaced, never shown', () {
      const leaky = CrosswordEntry(
        text: 'LASER',
        display: 'laser',
        freqZipf: 4.0,
        synsetCount: 1,
        isProper: false,
        isPhrase: false,
        isCrosswordese: false,
        tags: [],
        score: 8,
        editorTier: 51,
        familiarity: 5,
        clues: [
          CrosswordClue(
            'Light amplification by stimulated emission of radiation',
            CrosswordClueType.definition,
          ),
        ],
      );
      expect(pickClue(leaky, Random(1)).text, isNot(contains('amplification')));
    });

    test('the gate catches what a model actually got wrong', () {
      // Each of these is a rule the reviewer was given explicitly and broke
      // anyway in a measured run.
      expect(validateClue('A landslide victory', 'LANDSLIDE').ok, isFalse);
      expect(validateClue('Ophthalmologist, for short', 'DOC').ok, isFalse);
      expect(validateClue("Three-letter boy's name", 'ERIC').ok, isFalse);
      expect(validateClue('Bank', 'RELY').ok, isFalse); // one word is not a clue
      expect(
        validateClue('Frozen dessert containing cream and sugar', 'ICECREAM',
                display: 'ice cream')
            .ok,
        isFalse,
      );
      expect(validateClue('Exit or way out', 'EGRESS').ok, isTrue);
    });
  });

  group('solve history (§6.2a)', () {
    test('an abandoned puzzle suppresses nothing, a revealed answer returns', () {
      final events = [
        CrosswordSolveEvent.fromAnswers(
          puzzleId: 'a',
          solved: const ['SPARE', "I do's"],
          revealed: const ['SPARE'],
        ),
        CrosswordSolveEvent.fromAnswers(puzzleId: 'b', solved: const ['TERSE']),
      ];
      final blocked = blockedAnswersFrom(events);

      // Solved but revealed: they still need to learn it, so it comes back.
      expect(blocked, isNot(contains('SPARE')));
      // Normalized to grid form, so "I do's" and IDOS are one answer.
      expect(blocked, contains('IDOS'));
      expect(blocked, contains('TERSE'));
    });

    test('only the last ten events count', () {
      // Answers are letters only — normalization strips anything else — so
      // number the events with letters too.
      final names = [for (var i = 0; i < 12; i++) 'WORD${String.fromCharCode(65 + i)}'];
      final events = [
        for (var i = 0; i < names.length; i++)
          CrosswordSolveEvent.fromAnswers(puzzleId: '$i', solved: [names[i]]),
      ];
      final blocked = blockedAnswersFrom(events);
      expect(blocked, isNot(contains(names[0])));
      expect(blocked, isNot(contains(names[1])));
      expect(blocked, contains(names.last));
      expect(blocked.length, solveHistoryWindow);
    });
  });

  group('the editorial pass (§9.3, §9.4)', () {
    final index = CrosswordPatternIndex.build(_entries.where(inFillPool));

    CrosswordPuzzle buildPuzzle() => generateCrossword(CrosswordGenerationRequest(
          difficulty: CrosswordDifficulty.midi,
          entries: _entries,
          srsAnchors: [
            CrosswordEntry.synthetic(
              text: 'SPARE',
              display: 'spare',
              entryId: 1,
              clue: 'Not in use',
            ),
          ],
          blockedAnswers: const {},
          weekday: DateTime.thursday,
          seed: 31337,
        ))!;

    test('a verdict survives the shapes models actually return', () {
      final verdict = parseVerdict('Sure, here you go:\n'
          '```json\n'
          '{"entertainment": 7.5, "notes": "Solid.",\n'
          ' "clue_edits": {"12A": "Exit or way out", "3": "  ", "x": "ignored"},\n'
          ' "word_edits": {}}\n'
          '```');
      expect(verdict.entertainment, 7.5);
      // Models key edits as "12", 12 or "12A" however they are asked.
      expect(verdict.clueEdits, {12: 'Exit or way out'});
      expect(verdict.bannedAnswers, isEmpty);
      // Anything unreadable is an empty verdict, which is a no-op.
      expect(parseVerdict('sorry, I cannot help with that').isEmpty, isTrue);
      expect(parseVerdict('').isEmpty, isTrue);
    });

    test('the reviewer is shown the answers, keyed by slot id', () {
      final puzzle = buildPuzzle();
      final rendered = renderForReview(puzzle, weekday: DateTime.thursday);
      expect(rendered, contains('Day: Thursday'));
      expect(rendered, contains('Required answers (do not replace): SPARE'));
      expect(rendered, contains('id=${puzzle.words.first.slotId}'));
      expect(rendered, contains('#')); // the grid, black squares and all
    });

    test('an edit that breaks a rule is rejected, a good one applied', () {
      final puzzle = buildPuzzle();
      final target = puzzle.words.firstWhere((w) => w.answer != 'SPARE');
      final other = puzzle.words.lastWhere((w) => w.answer != target.answer);

      final revision = revisePuzzle(
        puzzle: puzzle,
        verdict: EditorialVerdict(clueEdits: {
          target.slotId: 'A perfectly ordinary replacement clue',
          other.slotId: 'Clue containing ${other.answer} itself',
        }),
        index: index,
        blockedAnswers: const {},
        seed: 1,
      );

      expect(revision.cluesApplied, 1);
      expect(revision.cluesRejected[ClueRejection.containsAnswer], 1);
      expect(
        revision.puzzle.words.firstWhere((w) => w.slotId == target.slotId).clue,
        'A perfectly ordinary replacement clue',
      );
      expect(assertPuzzleValid(revision.puzzle), isEmpty);
    });

    test('a banned answer is refilled by the solver, not by the reviewer', () {
      final puzzle = buildPuzzle();
      final target = puzzle.words.firstWhere((w) => w.answer != 'SPARE');

      final revision = revisePuzzle(
        puzzle: puzzle,
        verdict: EditorialVerdict(bannedAnswers: {target.slotId: 'nobody knows this'}),
        index: index,
        blockedAnswers: const {},
        seed: 1,
      );

      expect(revision.wordsApplied, 1, reason: revision.wordsRejectedReason);
      final answers = revision.puzzle.words.map((w) => w.answer);
      expect(answers, isNot(contains(target.answer)));
      // The replacement is the solver's, and it has to be a real word from
      // the fill pool that satisfies every crossing.
      final replacement =
          revision.puzzle.words.firstWhere((w) => w.slotId == target.slotId).answer;
      expect(index.byText[replacement], isNotNull);
      expect(assertPuzzleValid(revision.puzzle), isEmpty);
      // Recorded as "this became that", which is what the debug log shows.
      final edit = revision.edits.single;
      expect(edit.isWordEdit, isTrue);
      expect(edit.before, target.answer);
      expect(edit.after, replacement);
    });

    test('the puzzle only churns where it had to', () {
      // Banning one answer re-fills the grid, but the point of doing it with
      // the same seed and low jitter is that everything not forced to move
      // stays put — which is what lets clue rewrites for untouched answers
      // survive alongside a ban.
      final puzzle = buildPuzzle();
      final target = puzzle.words.firstWhere((w) => w.answer != 'SPARE');

      final revision = revisePuzzle(
        puzzle: puzzle,
        verdict: EditorialVerdict(bannedAnswers: {target.slotId: 'unfair'}),
        index: index,
        blockedAnswers: const {},
        seed: 1,
      );
      expect(revision.wordsApplied, 1);

      final before = {for (final w in puzzle.words) w.slotId: w.answer};
      final unchanged = revision.puzzle.words
          .where((w) => before[w.slotId] == w.answer)
          .length;
      expect(unchanged, greaterThan(puzzle.words.length ~/ 2),
          reason: 'a ban should not rewrite the whole puzzle');
    });

    test('an anchor can never be banned', () {
      final puzzle = buildPuzzle();
      final anchor = puzzle.words.firstWhere((w) => w.answer == 'SPARE');

      final revision = revisePuzzle(
        puzzle: puzzle,
        verdict: EditorialVerdict(bannedAnswers: {anchor.slotId: 'I dislike it'}),
        index: index,
        blockedAnswers: const {},
        seed: 1,
      );

      // The study word is the reason the puzzle is personalised; nothing the
      // reviewer says removes it.
      expect(revision.puzzle.words.map((w) => w.answer), contains('SPARE'));
      expect(revision.wordsApplied, 0);
      expect(revision.wordsRejectedReason, 'nothing_bannable');
    });

    test('a clue rewrite survives a ban unless its own answer moved', () {
      final puzzle = buildPuzzle();
      final banned = puzzle.words.firstWhere((w) => w.answer != 'SPARE');
      // A slot far from the banned one, so it is unlikely to be re-filled.
      final other = puzzle.words.lastWhere(
        (w) => w.answer != 'SPARE' && w.slotId != banned.slotId,
      );

      final revision = revisePuzzle(
        puzzle: puzzle,
        verdict: EditorialVerdict(
          bannedAnswers: {banned.slotId: 'unfair'},
          clueEdits: {other.slotId: 'A perfectly ordinary replacement clue'},
        ),
        index: index,
        blockedAnswers: const {},
        seed: 1,
      );

      final after = revision.puzzle.words.firstWhere((w) => w.slotId == other.slotId);
      final clueEdit = revision.edits.firstWhere((e) => !e.isWordEdit);
      if (after.answer == other.answer) {
        // Its answer survived, so the rewrite is still about the right word.
        expect(clueEdit.applied, isTrue);
        expect(after.clue, 'A perfectly ordinary replacement clue');
      } else {
        // Its answer moved, so the rewrite is stale and is dropped — the bug
        // this guards is a clue for one answer landing on another.
        expect(clueEdit.applied, isFalse);
        expect(clueEdit.rejection, 'stale_after_refill');
      }
      expect(assertPuzzleValid(revision.puzzle), isEmpty);
    });

    test('assertPuzzleValid catches a broken revision', () {
      final puzzle = buildPuzzle();
      final broken = puzzle.copyWith(words: [
        for (final word in puzzle.words)
          word == puzzle.words.first
              ? word.copyWith(clue: 'A clue containing ${word.answer}')
              : word,
      ]);
      expect(assertPuzzleValid(broken), isNotEmpty);
    });
  });
  group('the AI editor debug log', () {
    final index = CrosswordPatternIndex.build(_entries.where(inFillPool));

    CrosswordPuzzle buildPuzzle() => generateCrossword(CrosswordGenerationRequest(
          difficulty: CrosswordDifficulty.midi,
          entries: _entries,
          srsAnchors: const [],
          blockedAnswers: const {},
          weekday: DateTime.thursday,
          seed: 4242,
        ))!;

    test('cost is billed on prompt + completion, never on reasoning twice', () {
      // Reasoning tokens are already inside completion_tokens, which is how
      // the API bills them; adding them again would roughly double the
      // reported cost of a reasoning model.
      final cost = estimateCostUsd(
        model: 'gpt-5-mini',
        promptTokens: 1000000,
        completionTokens: 1000000,
      );
      expect(cost, closeTo(0.25 + 2.00, 1e-9));

      // An unpriced model reports nothing rather than free — the UI shows a
      // dash, which is honest about not knowing.
      expect(
        estimateCostUsd(model: 'some-future-model', promptTokens: 1000, completionTokens: 1000),
        0,
      );
      expect(estimateCostUsd(model: 'gpt-5-mini', promptTokens: 0, completionTokens: 0), 0);
    });

    test('every proposed edit is recorded, applied or not', () {
      final puzzle = buildPuzzle();
      final good = puzzle.words.first;
      final bad = puzzle.words.last;

      final revision = revisePuzzle(
        puzzle: puzzle,
        verdict: EditorialVerdict(clueEdits: {
          good.slotId: 'An entirely reasonable replacement clue',
          bad.slotId: 'Clue mentioning ${bad.answer} outright',
          9999: 'An edit for a slot that does not exist',
        }),
        index: index,
        blockedAnswers: const {},
        seed: 1,
      );

      expect(revision.cluesProposed, 3);
      expect(revision.cluesApplied, 1);

      final applied = revision.edits.firstWhere((e) => e.applied);
      expect(applied.answer, good.answer);
      // `before` is what the clue used to say, so the log can show the swap.
      expect(applied.before, good.clue);
      expect(applied.after, 'An entirely reasonable replacement clue');
      expect(applied.rejection, isEmpty);

      final leaked = revision.edits.firstWhere((e) => e.answer == bad.answer);
      expect(leaked.applied, isFalse);
      expect(leaked.rejection, ClueRejection.containsAnswer.name);

      // An edit keyed to a slot the puzzle doesn't have is kept too: a
      // reviewer inventing ids is exactly the sort of thing worth seeing.
      expect(
        revision.edits.where((e) => e.rejection == 'unknown_slot').length,
        1,
      );
    });

    test('a ban that cannot be filled records the reason and changes nothing', () {
      final puzzle = buildPuzzle();
      // Banning every answer leaves the grid with nothing to fill itself
      // from, which is the failure this has to survive.
      final revision = revisePuzzle(
        puzzle: puzzle,
        verdict: EditorialVerdict(bannedAnswers: {
          for (final word in puzzle.words) word.slotId: 'unfair',
        }),
        index: index,
        blockedAnswers: const {},
        seed: 1,
      );

      expect(revision.wordsApplied, 0);
      expect(revision.wordsRejectedReason, isNotEmpty);
      expect(revision.puzzle.words, puzzle.words);
      // Every attempted ban is recorded with why it failed, and with no
      // replacement — the reviewer never proposes one.
      expect(revision.edits, isNotEmpty);
      for (final edit in revision.edits) {
        expect(edit.applied, isFalse);
        expect(edit.after, isEmpty);
        expect(edit.rejection, revision.wordsRejectedReason);
      }
      // Round-trips through the JSON the log stores.
      final restored = CrosswordProposedEdit.fromJson(revision.edits.first.toJson());
      expect(restored.isWordEdit, isTrue);
      expect(restored.rejection, revision.edits.first.rejection);
    });
  });
}

/// Whether [text] matches a '.'-wildcard pattern.
bool _matches(String text, String pattern) {
  for (var i = 0; i < pattern.length; i++) {
    if (pattern[i] != '.' && pattern[i] != text[i]) return false;
  }
  return true;
}

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/hunt/hunt_generator.dart';
import 'package:word_wizard/domain/hunt/hunt_lexicon.dart';
import 'package:word_wizard/domain/hunt/hunt_models.dart';
import 'package:word_wizard/domain/hunt/hunt_solver.dart';
import 'package:word_wizard/domain/hunt/hunt_themes.dart';
import 'package:word_wizard/domain/hunt/hunt_trie.dart';

/// The research bundle's `test_engine.py` and `test_multi.py`, ported
/// alongside the engine, plus integration checks against the shipped
/// lexicon assets.

/// Independent, non-memoised per-word enumerator — the oracle the research
/// checks the memoised solver against.
(int starts, int uses) _oracle(List<String> board, String word) {
  var starts = 0;
  var uses = 0;
  void visit(List<int> path) {
    if (path.length == word.length) {
      starts |= 1 << path.first;
      for (final c in path) {
        uses |= 1 << c;
      }
      return;
    }
    final options = path.isEmpty ? [for (var i = 0; i < 16; i++) i] : huntNeighbours[path.last];
    for (final c in options) {
      if (!path.contains(c) && board[c] == word[path.length]) visit([...path, c]);
    }
  }

  visit([]);
  return (starts, uses);
}

void _checkPath(List<String> board, String word, HuntWord info) {
  expect(info.path.length, word.length, reason: word);
  expect(info.path.toSet().length, word.length, reason: '$word reuses a tile');
  expect([for (final c in info.path) board[c]].join(), word);
  for (var i = 1; i < info.path.length; i++) {
    expect(huntNeighbours[info.path[i - 1]].contains(info.path[i]), isTrue,
        reason: '$word step $i is not adjacent');
  }
  expect(info.starts & (1 << info.path.first), isNonZero);
  var pathMask = 0;
  for (final c in info.path) {
    pathMask |= 1 << c;
  }
  expect(info.uses & pathMask, pathMask);
}

final HuntLexicon _lexicon = HuntLexicon.fromSources(
  acceptedText: File('assets/hunt/accepted.txt').readAsStringSync(),
  mainText: File('assets/hunt/main.txt').readAsStringSync(),
);

void main() {
  group('trie', () {
    test('contains exactly what was inserted', () {
      final trie = HuntTrie.build(['ABLE', 'ABLER', 'ZOO', 'ZOO', 'not-a-word']);
      expect(trie.wordCount, 3);
      expect(trie.contains('ABLE'), isTrue);
      expect(trie.contains('ABLER'), isTrue);
      expect(trie.contains('ABL'), isFalse);
      expect(trie.contains('ZOO'), isTrue);
      expect(trie.contains('ZOOS'), isFalse);
      expect(trie.contains(''), isFalse);
    });
  });

  group('solver (research test_engine.py)', () {
    test('matches the per-word oracle on synthetic boards', () {
      final rng = Random(87);
      const alphabet = 'ABCDE';
      for (var round = 0; round < 25; round++) {
        final board = [for (var i = 0; i < 16; i++) alphabet[rng.nextInt(5)]];
        final words = <String>{};
        for (var i = 0; i < 30; i++) {
          final len = 4 + rng.nextInt(3);
          words.add([for (var j = 0; j < len; j++) alphabet[rng.nextInt(5)]].join());
        }
        // Deliberately reachable words.
        for (var i = 0; i < 10; i++) {
          final path = [rng.nextInt(16)];
          while (path.length < 5) {
            final options = [for (final c in huntNeighbours[path.last]) if (!path.contains(c)) c];
            if (options.isEmpty) break;
            path.add(options[rng.nextInt(options.length)]);
          }
          words.add([for (final c in path) board[c]].join());
        }
        final found = huntSolveChecked(board, HuntTrie.build(words));
        for (final w in words) {
          final (starts, uses) = _oracle(board, w);
          expect(found.containsKey(w), starts != 0, reason: '$w on ${board.join()}');
          if (starts != 0) {
            expect((found[w]!.starts, found[w]!.uses), (starts, uses), reason: w);
            _checkPath(board, w, found[w]!);
          }
        }
      }
    });

    test('never reuses a tile', () {
      final board = [...'ABCD'.split(''), ...List.filled(12, 'X')];
      final found = huntSolveChecked(board, HuntTrie.build(['ABABA', 'ABCD']));
      expect(found.containsKey('ABABA'), isFalse);
      expect(found.containsKey('ABCD'), isTrue);
    });

    test('a budget overrun throws rather than truncating', () {
      expect(
        () => huntSolveChecked(List.filled(16, 'A'), HuntTrie.build(['AAAAAA']), maxStates: 10),
        throwsA(isA<HuntIncompleteSearch>()),
      );
    });

    test('repeated letters union every route', () {
      final found = huntSolveChecked(List.filled(16, 'A'), HuntTrie.build(['AAAA']));
      expect(found['AAAA']!.starts, 65535);
      expect(found['AAAA']!.uses, 65535);
    });

    test('diagonals are adjacent', () {
      final board = List.filled(16, 'X');
      board[0] = 'W';
      board[5] = 'O';
      board[10] = 'R';
      board[15] = 'D';
      expect(huntSolveChecked(board, HuntTrie.build(['WORD'])).containsKey('WORD'), isTrue);
    });
  });

  group('placement (research test_multi.py)', () {
    test('shares tiles rather than requiring disjoint paths', () {
      const words = ['ABCD', 'DCBA', 'ABCE'];
      final placement = huntPlaceAnchors(words, Random(4));
      expect(placement.board, isNotNull);
      final found = huntSolveChecked(placement.board!, HuntTrie.build(words));
      expect(found.keys.toSet(), words.toSet());
    });

    test('capacity bound rejects impossible inventories without searching', () {
      final placement = huntPlaceAnchors(['AAAAAAAAA', 'BBBBBBBB'], Random(0));
      expect(placement.board, isNull);
      expect(placement.nodes, 0);
    });

    test('is bounded and replays deterministically', () {
      const words = ['QUIZZICAL', 'XYLOPHONE', 'BUZZARD'];
      final a = huntPlaceAnchors(words, Random(7), budget: 20);
      final b = huntPlaceAnchors(words, Random(7), budget: 20);
      expect(a.board, b.board);
      expect(a.nodes, b.nodes);
      expect(a.nodes, lessThanOrEqualTo(21));
    });

    test('backtracks into an earlier word when a later one cannot fit', () {
      // Sixteen distinct letters: the two words must tile the board exactly,
      // which only some placements of the first allow.
      const words = ['ABCDEFGH', 'IJKLMNOP'];
      var successes = 0;
      for (var seed = 0; seed < 10; seed++) {
        final placement = huntPlaceAnchors(words, Random(seed), budget: 50000);
        if (placement.board != null) {
          successes++;
          final found = huntSolveChecked(placement.board!, HuntTrie.build(words));
          expect(found.keys.toSet(), words.toSet());
        }
      }
      expect(successes, greaterThan(0));
    });
  });

  group('generation', () {
    HuntAnchor anchor(String text, {HuntAnchorKind kind = HuntAnchorKind.study}) =>
        HuntAnchor(text: text, display: text.toLowerCase(), kind: kind);

    test('refuses an anchor the lexicon has never heard of', () {
      final lexicon = HuntLexicon.fromSources(acceptedText: 'ABCD\n', mainText: 'ABCD\n');
      expect(
        () => generateHunt(lexicon, HuntGenerationRequest(seed: 0, anchors: [anchor('FAKE')])),
        throwsArgumentError,
      );
    });

    test('failure is explicit and reports every pass', () {
      final lexicon = HuntLexicon.fromSources(acceptedText: 'ABCD\n', mainText: '');
      final result = generateHunt(
        lexicon,
        HuntGenerationRequest(seed: 0, anchors: [anchor('ABCD')], attempts: 1),
      );
      expect(result.success, isFalse);
      expect(result.failure, isNotNull);
      expect([for (final d in result.diagnostics) d.anchorCount], [1, 0]);
    });

    test('lexicon: main is a subset of accepted and the fingerprint is stable', () {
      expect(_lexicon.accepted.wordCount, greaterThan(160000));
      expect(_lexicon.main.wordCount, greaterThan(25000));
      expect(_lexicon.main.wordCount, lessThan(_lexicon.accepted.wordCount));
      expect(_lexicon.fingerprint, startsWith('enable-bonus-v1:'));
      expect(_lexicon.accepted.contains('CANCER'), isTrue);
      expect(_lexicon.main.contains('MELODY'), isTrue);
    });

    test('places study and theme anchors, certifies the scan, keeps classes disjoint', () {
      final themes = HuntThemeSet.parse(File('assets/hunt/themes.tsv').readAsStringSync());
      expect(themes.themes.length, greaterThan(20));
      const studyWords = ['RESONANCE', 'MELODY', 'CADENCE', 'HARMONY', 'TEXTURE', 'TIMBRE'];
      final stopwatch = Stopwatch()..start();
      var generations = 0;
      var keptAll = 0;
      for (var seed = 0; seed < 12; seed++) {
        final theme = themes.forDate('2026-09-${(seed + 1).toString().padLeft(2, '0')}')!;
        final themeWord = HuntThemeSet.pickAnchor(theme, Random(seed))!;
        final anchors = [
          anchor(studyWords[seed % studyWords.length]),
          anchor(themeWord, kind: HuntAnchorKind.theme),
          anchor(studyWords[(seed + 1) % studyWords.length]),
        ];
        final result = generateHunt(
          _lexicon,
          HuntGenerationRequest(
            seed: seed,
            anchors: anchors,
            themeLabel: theme.label,
            themeWords: theme.words,
          ),
        );
        generations++;
        expect(result.success, isTrue, reason: 'seed $seed: ${result.failure}');
        final puzzle = result.puzzle!;
        if (puzzle.anchors.length == 3) keptAll++;
        expect(puzzle.anchors.length + puzzle.omitted.length, 3);
        expect(puzzle.anchors.isNotEmpty, isTrue);

        // Every anchor kept is on the board, on a legal path.
        for (final a in puzzle.anchors) {
          expect(puzzle.anchorWords.containsKey(a.text), isTrue, reason: a.text);
          _checkPath(puzzle.board, a.text, puzzle.anchorWords[a.text]!);
        }
        // Classes are disjoint.
        final anchorTexts = puzzle.anchorWords.keys.toSet();
        expect(puzzle.main.keys.toSet().intersection(anchorTexts), isEmpty);
        expect(puzzle.bonus.keys.toSet().intersection(anchorTexts), isEmpty);
        expect(puzzle.main.keys.toSet().intersection(puzzle.bonus.keys.toSet()), isEmpty);
        // The quality gate held on the ranked (main) set.
        expect(puzzle.main.length, inInclusiveRange(20, 60), reason: 'seed $seed');
        // Every answer replays against an independent scan.
        final rescan = huntSolveChecked(puzzle.board, _lexicon.accepted);
        expect(rescan.length, puzzle.main.length + puzzle.bonus.length + puzzle.anchors.length);
        for (final entry in [...puzzle.main.entries, ...puzzle.bonus.entries]) {
          _checkPath(puzzle.board, entry.key, entry.value);
          expect(_lexicon.main.contains(entry.key), puzzle.main.containsKey(entry.key));
          expect((rescan[entry.key]!.starts, rescan[entry.key]!.uses),
              (entry.value.starts, entry.value.uses));
        }
        // Theme bookkeeping.
        if (puzzle.themeAnchor != null) {
          expect(puzzle.themeLabel, theme.label);
          expect(puzzle.themeWords, contains(puzzle.themeAnchor!.text));
          for (final w in puzzle.themeWords) {
            expect(puzzle.wordInfo(w), isNotNull);
          }
        } else {
          expect(puzzle.themeLabel, isNull);
        }
        // Round-trips through JSON unchanged.
        final copy = HuntPuzzle.fromJson(puzzle.toJson());
        expect(copy.board, puzzle.board);
        expect(copy.main.keys.toSet(), puzzle.main.keys.toSet());
        expect(copy.anchorWords.keys.toSet(), anchorTexts);
        expect(copy.themeWords, puzzle.themeWords);
      }
      stopwatch.stop();
      // Research adaptive-two: 40/40 ordinary boards kept both. Three is the
      // opt-in condition at ~78%; require a healthy majority here.
      expect(keptAll, greaterThanOrEqualTo(generations ~/ 2));
      // ignore: avoid_print
      print('hunt: $generations generations, $keptAll kept all three anchors, '
          '${stopwatch.elapsedMilliseconds ~/ generations} ms each');
    });

    test('the same seed and anchors replay the same board', () {
      final request = HuntGenerationRequest(seed: 42, anchors: [anchor('SERENE'), anchor('VIVID')]);
      final a = generateHunt(_lexicon, request);
      final b = generateHunt(_lexicon, request);
      expect(a.puzzle!.board, b.puzzle!.board);
      expect(a.puzzle!.main.keys.toList(), b.puzzle!.main.keys.toList());
    });
  });

  group('themes', () {
    test('a date maps to one theme, stably, and walks the list', () {
      final themes = HuntThemeSet.parse('# c\nMusic\tCHOIR,OCTAVE\nLaw\tPAROLE,LEASE\nAt sea\tKEEL,MAST\n');
      expect(themes.themes.length, 3);
      final a = themes.forDate('2026-09-12')!;
      expect(themes.forDate('2026-09-12')!.label, a.label);
      final labels = {for (var d = 10; d < 13; d++) themes.forDate('2026-09-$d')!.label};
      expect(labels.length, 3);
    });

    test('anchor picks avoid recent words when it can', () {
      const theme = HuntTheme(label: 'Music', words: {'CHOIR', 'OCTAVE', 'MAST'});
      for (var seed = 0; seed < 5; seed++) {
        expect(HuntThemeSet.pickAnchor(theme, Random(seed), exclude: {'CHOIR'}), 'OCTAVE');
      }
      expect(HuntThemeSet.pickAnchor(theme, Random(0), exclude: {'CHOIR', 'OCTAVE'}), isNotNull);
    });
  });
}

// Generation benchmark for the crossword, checking PORTING_SPEC.md §11's
// acceptance targets against the real word list asset. Pure Dart — no
// Flutter, no database — so it runs straight from the command line:
//
//   dart run tool/crossword_bench.dart [runsPerSize]
//
// Reports, per size: fill success rate, wall time, achieved white %, entry
// length histogram, and quality-gate offenders. §11.1 is explicit that a
// 17x17 showing many 8+ letter entries means the port has reproduced the
// original bug, so the histogram is the quickest signal that something has
// regressed.

import 'dart:io';

import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/crossword/generator.dart';
import 'package:word_wizard/domain/crossword/skeleton.dart';
import 'package:word_wizard/domain/crossword/word_list.dart';

const _srsWords = ['SPARE', 'CANDID', 'LUCID', 'TERSE', 'OPAQUE', 'WRY', 'DEFT'];

void main(List<String> args) {
  final runs = args.isEmpty ? 8 : int.parse(args.first);

  final loadClock = Stopwatch()..start();
  final entries = parseWordList(File('assets/crossword/wordlist.tsv').readAsStringSync());
  loadClock.stop();
  final pool = entries.where(inFillPool).length;
  stdout.writeln('word list: ${entries.length} entries, fill pool $pool, '
      'parsed in ${loadClock.elapsedMilliseconds}ms');

  for (final difficulty in CrosswordDifficulty.values) {
    final n = difficulty.size;
    stdout.writeln('\n=== ${difficulty.label} ($n x $n, '
        'maxEntryLen ${difficulty.maxEntryLen}, whiteTarget ${difficulty.whiteTarget}) ===');

    var solved = 0;
    var totalMs = 0;
    var totalOffenders = 0;
    final lengths = <int, int>{};
    final whites = <double>[];

    for (var run = 0; run < runs; run++) {
      final clock = Stopwatch()..start();
      final puzzle = generateCrossword(CrosswordGenerationRequest(
        difficulty: difficulty,
        entries: entries,
        // A stand-in study word per run, so the anchor path is exercised the
        // way the app uses it.
        srsAnchors: [
          CrosswordEntry.synthetic(text: _srsWords[run % _srsWords.length], display: 'x', entryId: 1),
        ],
        recentUsage: const {},
        weekday: (run % 7) + 1,
        seed: 1000 + run,
      ));
      clock.stop();
      totalMs += clock.elapsedMilliseconds;

      if (puzzle == null) {
        stdout.writeln('  run $run: FAILED in ${clock.elapsedMilliseconds}ms');
        continue;
      }
      solved++;

      final white = <(int, int)>{};
      for (final word in puzzle.words) {
        lengths[word.answer.length] = (lengths[word.answer.length] ?? 0) + 1;
        white.addAll(word.cells);
      }
      whites.add(white.length / (n * n));

      _assertInvariants(puzzle, n);

      final index = CrosswordPatternIndex.build(entries.where(inFillPool));
      var offenders = 0;
      final worst = <String>[];
      for (final word in puzzle.words) {
        // §9.1 scores non-anchor entries only: an SRS word is required to be
        // there regardless of what the word list thinks of it.
        if (word.fromStudyPool) continue;
        final floor = qualityFloorByLength[word.answer.length];
        if (floor == null) continue;
        final entry = index.byText[word.answer];
        if (entry == null || entry.score < floor) {
          offenders++;
          worst.add(word.answer);
        }
      }
      totalOffenders += offenders;
      stdout.writeln('  run $run: ${clock.elapsedMilliseconds}ms, '
          '${puzzle.words.length} slots, '
          '${(white.length / (n * n) * 100).toStringAsFixed(1)}% white, '
          'quality ${puzzle.qualityScore.toStringAsFixed(1)}, '
          'theme ${puzzle.themeName}/${puzzle.themeKind}'
          '${offenders > 0 ? ', OFFENDERS $worst' : ''}');
      final anchorHit = puzzle.words.any((w) => w.fromStudyPool);
      if (!anchorHit) stdout.writeln('      (no study word placed)');
      if (run == 0) _printGrid(puzzle, n);
    }

    final histogram = (lengths.keys.toList()..sort())
        .map((len) => '$len:${lengths[len]}')
        .join(', ');
    stdout.writeln('  -> solved $solved/$runs, '
        'mean ${(totalMs / runs).round()}ms, '
        'mean white ${whites.isEmpty ? '-' : (whites.reduce((a, b) => a + b) / whites.length * 100).toStringAsFixed(1)}%, '
        'offenders $totalOffenders');
    stdout.writeln('  -> entry lengths: $histogram');
  }
}

void _printGrid(CrosswordPuzzle puzzle, int n) {
  final letters = <(int, int), String>{};
  for (final word in puzzle.words) {
    final cells = word.cells;
    for (var i = 0; i < cells.length; i++) {
      letters[cells[i]] = word.answer[i];
    }
  }
  for (var r = 0; r < n; r++) {
    final row = StringBuffer('      ');
    for (var c = 0; c < n; c++) {
      row.write(letters[(r, c)] ?? '#');
    }
    stdout.writeln(row);
  }
}

/// §11's invariants 1-5, asserted on every generated puzzle.
void _assertInvariants(CrosswordPuzzle puzzle, int n) {
  final letters = <(int, int), String>{};
  for (final word in puzzle.words) {
    final cells = word.cells;
    for (var i = 0; i < cells.length; i++) {
      final existing = letters[cells[i]];
      if (existing != null && existing != word.answer[i]) {
        throw StateError('crossing disagreement at ${cells[i]}: '
            '$existing vs ${word.answer[i]} (${word.answer})');
      }
      letters[cells[i]] = word.answer[i];
    }
    if (word.answer.length < 3) throw StateError('slot shorter than 3: ${word.answer}');
  }

  final black = List.generate(
    n,
    (r) => List.generate(n, (c) => !letters.containsKey((r, c))),
  );
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (black[r][c] != black[n - 1 - r][n - 1 - c]) {
        throw StateError('symmetry broken at ($r,$c)');
      }
    }
  }
  if (!isConnected(black, n)) throw StateError('white cells not connected');

  final texts = puzzle.words.map((w) => w.answer).toSet();
  if (texts.length != puzzle.words.length) {
    throw StateError('duplicate answers in one puzzle');
  }
}

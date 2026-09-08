import 'dart:math';

import 'crossword_models.dart';
import 'skeleton.dart';
import 'solver.dart';
import 'themes.dart';
import 'word_list.dart';

/// Orchestration, quality gate and puzzle scoring — PORTING_SPEC.md §9.

/// Everything a generation needs, bundled so it can be handed wholesale to
/// `Isolate.run` — this does real backtracking search and can take seconds on
/// a Mega grid, so the caller always runs it off the UI isolate.
class CrosswordGenerationRequest {
  final CrosswordDifficulty difficulty;

  /// The parsed word list asset, full (not the fill pool) — anchors draw on
  /// entries the fill pool excludes.
  final List<CrosswordEntry> entries;

  /// SRS words to anchor the puzzle on, highest priority, already normalized
  /// to A-Z uppercase.
  final List<CrosswordEntry> srsAnchors;

  /// Answers from the last 10 puzzles at this size (§A.2 requirement 10).
  final Set<String> recentUsage;

  /// 1 = Monday, matching [DateTime.weekday]; drives the day's theme.
  final int weekday;

  final int seed;

  const CrosswordGenerationRequest({
    required this.difficulty,
    required this.entries,
    required this.srsAnchors,
    required this.recentUsage,
    required this.weekday,
    required this.seed,
  });
}

/// What crosses the isolate boundary: the raw asset text rather than 49,000
/// parsed [CrosswordEntry] objects, which would have to be copied one by one.
/// Parsing happens on the far side, where the search runs.
///
/// Every field is a plain sendable value — strings, ints, an enum, records —
/// so this can be handed straight to `Isolate.run`.
class CrosswordIsolateRequest {
  final String wordListSource;
  final CrosswordDifficulty difficulty;

  /// SRS words to anchor on, as (grid text, display form, dictionary entry id).
  final List<(String, String, int)> srsWords;

  final Set<String> recentUsage;
  final int weekday;
  final int seed;

  const CrosswordIsolateRequest({
    required this.wordListSource,
    required this.difficulty,
    required this.srsWords,
    required this.recentUsage,
    required this.weekday,
    required this.seed,
  });
}

/// Isolate entry point: parse the asset, resolve the SRS anchors against it,
/// generate.
CrosswordPuzzle? generateCrosswordFromSource(CrosswordIsolateRequest request) {
  final entries = parseWordList(request.wordListSource);
  final byText = {for (final e in entries) e.text: e};

  final srsAnchors = <CrosswordEntry>[
    for (final (text, display, entryId) in request.srsWords)
      // §7.2: an SRS word that isn't in the list still gets placed — a
      // synthesized entry carries it into the grid. The user's vocabulary is
      // the point of the product, so it outranks the word list's opinion.
      byText[text] ?? CrosswordEntry.synthetic(text: text, display: display, entryId: entryId),
  ];

  return generateCrossword(CrosswordGenerationRequest(
    difficulty: request.difficulty,
    entries: entries,
    srsAnchors: srsAnchors,
    recentUsage: request.recentUsage,
    weekday: request.weekday,
    seed: request.seed,
  ));
}

/// The result of one generation. [words] carry no clue text yet — clues are
/// resolved by `CrosswordRepository` afterwards, for the words that actually
/// landed in the grid rather than the whole pool.
CrosswordPuzzle? generateCrossword(
  CrosswordGenerationRequest request, {
  int skeletonAttempts = 12,
  Duration perSolveBudget = const Duration(seconds: 8),
}) {
  final difficulty = request.difficulty;
  final n = difficulty.size;
  final rng = Random(request.seed);

  final overall = Stopwatch()..start();
  final overallBudget = difficulty.overallBudget;

  // §6.3: the index is built over the fill pool only. Every word in it is
  // recognizable, which is what makes any valid fill a publishable fill.
  final fillIndex = CrosswordPatternIndex.build(request.entries.where(inFillPool));

  final theme = selectTheme(
    entries: request.entries,
    weekday: request.weekday,
    maxAnchors: difficulty.maxAnchors,
    gridSize: n,
    recentUsage: request.recentUsage,
    rng: rng,
  );

  final srsCandidates = [
    for (final entry in request.srsAnchors)
      if (entry.length >= 3 && entry.length <= n) entry,
  ];
  // How many study words this puzzle should manage to place, if the grids
  // cooperate.
  final srsWanted = min(srsCandidates.length, difficulty.maxAnchors);

  CrosswordPuzzle? best;
  var bestOffenderCount = 1 << 30;

  for (var attempt = 0; attempt < skeletonAttempts; attempt++) {
    if (overall.elapsed > overallBudget) break;

    // Whether to reject a skeleton that can't hold every study word. Held for
    // most of the attempt budget, then relaxed so a puzzle still ships: §7.2's
    // "if they cannot reasonably be incorporated, use fewer or none".
    final insistOnSrs = attempt < (skeletonAttempts * 2) ~/ 3;

    final black = generateSkeletonCapped(n, difficulty.maxEntryLen, difficulty.whiteTarget, rng);
    // Uncommon at maxAttempts 800 (30/30 per call at both 9x9 and 17x17 in
    // the reference measurements). Just consume another orchestration
    // attempt. Deliberately *not* falling back to an unconstrained random
    // skeleton: that produces exactly the long-entry, high-white-percentage
    // grids §10.1 identifies as unfillable, turning a clean failure into a
    // bad puzzle.
    if (black == null) continue;

    final slots = extractSlots(black, n);
    final anchors = anchorsForSkeleton(
      srsAnchors: srsCandidates,
      themeAnchors: theme.anchors,
      maxAnchors: difficulty.maxAnchors,
      slots: slots,
    );
    final (preAssigned, anchorsUsed) = fitAnchors(anchors, slots);

    if (insistOnSrs) {
      final srsTexts = {for (final e in srsCandidates) e.text};
      final placed = anchorsUsed.where((a) => srsTexts.contains(a.text)).length;
      // Another skeleton costs ~2ms; a puzzle missing the user's word costs
      // the whole point of the feature.
      if (placed < srsWanted) continue;
    }

    final remainingBudget = overallBudget - overall.elapsed;
    if (remainingBudget <= Duration.zero) break;

    final solver = CrosswordSolver(
      slots: slots,
      index: fillIndex,
      rng: rng,
      preAssigned: preAssigned,
      recentUsage: request.recentUsage,
      timeBudget: perSolveBudget < remainingBudget ? perSolveBudget : remainingBudget,
    );
    final result = solver.solve();
    if (result == null) continue;

    refineFill(result, slots, fillIndex, protectedSlots: preAssigned.keys.toSet());

    final anchorTexts = preAssigned.values.toSet();
    final puzzle = _assemble(
      fill: result,
      slots: slots,
      size: n,
      index: fillIndex,
      anchorEntries: {for (final a in anchorsUsed) a.text: a},
      srsTexts: {for (final a in request.srsAnchors) a.text},
      theme: theme,
      recentUsage: request.recentUsage,
      anchorTexts: anchorTexts,
    );

    final offenders = _qualityOffenders(result, index: fillIndex, anchorTexts: anchorTexts);
    if (offenders == 0) return puzzle; // clean — stop early
    if (offenders < bestOffenderCount) {
      bestOffenderCount = offenders;
      best = puzzle;
    }
  }

  return best; // may be null if nothing solved at all
}

/// Non-anchor entries below their length's recognizability floor (§9.1).
int _qualityOffenders(
  Map<int, String> fill, {
  required CrosswordPatternIndex index,
  required Set<String> anchorTexts,
}) {
  var count = 0;
  for (final text in fill.values) {
    if (anchorTexts.contains(text)) continue;
    final floor = qualityFloorByLength[text.length];
    if (floor == null) continue; // no floor above length 9
    final entry = index.byText[text];
    if (entry == null || entry.score < floor) count++;
  }
  return count;
}

CrosswordPuzzle _assemble({
  required Map<int, String> fill,
  required List<CrosswordSlot> slots,
  required int size,
  required CrosswordPatternIndex index,
  required Map<String, CrosswordEntry> anchorEntries,
  required Set<String> srsTexts,
  required CrosswordTheme theme,
  required Set<String> recentUsage,
  required Set<String> anchorTexts,
}) {
  final words = <CrosswordWordPlacement>[];
  final placedEntries = <CrosswordEntry>[];

  for (final slot in slots) {
    final text = fill[slot.slotId]!;
    // An anchor may be a synthesized SRS entry that was never in the fill
    // index, so check the anchor map first.
    final entry = anchorEntries[text] ?? index.byText[text];
    if (entry != null) placedEntries.add(entry);
    words.add(CrosswordWordPlacement(
      number: slot.number,
      direction: slot.direction,
      row: slot.row,
      col: slot.col,
      answer: text,
      entryId: entry?.entryId ?? -1,
      clue: '', // filled in by CrosswordRepository once generation succeeds
      fromStudyPool: srsTexts.contains(text),
    ));
  }

  return CrosswordPuzzle(
    width: size,
    height: size,
    words: words,
    themeName: theme.name,
    themeKind: theme.kind,
    qualityScore: scorePuzzle(
      placedEntries,
      anchorCount: anchorTexts.length,
      themeKind: theme.kind,
      recentUsage: recentUsage,
    ),
  );
}

/// Puzzle-level score, §9.2. Reported, not used to drive search.
double scorePuzzle(
  List<CrosswordEntry> entries, {
  required int anchorCount,
  required String themeKind,
  required Set<String> recentUsage,
}) {
  if (entries.isEmpty) return 0;
  var scoreSum = 0.0;
  var obscuritySum = 0.0;
  var repetitions = 0;
  final clueKinds = <String>{};
  for (final entry in entries) {
    scoreSum += entry.score;
    obscuritySum += max(0.0, 3.0 - entry.freqZipf);
    if (recentUsage.contains(entry.text)) repetitions++;
    // The spec's "distinct clue types" term, in this app's terms: what kind
    // of clue the dictionary will be able to produce for the word.
    clueKinds.add(entry.isAcronym
        ? 'abbreviation'
        : entry.isProper
            ? 'proper'
            : entry.synsetCount > 1
                ? 'definition'
                : 'bare');
  }
  final answerQuality = scoreSum / entries.length;
  final obscurity = obscuritySum / entries.length;
  final varietyBonus = min(clueKinds.length, 5) * 0.5;
  final anchorBonus = 2.0 * anchorCount;
  final themeBonus = themeKind == 'hidden_word' ? 3.0 : 1.0;
  final repetitionPen = 2.0 * repetitions;

  return answerQuality + varietyBonus + anchorBonus + themeBonus - obscurity - repetitionPen;
}

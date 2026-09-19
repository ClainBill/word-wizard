import 'dart:math';

import 'clues.dart';
import 'crossword_models.dart';
import 'skeleton.dart';
import 'solver.dart';
import 'themes.dart';
import 'word_list.dart';

/// Orchestration, quality gate and puzzle scoring — PORTING_SPEC.md §9.

/// One SRS word the app wants anchored, with everything the generator needs
/// to place and clue it without touching the dictionary database — which it
/// cannot, because generation runs on a background isolate.
typedef CrosswordSrsWord = ({String text, String display, int entryId, String? clue});

/// Everything a generation needs, bundled so it can be handed wholesale to
/// `Isolate.run` — this does real backtracking search and can take seconds on
/// a Mega grid, so the caller always runs it off the UI isolate.
class CrosswordGenerationRequest {
  final CrosswordDifficulty difficulty;

  /// The parsed word list, full (not the fill pool) — anchors draw on entries
  /// the fill pool excludes.
  final List<CrosswordEntry> entries;

  /// SRS words to anchor the puzzle on, highest priority first, already
  /// normalized to A-Z uppercase.
  final List<CrosswordEntry> srsAnchors;

  /// Answers the user has **solved unaided** in the last 10 puzzles (§6.2a).
  /// Not "answers that appeared recently" — see `history.dart`.
  final Set<String> blockedAnswers;

  /// 1 = Monday, matching [DateTime.weekday]; drives the day's theme.
  final int weekday;

  final int seed;

  /// Multiplies the difficulty's time budgets. The budgets were measured on
  /// AOT-compiled release builds; a debug build runs the search under the
  /// JIT, several times slower, and would otherwise give up on grids a
  /// release build fills in well under a second.
  final double budgetScale;

  const CrosswordGenerationRequest({
    required this.difficulty,
    required this.entries,
    required this.srsAnchors,
    required this.blockedAnswers,
    required this.weekday,
    required this.seed,
    this.budgetScale = 1.0,
  });
}

/// What crosses the isolate boundary: the raw asset text rather than 72,000
/// parsed [CrosswordEntry] objects, which would have to be copied one by one.
/// Parsing happens on the far side, where the search runs.
///
/// Every field is a plain sendable value — strings, ints, an enum, records —
/// so this can be handed straight to `Isolate.run`.
class CrosswordIsolateRequest {
  final String wordListSource;
  final CrosswordDifficulty difficulty;
  final List<CrosswordSrsWord> srsWords;
  final Set<String> blockedAnswers;
  final int weekday;
  final int seed;

  /// See [CrosswordGenerationRequest.budgetScale].
  final double budgetScale;

  const CrosswordIsolateRequest({
    required this.wordListSource,
    required this.difficulty,
    required this.srsWords,
    required this.blockedAnswers,
    required this.weekday,
    required this.seed,
    this.budgetScale = 1.0,
  });
}

/// Isolate entry point: parse the asset, resolve the SRS anchors against it,
/// generate.
CrosswordPuzzle? generateCrosswordFromSource(CrosswordIsolateRequest request) {
  final entries = parseWordList(request.wordListSource);
  final byText = {for (final e in entries) e.text: e};

  final srsAnchors = <CrosswordEntry>[
    for (final word in request.srsWords)
      // §7.2: an SRS word that isn't in the list still gets placed — a
      // synthesized entry carries it into the grid. The user's vocabulary is
      // the point of the product, so it outranks the word list's opinion.
      // The dictionary clue the app resolved for it comes along, because an
      // unclued anchor lands a stub in the puzzle's most prominent slot.
      _withEntryId(byText[word.text], word) ??
          CrosswordEntry.synthetic(
            text: word.text,
            display: word.display,
            entryId: word.entryId,
            clue: word.clue,
          ),
  ];

  return generateCrossword(CrosswordGenerationRequest(
    difficulty: request.difficulty,
    entries: entries,
    srsAnchors: srsAnchors,
    blockedAnswers: request.blockedAnswers,
    weekday: request.weekday,
    seed: request.seed,
    budgetScale: request.budgetScale,
  ));
}

/// An asset entry re-tagged with the dictionary row it corresponds to, so a
/// study word the user solves can be credited back to its flashcard.
CrosswordEntry? _withEntryId(CrosswordEntry? entry, CrosswordSrsWord word) {
  if (entry == null) return null;
  return CrosswordEntry(
    text: entry.text,
    display: entry.display,
    freqZipf: entry.freqZipf,
    synsetCount: entry.synsetCount,
    isProper: entry.isProper,
    isPhrase: entry.isPhrase,
    isCrosswordese: entry.isCrosswordese,
    tags: entry.tags,
    score: entry.score,
    editorTier: entry.editorTier,
    familiarity: entry.familiarity,
    clues: entry.clues,
    entryId: word.entryId,
  );
}

/// The result of one generation, clues and all.
CrosswordPuzzle? generateCrossword(
  CrosswordGenerationRequest request, {
  int skeletonAttempts = 30,
}) {
  final difficulty = request.difficulty;
  final n = difficulty.size;
  final rng = Random(request.seed);

  final overall = Stopwatch()..start();
  final overallBudget = difficulty.overallBudget * request.budgetScale;
  final solveBudget = difficulty.solveBudget * request.budgetScale;

  // §6.3: the index is built over the fill pool only. Every word in it is
  // recognizable *and* cluable, which is what makes any valid fill a
  // publishable fill.
  final fillIndex = CrosswordPatternIndex.build(request.entries.where(inFillPool));

  final theme = selectTheme(
    entries: request.entries,
    weekday: request.weekday,
    maxAnchors: difficulty.maxAnchors,
    gridSize: n,
    blockedAnswers: request.blockedAnswers,
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
    // skeleton — the reference implementation keeps one and §9 says not to
    // port it: it produces exactly the long-entry, high-white-percentage
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
    final (preAssigned, anchorsUsed) = fitAnchors(anchors, slots, rng: rng);

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
      blockedAnswers: request.blockedAnswers,
      timeBudget: solveBudget < remainingBudget ? solveBudget : remainingBudget,
    );
    final result = solver.solve();
    if (result == null) continue;

    final fill = refineFill(
      result,
      slots,
      fillIndex,
      protectedSlots: preAssigned.keys.toSet(),
      blockedAnswers: request.blockedAnswers,
    );

    final anchorTexts = preAssigned.values.toSet();
    final puzzle = _assemble(
      fill: fill,
      slots: slots,
      size: n,
      index: fillIndex,
      anchorEntries: {for (final a in anchorsUsed) a.text: a},
      srsTexts: {for (final a in request.srsAnchors) a.text},
      theme: theme,
      blockedAnswers: request.blockedAnswers,
      anchorTexts: anchorTexts,
      seed: request.seed,
      rng: rng,
    );

    final offenders = qualityOffenders(fill.values, index: fillIndex, anchorTexts: anchorTexts);
    if (offenders == 0) return puzzle; // clean — stop early
    if (offenders < bestOffenderCount) {
      bestOffenderCount = offenders;
      best = puzzle;
    }
  }

  return best; // may be null if nothing solved at all
}

/// Non-anchor entries below their length's recognizability floor (§9.1).
///
/// With §4's grid shapes and §6.3's fill pool this reports zero at all three
/// sizes, so it functions as insurance rather than as the main quality
/// mechanism. It stays because it is cheap and it catches regressions.
int qualityOffenders(
  Iterable<String> fill, {
  required CrosswordPatternIndex index,
  required Set<String> anchorTexts,
}) {
  var count = 0;
  for (final text in fill) {
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
  required Set<String> blockedAnswers,
  required Set<String> anchorTexts,
  required int seed,
  required Random rng,
}) {
  final words = <CrosswordWordPlacement>[];
  final placedEntries = <CrosswordEntry>[];
  final clueTypes = <CrosswordClueType>{};

  for (final slot in slots) {
    final text = fill[slot.slotId]!;
    // An anchor may be a synthesized SRS entry that was never in the fill
    // index, so check the anchor map first.
    final entry = anchorEntries[text] ??
        index.byText[text] ??
        CrosswordEntry.synthetic(text: text, display: text, entryId: -1);
    placedEntries.add(entry);
    final clue = pickClue(entry, rng);
    clueTypes.add(clue.type);
    words.add(CrosswordWordPlacement(
      number: slot.number,
      slotId: slot.slotId,
      direction: slot.direction,
      row: slot.row,
      col: slot.col,
      answer: text,
      display: entry.display,
      entryId: entry.entryId,
      clue: clue.text,
      clueType: clue.type,
      freqZipf: entry.freqZipf,
      fromStudyPool: srsTexts.contains(text),
    ));
  }

  return CrosswordPuzzle(
    width: size,
    height: size,
    words: words,
    themeName: theme.name,
    themeKind: theme.kind,
    anchors: anchorTexts.toList(),
    seed: seed,
    qualityScore: scorePuzzle(
      placedEntries,
      clueTypes: clueTypes,
      anchorCount: anchorTexts.length,
      themeKind: theme.kind,
      blockedAnswers: blockedAnswers,
    ),
  );
}

/// Puzzle-level score, §9.2. Reported, not used to drive search.
double scorePuzzle(
  List<CrosswordEntry> entries, {
  required Set<CrosswordClueType> clueTypes,
  required int anchorCount,
  required String themeKind,
  required Set<String> blockedAnswers,
}) {
  if (entries.isEmpty) return 0;
  var scoreSum = 0.0;
  var obscuritySum = 0.0;
  var repetitions = 0;
  for (final entry in entries) {
    scoreSum += entry.score;
    obscuritySum += max(0.0, 3.0 - entry.freqZipf);
    if (blockedAnswers.contains(entry.text)) repetitions++;
  }
  final answerQuality = scoreSum / entries.length;
  final obscurity = obscuritySum / entries.length;
  final varietyBonus = min(clueTypes.length, 5) * 0.5;
  final anchorBonus = 2.0 * anchorCount;
  final themeBonus = themeKind == 'hidden_word' ? 3.0 : 1.0;
  final repetitionPen = 2.0 * repetitions;

  return answerQuality + varietyBonus + anchorBonus + themeBonus - obscurity - repetitionPen;
}

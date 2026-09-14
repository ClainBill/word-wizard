/// Board generation — research `multi.py` (milestone 0.4), the joint SRS
/// placement engine, with its algorithm contract kept intact:
///
/// 1. Anchors arrive in **priority order** and are validated against the
///    accepted lexicon; unknown spellings are refused, never injected.
/// 2. A letter-inventory lower bound rejects impossible anchor sets before
///    any search.
/// 3. Anchors are placed jointly by bounded backtracking over simple paths,
///    longest first, preferring cells that already hold the letter needed
///    so anchors share tiles. Empty cells are then filled from
///    frequency-weighted letters.
/// 4. Candidates are scanned against the **main** lexicon only and ranked:
///    gate 20-60 main words covering ≥ 12 tiles; prefer ~40 words, wide
///    coverage, a few long words, few word/word+S pairs — and, added here,
///    a few extra words from the day's theme.
/// 5. If no candidate passes, the lowest-priority anchor is dropped and the
///    search repeats. Falling all the way to zero anchors still yields a
///    board; the result says exactly which anchors were omitted and why.
/// 6. The chosen board is scanned once against the **full accepted**
///    lexicon by the certified solver. A scan that exhausts its budget
///    throws; no partial answer set is ever published.
/// 7. Anchors, main and bonus are disjoint classes, so nothing scores
///    twice.
library;

import 'dart:math';
import 'dart:typed_data';

import 'hunt_lexicon.dart';
import 'hunt_models.dart';
import 'hunt_solver.dart';

/// English letter frequencies for filling the cells no anchor claims — the
/// research's fill distribution, unchanged.
const String _fillLetters = 'ETAOINSHRDLUCMFPGWYBVKXJQZ';
const List<int> _fillWeights = [
  12, 9, 8, 7, 7, 7, 6, 6, 6, 4, 4, 3, 3, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1 //
];
final int _fillTotal = _fillWeights.fold(0, (a, b) => a + b);

String _weightedLetter(Random rng) {
  var r = rng.nextInt(_fillTotal);
  for (var i = 0; i < _fillWeights.length; i++) {
    r -= _fillWeights[i];
    if (r < 0) return _fillLetters[i];
  }
  return _fillLetters[0];
}

/// Result of one placement attempt: the board, or null, plus the search
/// nodes spent (0 when the capacity bound rejected the set outright).
typedef HuntPlacement = ({List<String>? board, int nodes});

/// Jointly places [words] on an empty board, then fills the rest.
///
/// Letters may be shared between words: a cell already holding the letter
/// a word needs next is preferred over an empty one, so two anchors that
/// can cross will. Backtracking undoes cells on failure. [budget] bounds
/// the recursion nodes across the whole placement; a bounded failure means
/// no layout was found, not that none exists.
HuntPlacement huntPlaceAnchors(List<String> words, Random rng, {int budget = 3000}) {
  // Capacity lower bound: each letter is needed at least as many times as
  // the word that needs it most. More than 16 is impossible outright.
  final required = Int32List(26);
  for (final w in words) {
    final count = Int32List(26);
    for (var i = 0; i < w.length; i++) {
      count[w.codeUnitAt(i) - 0x41]++;
    }
    for (var c = 0; c < 26; c++) {
      if (count[c] > required[c]) required[c] = count[c];
    }
  }
  var needed = 0;
  for (var c = 0; c < 26; c++) {
    needed += required[c];
  }
  if (needed > huntCells) return (board: null, nodes: 0);

  final board = Int32List(huntCells)..fillRange(0, huntCells, -1);
  var nodes = 0;
  final order = [...words]..sort((a, b) => b.length != a.length ? b.length - a.length : a.compareTo(b));
  // One path per word: a later word's search must not scribble over the
  // cells an earlier, still-backtrackable word is standing on.
  final paths = [for (final _ in order) Int32List(huntCells)];

  // Mutual recursion: finishing word k descends into word k+1 *inside* the
  // search, so a later word that won't fit backtracks into the earlier
  // words' alternative placements rather than giving up on them.
  late bool Function(int k) nextWord;

  bool step(int k, int depth) {
    nodes++;
    if (nodes > budget) return false;
    final word = order[k];
    if (depth == word.length) return nextWord(k + 1);
    final path = paths[k];
    final letter = word.codeUnitAt(depth) - 0x41;
    final options = depth == 0
        ? [for (var c = 0; c < huntCells; c++) c]
        : [...huntNeighbours[path[depth - 1]]];
    options.shuffle(rng);
    // Stable partition: cells already holding the letter first, in shuffled
    // order, then the rest.
    final preferred = [for (final c in options) if (board[c] == letter) c];
    final others = [for (final c in options) if (board[c] != letter) c];
    for (final c in preferred.followedBy(others)) {
      var onPath = false;
      for (var i = 0; i < depth; i++) {
        if (path[i] == c) {
          onPath = true;
          break;
        }
      }
      if (onPath) continue;
      if (board[c] != -1 && board[c] != letter) continue;
      final old = board[c];
      board[c] = letter;
      path[depth] = c;
      if (step(k, depth + 1)) return true;
      board[c] = old;
      if (nodes > budget) return false;
    }
    return false;
  }

  nextWord = (int k) => k == order.length || step(k, 0);

  if (!nextWord(0)) return (board: null, nodes: nodes);
  return (
    board: [
      for (var c = 0; c < huntCells; c++)
        board[c] == -1 ? _weightedLetter(rng) : String.fromCharCode(board[c] + 0x41),
    ],
    nodes: nodes,
  );
}

/// What the generator was asked for. [anchors] is priority order — the
/// first is the most important to keep.
class HuntGenerationRequest {
  final int seed;
  final List<HuntAnchor> anchors;
  final String? themeLabel;

  /// The day's theme vocabulary, for marking theme finds and nudging the
  /// ranking toward boards that carry a few of them.
  final Set<String> themeWords;
  final int attempts;
  final int placementBudget;
  final int scanBudget;

  const HuntGenerationRequest({
    required this.seed,
    required this.anchors,
    this.themeLabel,
    this.themeWords = const {},
    this.attempts = 40,
    this.placementBudget = 3000,
    this.scanBudget = 1000000,
  });
}

/// Per anchor-count pass: how the search went.
typedef HuntPassDiagnostics = ({
  int anchorCount,
  int placedCandidates,
  int attempts,
  int placementNodes,
  bool passed,
});

/// Candidate metrics the ranking is computed from; kept on the result so a
/// debug screen can show why a board won.
typedef HuntBoardMetrics = ({
  int mainCount,
  int coverage,
  int longWords,
  int suffixPairs,
  int themeHits,
});

class HuntGeneration {
  final HuntPuzzle? puzzle;
  final HuntBoardMetrics? metrics;
  final List<HuntPassDiagnostics> diagnostics;

  /// Set when no board at all could be produced — which, since the search
  /// falls back to zero anchors, means every unanchored candidate failed
  /// the quality gate too.
  final String? failure;

  const HuntGeneration({
    required this.puzzle,
    required this.metrics,
    required this.diagnostics,
    this.failure,
  });

  bool get success => puzzle != null;
}

int _popCount(int v) {
  var n = 0;
  while (v != 0) {
    v &= v - 1;
    n++;
  }
  return n;
}

/// Seed for one anchor-count pass — a fixed mix so a replay with the same
/// seed and anchors produces the same board.
int _passSeed(int seed, int count) => (seed * 1000003 + count * 7919 + 17) & 0x7fffffff;

/// Generates a board for [request] against [lexicon]. Pure and
/// deterministic in (seed, anchors, theme words, lexicon).
HuntGeneration generateHunt(HuntLexicon lexicon, HuntGenerationRequest request) {
  if (request.attempts < 1) throw ArgumentError('Positive attempts required');

  // Normalise and de-duplicate, keeping caller order as priority.
  final seenTexts = <String>{};
  final requested = <HuntAnchor>[];
  for (final anchor in request.anchors) {
    final text = anchor.text.toUpperCase();
    if (!seenTexts.add(text)) continue;
    if (!lexicon.isAnchorable(text)) {
      throw ArgumentError('Anchor "$text" requires lexical review: not an accepted spelling');
    }
    requested.add(HuntAnchor(
      text: text,
      display: anchor.display,
      kind: anchor.kind,
      entryId: anchor.entryId,
      clue: anchor.clue,
    ));
  }

  final diagnostics = <HuntPassDiagnostics>[];

  for (var count = requested.length; count >= 0; count--) {
    final anchors = requested.sublist(0, count);
    final anchorTexts = {for (final a in anchors) a.text};
    final rng = Random(_passSeed(request.seed, count));
    var placed = 0;
    var nodes = 0;
    List<String>? bestBoard;
    HuntBoardMetrics? bestMetrics;
    var bestEligible = false;
    var bestScore = double.negativeInfinity;

    for (var attempt = 0; attempt < request.attempts; attempt++) {
      final placement = huntPlaceAnchors(
        [for (final a in anchors) a.text],
        rng,
        budget: request.placementBudget,
      );
      nodes += placement.nodes;
      final board = placement.board;
      if (board == null) continue;
      placed++;

      Map<String, HuntWord> found;
      try {
        found = huntSolveChecked(board, lexicon.main, maxStates: request.scanBudget);
      } on HuntIncompleteSearch {
        // Pathological letter layout; a candidate we can't certify is a
        // candidate we don't rank.
        continue;
      }

      var mainCount = 0;
      var uses = 0;
      var longWords = 0;
      var suffixPairs = 0;
      var themeHits = 0;
      for (final entry in found.entries) {
        final word = entry.key;
        if (anchorTexts.contains(word)) continue;
        mainCount++;
        uses |= entry.value.uses;
        if (word.length >= 7) longWords++;
        if (found.containsKey('${word}S')) suffixPairs++;
        if (request.themeWords.contains(word)) themeHits++;
      }
      final coverage = _popCount(uses);
      final eligible = mainCount >= 20 && mainCount <= 60 && coverage >= 12;
      final score = -(mainCount - 40).abs() +
          2.0 * coverage +
          min(8, longWords) -
          0.5 * suffixPairs +
          min(4, themeHits);

      final better = bestBoard == null ||
          (eligible && !bestEligible) ||
          (eligible == bestEligible && score > bestScore);
      if (better) {
        bestBoard = board;
        bestEligible = eligible;
        bestScore = score;
        bestMetrics = (
          mainCount: mainCount,
          coverage: coverage,
          longWords: longWords,
          suffixPairs: suffixPairs,
          themeHits: themeHits,
        );
      }
    }

    diagnostics.add((
      anchorCount: count,
      placedCandidates: placed,
      attempts: request.attempts,
      placementNodes: nodes,
      passed: bestBoard != null && bestEligible,
    ));
    if (bestBoard == null || !bestEligible) continue;

    // The one full scan, against everything the board will accept. Let a
    // budget failure propagate: it is a bug in the gate, not a board to
    // ship with a hole in its answer key.
    final found = huntSolveChecked(bestBoard, lexicon.accepted, maxStates: request.scanBudget);

    final anchorWords = <String, HuntWord>{};
    for (final anchor in anchors) {
      final info = found[anchor.text];
      if (info == null) {
        throw StateError('Placed anchor ${anchor.text} missing from the certified scan');
      }
      anchorWords[anchor.text] = info;
    }
    final main = <String, HuntWord>{};
    final bonus = <String, HuntWord>{};
    final themeWords = <String>{};
    for (final entry in found.entries) {
      final word = entry.key;
      if (request.themeWords.contains(word)) themeWords.add(word);
      if (anchorTexts.contains(word)) continue;
      if (lexicon.main.contains(word)) {
        main[word] = entry.value;
      } else {
        bonus[word] = entry.value;
      }
    }
    for (final anchor in anchors) {
      if (anchor.kind == HuntAnchorKind.theme) themeWords.add(anchor.text);
    }

    final themeAnchorKept = anchors.any((a) => a.kind == HuntAnchorKind.theme);
    return HuntGeneration(
      puzzle: HuntPuzzle(
        seed: request.seed,
        board: bestBoard,
        anchors: anchors,
        omitted: [
          for (final a in requested.sublist(count))
            HuntOmittedAnchor(anchor: a, reason: 'placement budget or quality gate'),
        ],
        anchorWords: anchorWords,
        main: main,
        bonus: bonus,
        // A theme with no theme word on the board isn't a theme.
        themeLabel: themeAnchorKept ? request.themeLabel : null,
        themeWords: themeAnchorKept ? themeWords : const {},
        dictionaryHash: lexicon.fingerprint,
      ),
      metrics: bestMetrics,
      diagnostics: diagnostics,
    );
  }

  return HuntGeneration(
    puzzle: null,
    metrics: null,
    diagnostics: diagnostics,
    failure: 'No candidate passed the quality gate within budget; not proof of infeasibility',
  );
}

// ---------------------------------------------------------------------------
// Isolate entry points. Top-level so `Isolate.run` can send them without
// dragging a closure context along (see crossword_repository.dart for why).
// ---------------------------------------------------------------------------

typedef HuntLexiconSources = ({String acceptedText, String mainText});

HuntLexicon buildHuntLexicon(HuntLexiconSources sources) =>
    HuntLexicon.fromSources(acceptedText: sources.acceptedText, mainText: sources.mainText);

typedef HuntIsolateRequest = ({HuntLexicon lexicon, HuntGenerationRequest request});

HuntGeneration generateHuntInIsolate(HuntIsolateRequest args) =>
    generateHunt(args.lexicon, args.request);

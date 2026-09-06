import 'dart:math';

import 'crossword_models.dart';
import 'crossword_pattern.dart';

/// Everything [generateCrossword] needs, bundled into one object so it can
/// be handed wholesale to [Isolate.run] — this function does real
/// backtracking search and can take several seconds on a big grid, so the
/// caller (`CrosswordRepository`) always runs it on a background isolate
/// rather than the UI isolate.
class CrosswordGenerationRequest {
  final List<CrosswordCandidate> candidates;
  final CrosswordDifficulty difficulty;

  const CrosswordGenerationRequest({required this.candidates, required this.difficulty});
}

/// Builds a real North-American-style crossword: a symmetric black-square
/// pattern (see `crossword_pattern.dart`) filled completely via constraint-
/// solving backtracking, not grown organically word-by-word. Every cell
/// that isn't black ends up with a letter — unlike the old greedy
/// approach, there's no partial/best-effort result. If a pattern can't be
/// fully solved with the given candidates (extremely unlikely once the
/// pool is the full dictionary — verified by benchmarking against ~460k
/// real words in Python before writing this), a few more pattern attempts
/// are tried, then a slightly less dense (easier) target as a fallback
/// tier, before finally giving up and returning `null`.
CrosswordPuzzle? generateCrossword(
  CrosswordGenerationRequest request, {
  // Every attempt in a tier now runs to completion (rather than stopping at
  // the first full solve) so the best-scoring one can be kept — see the
  // tier loop below. Benchmarking in Python showed most of the word-quality
  // gain from trying multiple patterns arrives within the first handful of
  // attempts, so this stays modest to keep worst-case generation time (this
  // runs on a background isolate, but Mega's full ~380k-word pool still
  // makes each attempt non-trivial) from multiplying too far past the old
  // single-attempt cost.
  int patternAttemptsPerTier = 4,
  Duration perAttemptBudget = const Duration(seconds: 2),
}) {
  final difficulty = request.difficulty;

  final entryIdByWord = <String, int>{};
  final seedWords = <String>{};
  final wordsByLength = <int, List<String>>{};
  // Position in the (already frequency-ordered, see allCrosswordWords) input
  // list, keyed by word — a cheap proxy for "how common is this word" that
  // the solver uses to prefer everyday fill over obscure dictionary tail
  // entries. Benchmarking against the real dictionary showed uniform random
  // selection from the full candidate pool picks obscure/technical words the
  // overwhelming majority of the time, since for any given length the tail
  // vastly outnumbers genuinely common words (e.g. 9-letter words: ~63k
  // total vs. ~18 in the top 10k by frequency) — ordering search by rank
  // fixes that without needing to exclude the tail outright, which is still
  // needed for density.
  final rankByWord = <String, int>{};
  // Words whose only available clue material is "Abbreviation/Initialism/
  // Acronym of X" (see CrosswordCandidate.isAcronymOnly) — e.g. an acronym
  // clued as "Application programming interface, for short" spells out
  // exactly what the answer stands for the moment it's read, which is a
  // legitimate crossword convention in moderation but starts to feel
  // "unacceptable" (as reported) once it dominates the fill. Excluded from
  // the pool entirely on the first attempt at each density tier — see
  // acronymOnlyWords below — and only let back in (still deprioritized via
  // acronymPenalty in _solve) if a tier genuinely can't be filled without
  // them. Benchmarked in Python: Mini and Midi both solved 5/5 test runs
  // with acronyms excluded outright and never needed the fallback; only
  // Mega, with much less density slack, occasionally does.
  final acronymOnlyWords = <String>{};

  for (final c in request.candidates) {
    final word = c.headword.toUpperCase();
    if (word.length < difficulty.minWordLength || word.length > difficulty.maxWordLength) continue;
    if (entryIdByWord.containsKey(word)) continue; // dedupe by headword, first wins
    entryIdByWord[word] = c.entryId;
    rankByWord[word] = rankByWord.length;
    if (c.fromStudyPool) seedWords.add(word);
    if (c.isAcronymOnly) acronymOnlyWords.add(word);
    wordsByLength.putIfAbsent(word.length, () => []).add(word);
  }
  if (wordsByLength.isEmpty) return null;

  final letterIndex = _buildLetterIndex(wordsByLength);
  final wordsByLengthNoAcronyms = <int, List<String>>{
    for (final entry in wordsByLength.entries)
      entry.key: [for (final w in entry.value) if (!acronymOnlyWords.contains(w)) w],
  };
  final letterIndexNoAcronyms = _buildLetterIndex(wordsByLengthNoAcronyms);
  final width = difficulty.maxWidth;
  final height = difficulty.maxHeight;

  // If the target density can't be filled, back off to something easier
  // rather than ever leave the grid with unfilled white cells.
  final blackRatioTiers = [difficulty.blackRatio, difficulty.blackRatio + 0.06, 0.30];

  var seedCounter = 0;

  // Tries patternAttemptsPerTier patterns at the given density against the
  // given pool, keeping the best-scoring (mean rank, lower/more-common is
  // better) full solve found rather than returning on the first success —
  // a bad pattern can force a common word into an impossible corner even
  // when a better pattern for the same density wouldn't have.
  CrosswordPuzzle? tryTier(
    double blackRatio,
    Map<int, List<String>> pool,
    Map<int, List<Map<String, Set<String>>>> index,
  ) {
    List<CrosswordSlot>? bestSlots;
    Map<int, String>? bestAssignment;
    double? bestScore;

    for (var attempt = 0; attempt < patternAttemptsPerTier; attempt++) {
      seedCounter++;
      final rng = Random(seedCounter);
      final black = generateBlackPattern(width, height, blackRatio, rng);
      final slots = extractSlots(width, height, black);
      if (slots.isEmpty) continue;

      final assignment = _solve(
        slots: slots,
        wordsByLength: pool,
        letterIndex: index,
        seedWords: seedWords,
        rankByWord: rankByWord,
        acronymOnlyWords: acronymOnlyWords,
        seed: seedCounter,
        timeBudget: perAttemptBudget,
      );
      if (assignment == null || assignment.length != slots.length) continue;

      final score = assignment.values.map((w) => rankByWord[w] ?? rankByWord.length).reduce((a, b) => a + b) /
          assignment.length;
      if (bestScore == null || score < bestScore) {
        bestScore = score;
        bestSlots = slots;
        bestAssignment = assignment;
      }
    }
    if (bestAssignment == null) return null;
    return _buildPuzzle(width, height, bestSlots!, bestAssignment, entryIdByWord, seedWords);
  }

  for (final blackRatio in blackRatioTiers) {
    final withoutAcronyms = tryTier(blackRatio, wordsByLengthNoAcronyms, letterIndexNoAcronyms);
    if (withoutAcronyms != null) return withoutAcronyms;
    final withAcronyms = tryTier(blackRatio, wordsByLength, letterIndex);
    if (withAcronyms != null) return withAcronyms;
  }
  return null;
}

Map<int, List<Map<String, Set<String>>>> _buildLetterIndex(Map<int, List<String>> wordsByLength) {
  final index = <int, List<Map<String, Set<String>>>>{};
  wordsByLength.forEach((length, words) {
    final posIndex = List.generate(length, (_) => <String, Set<String>>{});
    for (final w in words) {
      for (var i = 0; i < w.length; i++) {
        posIndex[i].putIfAbsent(w[i], () => <String>{}).add(w);
      }
    }
    index[length] = posIndex;
  });
  return index;
}

/// crossings[slotIndex] = list of (posInThisSlot, otherSlotIndex, posInOtherSlot)
/// for every cell this slot shares with another slot.
List<List<(int, int, int)>> _buildCrossings(List<CrosswordSlot> slots) {
  final cellSlots = <(int, int), List<(int, int)>>{};
  for (var i = 0; i < slots.length; i++) {
    final s = slots[i];
    for (var p = 0; p < s.length; p++) {
      final cell = s.direction == CrosswordDirection.across ? (s.row, s.col + p) : (s.row + p, s.col);
      cellSlots.putIfAbsent(cell, () => []).add((i, p));
    }
  }
  final crossings = List.generate(slots.length, (_) => <(int, int, int)>[]);
  for (final entries in cellSlots.values) {
    if (entries.length < 2) continue;
    for (final (i, p) in entries) {
      for (final (j, q) in entries) {
        if (i != j) crossings[i].add((p, j, q));
      }
    }
  }
  return crossings;
}

/// Backtracking search with forward checking (MRV variable ordering, domain
/// pruning via set intersection against [letterIndex] on every tentative
/// assignment) for one already-generated pattern's slots. Returns `null` if
/// no full assignment was found within [timeBudget].
Map<int, String>? _solve({
  required List<CrosswordSlot> slots,
  required Map<int, List<String>> wordsByLength,
  required Map<int, List<Map<String, Set<String>>>> letterIndex,
  required Set<String> seedWords,
  required Map<String, int> rankByWord,
  required Set<String> acronymOnlyWords,
  required int seed,
  required Duration timeBudget,
}) {
  final rng = Random(seed);
  final crossings = _buildCrossings(slots);
  final domains = <int, Set<String>>{
    for (var i = 0; i < slots.length; i++) i: {...(wordsByLength[slots[i].length] ?? const [])},
  };
  final assignment = <int, String>{};
  final usedWords = <String>{};
  final stopwatch = Stopwatch()..start();

  // Common words first (seed words always first of all), with a little
  // random jitter so the same slot doesn't deterministically try candidates
  // in the exact same order across regenerations/attempts — jitter of 0.15
  // was benchmarked against the real dictionary as enough to vary results
  // without undoing the commonness bias.
  const rankJitter = 0.15;
  // Validated in Python against the real dictionary: a 3x penalty roughly
  // halves acronym prevalence in a Midi-size solve (30% -> 15%) without
  // hurting solvability, while going much higher (8x, 20x) gave no further
  // improvement — the words satisfying a given crossing pattern are often
  // already exhausted at that point, so the penalty just needs to be enough
  // to try every non-acronym option first, not enough to ban acronyms
  // outright (still needed sometimes for density, especially at Mini's
  // size where short slots dominate structurally).
  const acronymPenalty = 3.0;
  double sortKey(String word) {
    if (seedWords.contains(word)) return -1;
    var rank = (rankByWord[word] ?? rankByWord.length).toDouble();
    if (acronymOnlyWords.contains(word)) rank *= acronymPenalty;
    return rank * (1.0 + (rng.nextDouble() * 2 - 1) * rankJitter);
  }

  List<String> orderCandidates(int slotIndex) {
    return domains[slotIndex]!.toList()..sort((a, b) => sortKey(a).compareTo(sortKey(b)));
  }

  // Tries to place `word` in `slotIndex` against whatever's already
  // assigned, narrowing crossing slots' domains via forward checking.
  // Returns the domains that were narrowed (so the caller can restore them
  // on backtrack) — empty means the placement failed outright.
  ({bool ok, Map<int, Set<String>> saved}) tryAssign(int slotIndex, String word) {
    final saved = <int, Set<String>>{};
    for (final (pos, otherSlot, otherPos) in crossings[slotIndex]) {
      if (assignment.containsKey(otherSlot)) {
        if (assignment[otherSlot]![otherPos] != word[pos]) {
          saved.forEach((k, v) => domains[k] = v);
          return (ok: false, saved: const {});
        }
      } else {
        final otherLength = slots[otherSlot].length;
        final letterSet = letterIndex[otherLength]?[otherPos][word[pos]] ?? const {};
        final filtered = domains[otherSlot]!.intersection(letterSet);
        if (filtered.isEmpty) {
          saved.forEach((k, v) => domains[k] = v);
          return (ok: false, saved: const {});
        }
        saved[otherSlot] = domains[otherSlot]!;
        domains[otherSlot] = filtered;
      }
    }
    return (ok: true, saved: saved);
  }

  bool backtrack() {
    if (assignment.length == slots.length) return true;
    if (stopwatch.elapsed > timeBudget) return false;

    final unassigned = [for (var i = 0; i < slots.length; i++) if (!assignment.containsKey(i)) i]
      ..sort((a, b) => domains[a]!.length.compareTo(domains[b]!.length));
    final slot = unassigned.first;
    if (domains[slot]!.isEmpty) return false;

    for (final word in orderCandidates(slot)) {
      if (usedWords.contains(word)) continue;
      final result = tryAssign(slot, word);
      if (!result.ok) continue;

      assignment[slot] = word;
      usedWords.add(word);
      if (backtrack()) return true;
      assignment.remove(slot);
      usedWords.remove(word);
      result.saved.forEach((k, v) => domains[k] = v);
      if (stopwatch.elapsed > timeBudget) return false;
    }
    return false;
  }

  // Study-pool words are only "tried first" within whatever slot MRV
  // happens to pick — that's not a real guarantee of inclusion, since
  // general search might resolve the whole grid without ever touching a
  // slot the seed word would fit. Locking each one into a matching-length
  // slot *before* general search starts (when doing so doesn't immediately
  // break forward-checking) makes inclusion far more reliable.
  for (final seedWord in seedWords) {
    if (usedWords.contains(seedWord)) continue;
    for (var i = 0; i < slots.length; i++) {
      if (assignment.containsKey(i) || slots[i].length != seedWord.length) continue;
      final result = tryAssign(i, seedWord);
      if (result.ok) {
        assignment[i] = seedWord;
        usedWords.add(seedWord);
        break;
      }
    }
  }

  return backtrack() ? assignment : null;
}

CrosswordPuzzle _buildPuzzle(
  int width,
  int height,
  List<CrosswordSlot> slots,
  Map<int, String> assignment,
  Map<String, int> entryIdByWord,
  Set<String> seedWords,
) {
  final grid = <(int, int), String>{};
  for (var i = 0; i < slots.length; i++) {
    final slot = slots[i];
    final word = assignment[i]!;
    for (var p = 0; p < word.length; p++) {
      final cell = slot.direction == CrosswordDirection.across ? (slot.row, slot.col + p) : (slot.row + p, slot.col);
      grid[cell] = word[p];
    }
  }

  final numberAt = <(int, int), int>{};
  var nextNumber = 1;
  for (var r = 0; r < height; r++) {
    for (var c = 0; c < width; c++) {
      if (!grid.containsKey((r, c))) continue;
      final startsAcross = !grid.containsKey((r, c - 1)) && grid.containsKey((r, c + 1));
      final startsDown = !grid.containsKey((r - 1, c)) && grid.containsKey((r + 1, c));
      if (startsAcross || startsDown) {
        numberAt[(r, c)] = nextNumber++;
      }
    }
  }

  final words = [
    for (var i = 0; i < slots.length; i++)
      CrosswordWordPlacement(
        number: numberAt[(slots[i].row, slots[i].col)]!,
        direction: slots[i].direction,
        row: slots[i].row,
        col: slots[i].col,
        answer: assignment[i]!,
        entryId: entryIdByWord[assignment[i]!]!,
        clue: '', // filled in by CrosswordRepository once generation succeeds
        fromStudyPool: seedWords.contains(assignment[i]!),
      ),
  ];

  return CrosswordPuzzle(width: width, height: height, words: words);
}

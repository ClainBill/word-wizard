import 'dart:math';

import 'crossword_models.dart';
import 'skeleton.dart';

/// Themes and anchors — PORTING_SPEC.md §7.
///
/// An *anchor* is an entry the puzzle is required to contain: the user's
/// spaced-repetition words first, then whatever the day's theme calls for.
/// Anchors are pre-assigned before the solver runs and protected from the
/// refinement pass.

/// Day-of-week category mapping (§7.1). [DateTime.weekday] is 1=Monday.
String themeCategoryFor(int weekday) => switch (weekday) {
      DateTime.tuesday || DateTime.saturday => 'pop_culture',
      DateTime.wednesday => 'general_knowledge',
      DateTime.sunday => 'distinctive',
      _ => 'random', // Monday, Thursday, Friday
    };

/// Which asset tags satisfy which category. `general_knowledge` is the
/// brief's history/politics/geography/science bundle.
const Map<String, List<String>> categoryTags = {
  'pop_culture': ['pop_culture', 'sport'],
  'general_knowledge': ['history', 'politics', 'geography', 'science'],
};

/// Sunday's "distinctive" mechanism: a word hidden inside a longer answer
/// (§7.3). Rebus and letter-addition/subtraction mechanisms are designed in
/// the spec but not implemented anywhere, here included.
const Map<String, List<String>> hiddenCategories = {
  'colors': ['RED', 'BLUE', 'GREEN', 'BLACK', 'WHITE', 'GOLD', 'ROSE', 'JADE', 'TAN', 'GRAY'],
  'animals': ['CAT', 'DOG', 'BAT', 'OWL', 'APE', 'RAT', 'COW', 'HEN', 'FOX', 'BEAR', 'LION'],
  'numbers': ['ONE', 'TWO', 'TEN', 'SIX', 'NINE', 'FOUR', 'FIVE', 'EIGHT'],
  'body_parts': ['ARM', 'EAR', 'EYE', 'HIP', 'RIB', 'SHIN', 'CHIN', 'LIP', 'HEEL'],
  'gems': ['OPAL', 'RUBY', 'JADE', 'PEARL', 'ONYX', 'TOPAZ', 'AMBER'],
};

class CrosswordTheme {
  final String name;
  final String kind;
  final List<CrosswordEntry> anchors;

  const CrosswordTheme({required this.name, required this.kind, required this.anchors});
}

/// Builds the Sunday hidden-word theme (§7.3): pick a category, then find
/// entries containing one of its words as a contiguous substring (and not
/// being that word themselves).
CrosswordTheme? buildSundayTheme(
  List<CrosswordEntry> entries,
  int maxAnchors,
  Random rng, {
  int maxPerWord = 8,
}) {
  final categories = hiddenCategories.keys.toList()..shuffle(rng);
  for (final category in categories) {
    final matchesByWord = <String, List<CrosswordEntry>>{};
    for (final hidden in hiddenCategories[category]!) {
      final matches = [
        for (final entry in entries)
          if (entry.length >= 6 &&
              entry.text != hidden &&
              entry.clues.isNotEmpty &&
              entry.text.contains(hidden))
            entry,
      ]..sort((a, b) => b.score.compareTo(a.score));
      if (matches.isNotEmpty) {
        matchesByWord[hidden] = matches.take(maxPerWord).toList();
      }
    }
    // Need real variety, not one lucky match.
    if (matchesByWord.length < min(3, maxAnchors)) continue;

    final usable = matchesByWord.keys.toList()..shuffle(rng);
    final anchors = <CrosswordEntry>[];
    for (final word in usable.take(maxAnchors)) {
      final options = matchesByWord[word]!;
      anchors.add(options[rng.nextInt(options.length)]);
    }
    return CrosswordTheme(name: category, kind: 'hidden_word', anchors: anchors);
  }
  return null;
}

/// Picks the day's theme and a pool of candidate theme anchors (§7.1-§7.2).
///
/// SRS words are deliberately *not* merged in here: which of them can
/// actually be used depends on the grid, so [anchorsForSkeleton] decides that
/// once a skeleton exists.
CrosswordTheme selectTheme({
  required List<CrosswordEntry> entries,
  required int weekday,
  required int maxAnchors,
  required int gridSize,
  required Set<String> blockedAnswers,
  required Random rng,
}) {
  final category = themeCategoryFor(weekday);

  if (category == 'distinctive') {
    final theme = buildSundayTheme(entries, maxAnchors, rng);
    if (theme != null) {
      return CrosswordTheme(
        name: theme.name,
        kind: theme.kind,
        anchors: [
          for (final entry in theme.anchors)
            if (entry.length <= gridSize && !blockedAnswers.contains(entry.text)) entry,
        ],
      );
    }
    // No category had enough hidden-word variety; fall through to a plain
    // topical theme rather than shipping Sunday with no theme at all.
  }

  final tags = categoryTags[category];
  final pool = [
    for (final entry in entries)
      if (entry.length >= 4 &&
          entry.length <= gridSize &&
          !blockedAnswers.contains(entry.text) &&
          // §7.2: an anchor is drawn from the whole word list rather than the
          // fill pool, so unlike ordinary fill it can arrive unclued — and
          // then falls through to a stub, in the puzzle's most prominent
          // slot. The SRS word is the deliberate exception (the app resolves
          // a clue for it from its own dictionary); a theme pick is not.
          entry.clues.isNotEmpty &&
          (tags == null || entry.tags.any(tags.contains)))
        entry,
  ]..sort((a, b) => b.score.compareTo(a.score));

  // Sample from the strongest slice rather than always taking the very top:
  // the top of a score ordering is "the", "about", "there" — true to the
  // formula and useless as a puzzle's centrepiece. Several times as many
  // candidates as anchors, so [anchorsForSkeleton] has a choice of lengths.
  final window = pool.take(max(maxAnchors * 60, 300)).toList()..shuffle(rng);

  return CrosswordTheme(
    name: category,
    kind: 'category',
    anchors: window.take(maxAnchors * 4).toList(),
  );
}

/// Chooses which anchors to attempt against one specific skeleton, in
/// priority order.
///
/// The spec fixes its anchors before any grid exists and then hopes a slot of
/// the right length turns up (§7.2) — its own §A.2 marks "anchors should
/// influence grid generation" as requirement 4, a GAP. Left that way, a 9x9
/// skeleton with no five-letter slot silently drops the user's study word,
/// and "how many of today's words came from your study list" is the feature
/// this game exists to serve.
///
/// Filtering candidates by the lengths a grid actually contains costs
/// nothing — the orchestrator generates several skeletons anyway — and turns
/// "your word didn't fit" into "a different study word was used". SRS words
/// keep absolute priority; theme words fill whatever is left over.
List<CrosswordEntry> anchorsForSkeleton({
  required List<CrosswordEntry> srsAnchors,
  required List<CrosswordEntry> themeAnchors,
  required int maxAnchors,
  required List<CrosswordSlot> slots,
}) {
  final available = {for (final slot in slots) slot.length};
  final chosen = <CrosswordEntry>[];
  final taken = <String>{};

  for (final source in [srsAnchors, themeAnchors]) {
    for (final entry in source) {
      if (chosen.length >= maxAnchors) break;
      if (!available.contains(entry.length)) continue;
      if (!taken.add(entry.text)) continue;
      chosen.add(entry);
    }
  }
  return chosen;
}

/// Fits anchors into an already-generated skeleton, degrading gracefully —
/// the brief's "if they cannot reasonably be incorporated, use fewer or
/// none".
///
/// [anchors] must arrive in **priority order**, and degradation drops from
/// the end. The spec sorts by score here and drops the lowest-scoring anchor,
/// which quietly contradicts its own §7.2 rule that "caller-supplied SRS
/// words come first (highest priority)": a study word is whatever word the
/// user happens to be learning, so its list score is often lower than a
/// theme word's, and score-ordered degradation would drop the one anchor the
/// product exists to place. [selectAnchors] emits SRS words first.
///
/// [rng], when given, shuffles which slot of the right length an anchor lands
/// in. Without it the first matching slot always wins, and *that* is what
/// decides whether the grid is fillable: pre-assigning OPAQUE fixes a Q in
/// the middle of two crossing entries, and if the crossings can't take it the
/// solver dead-ends in about 3ms. Deterministic placement means all twelve
/// orchestration retries re-place the anchor in the same square and re-hit the
/// same dead end — measured as a 9x9 that failed every attempt in 360ms
/// total. Shuffling turns those retries into twelve genuinely different
/// placements.
///
/// A stricter approach, reserving anchor cells *before* generating the
/// skeleton via `generateSkeletonCapped`'s `reservedWhite`, is better still
/// and is §A.2's requirement 4 — a known gap here, as in the reference
/// implementation.
(Map<int, String>, List<CrosswordEntry>) fitAnchors(
  List<CrosswordEntry> anchors,
  List<CrosswordSlot> slots, {
  Random? rng,
}) {
  var remaining = [...anchors];
  final order = [...slots];
  if (rng != null) order.shuffle(rng);

  while (remaining.isNotEmpty) {
    // Longest first: long entries have the fewest slots that can hold them.
    final byLength = [...remaining]..sort((a, b) => b.length.compareTo(a.length));
    final preAssigned = <int, String>{};
    final usedSlots = <int>{};
    var allPlaced = true;

    // Letters already committed by a placed anchor. Two anchors can share a
    // cell — an across and a down slot that cross — and a slot of the right
    // length is not automatically a slot this anchor *fits*. The spec's
    // fitAnchors matches on length alone, which is fine only as long as no
    // two anchors ever cross; at Mega's three anchors on a 94-slot grid they
    // do, and because pre-assigned words bypass the solver's forward check
    // entirely the conflict survives all the way into the finished grid as a
    // cell whose across and down answers disagree — §11's invariant 4,
    // violated. Checking here is the cheapest place to catch it.
    final letters = <(int, int), String>{};

    for (final anchor in byLength) {
      CrosswordSlot? target;
      for (final slot in order) {
        if (usedSlots.contains(slot.slotId)) continue;
        if (slot.length != anchor.length) continue;
        final cells = slot.cells();
        var fits = true;
        for (var i = 0; i < cells.length; i++) {
          final existing = letters[cells[i]];
          if (existing != null && existing != anchor.text[i]) {
            fits = false;
            break;
          }
        }
        if (!fits) continue;
        target = slot;
        break;
      }
      if (target == null) {
        allPlaced = false;
        break;
      }
      usedSlots.add(target.slotId);
      preAssigned[target.slotId] = anchor.text;
      final cells = target.cells();
      for (var i = 0; i < cells.length; i++) {
        letters[cells[i]] = anchor.text[i];
      }
    }

    if (allPlaced) return (preAssigned, remaining);

    // Drop the lowest-priority anchor and retry.
    remaining = remaining.sublist(0, remaining.length - 1);
  }

  return (const {}, const []);
}

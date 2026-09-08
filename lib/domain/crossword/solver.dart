import 'dart:collection';
import 'dart:math';

import 'crossword_models.dart';
import 'skeleton.dart';
import 'word_list.dart';

/// The fill solver — PORTING_SPEC.md §6.
///
/// A word-level CSP: one variable per **slot**, domain = candidate words.
/// Modelling individual letters as variables does not scale (a published
/// benchmark needed 235s to build the model and 730s to solve an 11x11, in
/// 32GB+ of RAM) — §10.3.

/// Skip propagation *from* slots with domains bigger than this (§6.4,
/// *measured*). A barely-constrained slot's letter set is close to "anything
/// goes", so scanning it costs more than it prunes. Removing the cap made
/// 17x17 ~85ms/node; setting it to 50 was worse than 150 for 9x9.
const int propagateDomainCap = 150;

/// Without jitter the search is deterministic, so retrying a rejected puzzle
/// with a new skeleton converges on the identical fill and never explores an
/// alternative (§6.5, *measured*).
const double defaultScoreJitter = 2.0;

const int defaultMaxSteps = 400000;

class CrosswordSolver {
  final List<CrosswordSlot> slots;
  final CrosswordPatternIndex index;
  final Random rng;
  final double scoreJitter;
  final int maxSteps;
  final Duration timeBudget;

  final Map<int, String> assignment = {};
  final Set<String> used = {};
  final Map<int, List<CrosswordEntry>> domains = {};

  final Stopwatch _clock = Stopwatch();
  int _steps = 0;

  CrosswordSolver({
    required this.slots,
    required this.index,
    required this.rng,
    required Map<int, String> preAssigned,
    /// Answers from the last 10 puzzles. §A.2 requirement 10 asks that they
    /// never come back; the reference implementation routes them to anchor
    /// selection and the puzzle score but never to the solver, so ordinary
    /// fill repeats freely. Seeding `used` with them is the one-line fix
    /// §A.4 calls for.
    Set<String> recentUsage = const {},
    this.scoreJitter = defaultScoreJitter,
    this.maxSteps = defaultMaxSteps,
    this.timeBudget = const Duration(seconds: 8),
  }) {
    assignment.addAll(preAssigned);
    used.addAll(preAssigned.values);
    used.addAll(recentUsage);
    for (final slot in slots) {
      if (assignment.containsKey(slot.slotId)) continue;
      domains[slot.slotId] = index.candidates(_pattern(slot), used);
    }
  }

  late final Map<int, CrosswordSlot> _slotById = {for (final s in slots) s.slotId: s};

  /// A string of length `slot.length` whose character `i` is the crossing
  /// letter if that crossing slot is assigned, else '.'.
  String _pattern(CrosswordSlot slot) {
    final chars = List<int>.filled(slot.length, 0x2E); // '.'
    slot.crossings.forEach((i, crossing) {
      final word = assignment[crossing.$1];
      if (word != null) chars[i] = word.codeUnitAt(crossing.$2);
    });
    return String.fromCharCodes(chars);
  }

  bool get _outOfTime => _clock.elapsed > timeBudget;

  /// Returns a complete assignment, or null if none was found in budget.
  Map<int, String>? solve() {
    _clock.start();
    return _run();
  }

  /// AC-3 style cascade (§6.4). Direct forward-checking only updates slots
  /// that cross the assigned one; narrowing a domain also shrinks the set of
  /// letters it can contribute at *its* crossings, which can narrow slots two
  /// hops away.
  ///
  /// `saved` records each touched slot's domain from before the call, for the
  /// caller's undo trail.
  (bool, Map<int, List<CrosswordEntry>>) _propagate(List<int> seedSlotIds) {
    final saved = <int, List<CrosswordEntry>>{};
    // A real FIFO: this is the second-hottest loop in the generator (§12) and
    // removing from the front of a List is O(n) in Dart.
    final queue = Queue<int>.of(seedSlotIds);
    final queued = <int>{...seedSlotIds};

    while (queue.isNotEmpty) {
      final sid = queue.removeFirst();
      queued.remove(sid);
      final domain = domains[sid];
      if (domain == null) continue; // already assigned
      final slot = _slotById[sid]!;
      if (domain.length > propagateDomainCap || slot.crossings.isEmpty) continue;

      for (final crossing in slot.crossings.entries) {
        final idx = crossing.key;
        final (otherId, otherIdx) = crossing.value;
        final otherDomain = domains[otherId];
        if (otherDomain == null) continue;

        // A 26-wide flag array rather than a Set: the alphabet is fixed and
        // this runs once per crossing per propagation step.
        final allowed = List<bool>.filled(26, false);
        for (final entry in domain) {
          allowed[entry.text.codeUnitAt(idx) - 65] = true;
        }
        final filtered = [
          for (final entry in otherDomain)
            if (allowed[entry.text.codeUnitAt(otherIdx) - 65]) entry,
        ];
        if (filtered.length != otherDomain.length) {
          // FIRST value only — a slot touched by both the one-hop check and
          // this cascade must revert to its pre-assignment state, not the
          // intermediate one.
          saved.putIfAbsent(otherId, () => otherDomain);
          domains[otherId] = filtered;
          if (filtered.isEmpty) return (false, saved);
          if (queued.add(otherId)) queue.add(otherId);
        }
      }
    }
    return (true, saved);
  }

  Map<int, String>? _run() {
    _steps++;
    if (_steps > maxSteps || _outOfTime) return null;
    if (domains.isEmpty) return Map.of(assignment); // every slot assigned

    // --- variable ordering: MRV, ties broken by degree ---
    var bestId = -1;
    var bestSize = 1 << 30;
    var bestDegree = -1;
    domains.forEach((sid, domain) {
      final degree = _slotById[sid]!.crossings.length;
      if (domain.length < bestSize || (domain.length == bestSize && degree > bestDegree)) {
        bestId = sid;
        bestSize = domain.length;
        bestDegree = degree;
      }
    });

    final bestSlot = _slotById[bestId]!;

    // The authoritative candidate list for this decision, recomputed against
    // live `used`. Cached `domains` entries may be stale — a cached list can
    // contain a word some non-crossing slot has since consumed — and that is
    // fine and intentional: `domains` is used *only* for the cheap MRV
    // comparison above. Do not "fix" the staleness with global invalidation;
    // it costs more than it saves (§6.5).
    final fresh = index.candidates(_pattern(bestSlot), used);
    if (fresh.isEmpty) return null;

    final ordered = _sortedByScore(fresh);

    final crossers = <int>[
      for (final crossing in bestSlot.crossings.values)
        if (domains.containsKey(crossing.$1)) crossing.$1,
    ];

    for (final entry in ordered) {
      assignment[bestId] = entry.text;
      used.add(entry.text);
      domains.remove(bestId);

      final saved = <int, List<CrosswordEntry>>{};
      var deadEnd = false;

      // One-hop forward check, exact: recomputed from the index.
      for (final otherId in crossers) {
        saved[otherId] = domains[otherId]!;
        final next = index.candidates(_pattern(_slotById[otherId]!), used);
        domains[otherId] = next;
        if (next.isEmpty) {
          deadEnd = true;
          break;
        }
      }

      if (!deadEnd) {
        final (ok, propSaved) = _propagate(crossers);
        // Keep the EARLIEST saved value.
        propSaved.forEach((k, v) => saved.putIfAbsent(k, () => v));
        if (!ok) deadEnd = true;
      }

      if (!deadEnd) {
        final result = _run();
        if (result != null) return result;
      }

      // ---- undo, exactly ----
      saved.forEach((otherId, oldDomain) => domains[otherId] = oldDomain);
      assignment.remove(bestId);
      used.remove(entry.text);
      // `fresh` — the list computed before any candidate was tried — not a
      // recompute. And it must be left in place when this loop falls through
      // and returns null: the slot is unassigned again and ancestors will
      // reconsider it. Deleting it here was a real bug, whose symptom was
      // that some slots never got filled on deeper branches.
      domains[bestId] = fresh;

      if (_outOfTime) return null;
    }

    return null;
  }

  List<CrosswordEntry> _sortedByScore(List<CrosswordEntry> entries) {
    if (scoreJitter <= 0) {
      return [...entries]..sort((a, b) => b.score.compareTo(a.score));
    }
    // Keys are precomputed rather than jittered inside the comparator: a
    // comparator that returns a different answer each call is not a valid
    // ordering and Dart's sort is free to misbehave on one.
    final keyed = [
      for (final entry in entries)
        (entry, entry.score + (rng.nextDouble() * 2 - 1) * scoreJitter),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final k in keyed) k.$1];
  }
}

/// Local refinement (§6.6): after a complete fill, try to upgrade weak
/// entries without re-searching.
///
/// [protectedSlots] **must** contain the anchor slot ids, or this pass will
/// happily replace a required SRS or theme entry with a higher-scoring word.
void refineFill(
  Map<int, String> assignment,
  List<CrosswordSlot> slots,
  CrosswordPatternIndex index, {
  Set<int> protectedSlots = const {},
  int passes = 2,
}) {
  final slotById = {for (final s in slots) s.slotId: s};

  for (var pass = 0; pass < passes; pass++) {
    var improved = false;

    final order = [
      for (final sid in assignment.keys)
        if (!protectedSlots.contains(sid)) sid,
    ]..sort((a, b) {
        final sa = index.byText[assignment[a]]?.score ?? 0;
        final sb = index.byText[assignment[b]]?.score ?? 0;
        return sa.compareTo(sb); // weakest first
      });

    for (final sid in order) {
      final slot = slotById[sid]!;
      final current = assignment[sid]!;
      final currentScore = index.byText[current]?.score ?? 0;

      final others = <String>{
        for (final e in assignment.entries)
          if (e.key != sid) e.value,
      };
      final chars = List<int>.filled(slot.length, 0x2E);
      slot.crossings.forEach((i, crossing) {
        final word = assignment[crossing.$1];
        if (word != null && crossing.$1 != sid) chars[i] = word.codeUnitAt(crossing.$2);
      });

      final options = index.candidates(String.fromCharCodes(chars), others);
      if (options.isEmpty) continue;
      var best = options.first;
      for (final option in options) {
        if (option.score > best.score) best = option;
      }
      if (best.score > currentScore + 0.5) {
        assignment[sid] = best.text;
        improved = true;
      }
    }

    if (!improved) break;
  }
}

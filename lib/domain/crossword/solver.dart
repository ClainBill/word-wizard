import 'dart:math';
import 'dart:typed_data';

import 'crossword_models.dart';
import 'skeleton.dart';
import 'word_list.dart';

/// Word-level weighted-CSP solver — PORTING_SPEC.md §6.
///
/// One variable per **slot**, not per letter: the letter-level formulation
/// does not scale to 17x17 (§10.3). The pieces that matter:
///
/// - **Domains are integer bitmasks** over the words of one length, ordered
///   by score (§5.2). Intersection is `&`, size is a popcount, excluding a
///   word is clearing a bit, and because bit order is score order, value
///   ordering costs nothing — the old set-based solver sorted a candidate
///   list at every node.
/// - **MRV** picks the next slot (fewest remaining candidates), ties broken
///   by degree — the slot that constrains the most neighbours.
/// - **Full arc consistency at every node.** Letter support is ~26 bitwise
///   operations regardless of domain size, so the old
///   `PROPAGATE_DOMAIN_CAP` — which switched propagation off for exactly the
///   large domains where pruning is most valuable — is gone. Porting it back
///   would be a mistake.
/// - **No `used` set.** All-different is enforced by construction: placing a
///   word clears its bit from every unassigned same-length domain, and only
///   same-length slots could hold it.
///
/// Domains are exact, not a heuristic aid: they are forward-checked,
/// propagated and kept all-different, so a domain *is* the candidate set and
/// MRV compares real numbers.

/// How many candidates to materialize for one decision at a time.
///
/// The domain is already in score order, so this is a **lazy slice, not a
/// cap**: if every word in the first chunk fails, the next is taken and the
/// search stays complete. It exists because a barely-constrained slot can
/// have thousands of candidates while the search almost never needs past the
/// first few dozen.
const int candidateChunk = 256;

/// Node budget for one solve (§6.5).
const int maxSolverSteps = 400000;

/// Perturbs each candidate's score by up to ±this before ordering within a
/// chunk (§6.5, *measured*).
///
/// Without it the search is deterministic, so retrying a rejected puzzle with
/// a new skeleton converges on the identical fill and never explores an
/// alternative. Because bit order is score order, the chunk boundary is a
/// score boundary — so jitter reorders within a chunk, which is all it was
/// ever doing in practice.
const double defaultScoreJitter = 2.0;

/// What one domain narrowing did — see [CrosswordSolver._narrow].
enum _Narrowing { unchanged, narrowed, emptied }

class CrosswordSolver {
  final List<CrosswordSlot> slots;
  final Map<int, CrosswordSlot> _byId;
  final CrosswordPatternIndex index;
  final Random rng;
  final double scoreJitter;
  final int maxSteps;
  final Stopwatch _clock = Stopwatch();
  final Duration timeBudget;

  final Map<int, String> _assignment = {};
  final Map<int, Uint32List> _domains = {};
  final Map<int, int> _lengthOf = {};

  /// Reused per-length zero buffers for propagation's support masks, so a
  /// full arc-consistency pass doesn't allocate a mask per arc. Each is
  /// filled and consumed before the next use, never held across arcs.
  final Map<int, Uint32List> _scratch = {};

  /// Whether the caller's pinned words are mutually consistent (§6.1). They
  /// are never revisited by the search, so if two of them disagree at a
  /// crossing the contradiction would survive into the "solution" — the
  /// editorial pass pins whatever a model asks for, and a model duly pinned
  /// JUST and LIKE across the same cell.
  bool _preAssignedConsistent = true;

  int steps = 0;

  CrosswordSolver({
    required this.slots,
    required this.index,
    required this.rng,
    required Map<int, String> preAssigned,
    required Set<String> blockedAnswers,
    required this.timeBudget,
    this.scoreJitter = defaultScoreJitter,
    this.maxSteps = maxSolverSteps,
  }) : _byId = {for (final s in slots) s.slotId: s} {
    _assignment.addAll(preAssigned);
    _preAssignedConsistent = _checkPreAssigned();
    if (!_preAssignedConsistent) return;

    for (final slot in slots) {
      if (_assignment.containsKey(slot.slotId)) continue;
      _lengthOf[slot.slotId] = slot.length;
      _domains[slot.slotId] = index.maskFor(_pattern(slot));
    }

    // Pinned and blocked words are excluded by clearing their bit once, here.
    // Nothing in the search ever *sets* a bit that wasn't set at this point —
    // undo only restores saved masks — so they stay out for the whole search
    // without being re-checked anywhere.
    for (final text in preAssigned.values) {
      _clearWord(text, null);
    }
    for (final text in blockedAnswers) {
      _clearWord(text, null);
    }
  }

  bool _checkPreAssigned() {
    for (final entry in _assignment.entries) {
      final slot = _byId[entry.key];
      if (slot == null || entry.value.length != slot.length) return false;
      for (final crossing in slot.crossings.entries) {
        final other = _assignment[crossing.value.$1];
        if (other == null) continue;
        if (other.length <= crossing.value.$2) return false;
        if (entry.value[crossing.key] != other[crossing.value.$2]) return false;
      }
    }
    return true;
  }

  /// The slot's current pattern: a crossing letter where the crossing slot is
  /// assigned, '.' elsewhere.
  String _pattern(CrosswordSlot slot, {int? excluding}) {
    final chars = List<int>.filled(slot.length, 0x2E); // '.'
    for (final crossing in slot.crossings.entries) {
      final otherId = crossing.value.$1;
      if (otherId == excluding) continue;
      final text = _assignment[otherId];
      if (text == null) continue;
      chars[crossing.key] = text.codeUnitAt(crossing.value.$2);
    }
    return String.fromCharCodes(chars);
  }

  /// Removes one word from every unassigned domain that could hold it — the
  /// whole of the all-different constraint (§6.2).
  void _clearWord(String text, Map<int, Uint32List>? saved) {
    final bit = index.bitOf[text];
    if (bit == null) return; // not in the fill pool: no domain can hold it
    final length = text.length;
    final wordIndex = bit >> 5;
    final mask = 1 << (bit & 31);
    for (final id in _domains.keys) {
      if (_lengthOf[id] != length) continue;
      final domain = _domains[id]!;
      if (domain[wordIndex] & mask == 0) continue;
      if (saved != null) saved.putIfAbsent(id, () => Uint32List.fromList(domain));
      _domains[id]![wordIndex] &= ~mask;
    }
  }

  /// Narrows `domains[id]` to its intersection with [src], saving the domain
  /// as it stood *before this candidate was tried* on first touch.
  ///
  /// [src] of null means "no word of that length has that letter there" and
  /// empties the domain, which is a dead end rather than an error.
  ///
  /// The three outcomes are distinct because propagation needs to tell
  /// "unchanged" from "narrowed": re-queueing a slot whose domain did not
  /// move is how an AC-3 pass fails to reach a fixed point.
  _Narrowing _narrow(int id, Uint32List? src, Map<int, Uint32List> saved) {
    final target = _domains[id]!;
    if (src == null) {
      saved.putIfAbsent(id, () => Uint32List.fromList(target));
      target.fillRange(0, target.length, 0);
      return _Narrowing.emptied;
    }
    var changed = false;
    for (var i = 0; i < target.length; i++) {
      if (target[i] & src[i] != target[i]) {
        changed = true;
        break;
      }
    }
    if (!changed) return _Narrowing.unchanged; // domains are never left empty
    saved.putIfAbsent(id, () => Uint32List.fromList(target));
    var empty = true;
    for (var i = 0; i < target.length; i++) {
      empty &= (target[i] &= src[i]) == 0;
    }
    return empty ? _Narrowing.emptied : _Narrowing.narrowed;
  }

  /// AC-3 with bitwise arc consistency (§6.4).
  ///
  /// Narrowing a slot's domain shrinks the set of letters it can contribute
  /// at its crossings, which can narrow a slot two hops away; forward
  /// checking only handles one hop. For each letter the source can still show
  /// at the crossing cell, OR in the words the target has with that letter
  /// there — ~26 bitwise operations regardless of domain size, which is what
  /// makes running this at every node affordable.
  bool _propagate(List<int> seedIds, Map<int, Uint32List> saved) {
    final queue = List<int>.from(seedIds);
    final queued = Set<int>.from(seedIds);
    var head = 0;
    while (head < queue.length) {
      final id = queue[head++];
      queued.remove(id);
      final source = _domains[id];
      if (source == null) continue; // assigned in the meantime
      final slot = _byId[id]!;
      final sourceLength = slot.length;

      for (final crossing in slot.crossings.entries) {
        final otherId = crossing.value.$1;
        final target = _domains[otherId];
        if (target == null || maskIsEmpty(target)) continue;
        final otherLength = _lengthOf[otherId]!;
        final otherIdx = crossing.value.$2;

        final supported = _scratchFor(otherLength);
        final letters = index.lettersAt(sourceLength, crossing.key);
        for (var l = 0; l < letters.length; l++) {
          final letter = letters[l];
          final sourceMask = index.letterMask(sourceLength, crossing.key, letter)!;
          var possible = false;
          for (var i = 0; i < source.length; i++) {
            if (source[i] & sourceMask[i] != 0) {
              possible = true;
              break;
            }
          }
          if (!possible) continue;
          final targetMask = index.letterMask(otherLength, otherIdx, letter);
          if (targetMask == null) continue;
          for (var i = 0; i < supported.length; i++) {
            supported[i] |= targetMask[i];
          }
        }

        // Unchanged domains must not re-enter the queue, or propagation
        // never reaches a fixed point.
        switch (_narrow(otherId, supported, saved)) {
          case _Narrowing.emptied:
            return false;
          case _Narrowing.unchanged:
            break;
          case _Narrowing.narrowed:
            if (queued.add(otherId)) queue.add(otherId);
        }
      }
    }
    return true;
  }

  Uint32List _scratchFor(int length) {
    final buffer = _scratch.putIfAbsent(length, () => index.emptyMask(length));
    buffer.fillRange(0, buffer.length, 0);
    return buffer;
  }

  /// Candidates for one decision, best first, in lazy chunks (§6.5).
  Iterable<CrosswordEntry> _orderedCandidates(int slotId, Uint32List domain) sync* {
    final length = _lengthOf[slotId]!;
    final remaining = Uint32List.fromList(domain);
    while (true) {
      final chunk = index.entriesIn(length, remaining, limit: candidateChunk);
      if (chunk.isEmpty) return;
      if (scoreJitter > 0) {
        final jittered = {
          for (final entry in chunk)
            entry.text: entry.score + (rng.nextDouble() * 2 - 1) * scoreJitter,
        };
        chunk.sort((a, b) => jittered[b.text]!.compareTo(jittered[a.text]!));
      }
      yield* chunk;
      for (final entry in chunk) {
        final bit = index.bitOf[entry.text]!;
        remaining[bit >> 5] &= ~(1 << (bit & 31));
      }
    }
  }

  /// Runs the search. Returns slotId -> answer, or null if nothing was found
  /// inside the step and time budgets.
  Map<int, String>? solve() {
    if (!_preAssignedConsistent) return null;
    _clock.start();
    return _run();
  }

  bool get _outOfTime => _clock.elapsed > timeBudget;

  Map<int, String>? _run() {
    steps++;
    if (steps > maxSteps || _outOfTime) return null;
    if (_domains.isEmpty) return Map.of(_assignment); // every slot assigned

    // Variable ordering: MRV, ties broken by degree.
    var bestId = -1;
    var bestSize = 1 << 30;
    var bestDegree = -1;
    for (final id in _domains.keys) {
      final size = maskPopCount(_domains[id]!);
      final degree = _byId[id]!.crossings.length;
      if (size < bestSize || (size == bestSize && degree > bestDegree)) {
        bestId = id;
        bestSize = size;
        bestDegree = degree;
      }
    }
    if (bestSize == 0) return null;

    final slot = _byId[bestId]!;
    final domain = _domains[bestId]!;

    final crossers = <(int, int, int)>[]; // (otherId, otherIdx, idxInThisSlot)
    for (final crossing in slot.crossings.entries) {
      if (_domains.containsKey(crossing.value.$1)) {
        crossers.add((crossing.value.$1, crossing.value.$2, crossing.key));
      }
    }

    for (final entry in _orderedCandidates(bestId, domain)) {
      _assignment[bestId] = entry.text;
      _domains.remove(bestId);

      final saved = <int, Uint32List>{};
      var deadEnd = false;

      // One-hop forward check: one AND per crossing. The assigned word fixes
      // one letter of the neighbour, and that letter's mask *is* the
      // neighbour's surviving domain.
      for (final (otherId, otherIdx, idx) in crossers) {
        final letterMask = index.letterMask(
          _lengthOf[otherId]!,
          otherIdx,
          entry.text.codeUnitAt(idx) - 65,
        );
        if (_narrow(otherId, letterMask, saved) == _Narrowing.emptied) {
          deadEnd = true;
          break;
        }
      }

      if (!deadEnd) {
        _clearWord(entry.text, saved);
        if (!_propagate([for (final c in crossers) c.$1], saved)) deadEnd = true;
      }

      if (!deadEnd) {
        final result = _run();
        if (result != null) return result;
      }

      // Undo, exactly: every touched domain goes back to the mask it held
      // before this candidate was tried, and the chosen slot goes back to the
      // mask captured at node entry. Leaving `domains[bestId]` set on the way
      // out matters — the slot is unassigned again and ancestors will
      // reconsider it.
      for (final restored in saved.entries) {
        _domains[restored.key] = restored.value;
      }
      _assignment.remove(bestId);
      _domains[bestId] = domain;

      if (_outOfTime) return null;
    }

    return null;
  }
}

/// Local refinement after a complete fill (§6.6) — upgrade weak entries
/// without re-searching.
///
/// [protectedSlots] **must** contain the anchor slot ids, or this pass will
/// happily replace a required SRS or theme entry with a higher-scoring word.
Map<int, String> refineFill(
  Map<int, String> assignment,
  List<CrosswordSlot> slots,
  CrosswordPatternIndex index, {
  int passes = 2,
  Set<int> protectedSlots = const {},
  Set<String> blockedAnswers = const {},
}) {
  final byId = {for (final s in slots) s.slotId: s};
  final fill = Map.of(assignment);

  double scoreOf(String text) => index.byText[text]?.score ?? 0;

  for (var pass = 0; pass < passes; pass++) {
    var improved = false;
    final order = [
      for (final id in fill.keys)
        if (!protectedSlots.contains(id)) id,
    ]..sort((a, b) => scoreOf(fill[a]!).compareTo(scoreOf(fill[b]!)));

    for (final slotId in order) {
      final slot = byId[slotId]!;
      final used = {
        for (final entry in fill.entries)
          if (entry.key != slotId) entry.value,
        ...blockedAnswers,
      };
      final chars = List<int>.filled(slot.length, 0x2E);
      for (final crossing in slot.crossings.entries) {
        final other = fill[crossing.value.$1];
        if (other == null || crossing.value.$1 == slotId) continue;
        chars[crossing.key] = other.codeUnitAt(crossing.value.$2);
      }
      final candidates = index.candidates(String.fromCharCodes(chars), used);
      if (candidates.isEmpty) continue;
      var best = candidates.first;
      for (final candidate in candidates) {
        if (candidate.score > best.score) best = candidate;
      }
      if (best.score > scoreOf(fill[slotId]!) + 0.5) {
        fill[slotId] = best.text;
        improved = true;
      }
    }
    if (!improved) break;
  }
  return fill;
}

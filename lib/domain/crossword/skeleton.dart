import 'dart:math';

import 'crossword_models.dart';

/// Grid skeleton generation, slot extraction and numbering — PORTING_SPEC.md
/// §4. This step is **where puzzle quality and solvability are actually
/// determined**: the solver was never the bottleneck, the grid shapes were
/// (§10.1).

/// One maximal white run: an entry the solver has to fill.
class CrosswordSlot {
  final int slotId;
  final int number;
  final CrosswordDirection direction;
  final int row;
  final int col;
  final int length;

  /// cellIndexInThisSlot -> (otherSlotId, indexInOtherSlot)
  final Map<int, (int, int)> crossings = {};

  CrosswordSlot({
    required this.slotId,
    required this.number,
    required this.direction,
    required this.row,
    required this.col,
    required this.length,
  });

  /// This slot's cells, in order.
  List<(int, int)> cells() => [
        for (var i = 0; i < length; i++)
          direction == CrosswordDirection.across ? (row, col + i) : (row + i, col),
      ];
}

/// Structural rules, American/NYT convention (§4.1):
/// 1. 180° rotational symmetry.
/// 2. Minimum entry length 3 — every maximal white run is 0 or >= 3 long.
/// 3. Full checking: every white cell belongs to both an across and a down
///    entry (follows from 2 + connectivity for these shapes).
/// 4. Connectivity: all white cells form one orthogonally-connected
///    component.

bool _rowRunsOk(List<List<bool>> black, int n, int r) {
  var run = 0;
  for (var c = 0; c < n; c++) {
    if (black[r][c]) {
      if (run > 0 && run < 3) return false;
      run = 0;
    } else {
      run++;
    }
  }
  return run == 0 || run >= 3;
}

bool _colRunsOk(List<List<bool>> black, int n, int c) {
  var run = 0;
  for (var r = 0; r < n; r++) {
    if (black[r][c]) {
      if (run > 0 && run < 3) return false;
      run = 0;
    } else {
      run++;
    }
  }
  return run == 0 || run >= 3;
}

/// Flood-fill from any white cell; every white cell must be reachable.
bool isConnected(List<List<bool>> black, int n) {
  var total = 0;
  (int, int)? start;
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (!black[r][c]) {
        total++;
        start ??= (r, c);
      }
    }
  }
  if (start == null) return false;

  final seen = List.generate(n, (_) => List.filled(n, false));
  final stack = <(int, int)>[start];
  seen[start.$1][start.$2] = true;
  var reached = 0;
  while (stack.isNotEmpty) {
    final (r, c) = stack.removeLast();
    reached++;
    for (final (dr, dc) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
      final nr = r + dr;
      final nc = c + dc;
      if (nr < 0 || nr >= n || nc < 0 || nc >= n) continue;
      if (black[nr][nc] || seen[nr][nc]) continue;
      seen[nr][nc] = true;
      stack.add((nr, nc));
    }
  }
  return reached == total;
}

/// Every maximal white run in the grid, each as an **ordered** list of its
/// cells — order matters, the splitter indexes into it. Rows first, then
/// columns; the ordering isn't semantically important (the caller shuffles)
/// but keeping it makes runs reproducible for a given seed.
List<List<(int, int)>> enumerateRuns(List<List<bool>> black, int n) {
  final out = <List<(int, int)>>[];
  for (var r = 0; r < n; r++) {
    var run = <(int, int)>[];
    for (var c = 0; c < n; c++) {
      if (black[r][c]) {
        if (run.isNotEmpty) {
          out.add(run);
          run = <(int, int)>[];
        }
      } else {
        run.add((r, c));
      }
    }
    if (run.isNotEmpty) out.add(run);
  }
  for (var c = 0; c < n; c++) {
    var run = <(int, int)>[];
    for (var r = 0; r < n; r++) {
      if (black[r][c]) {
        if (run.isNotEmpty) {
          out.add(run);
          run = <(int, int)>[];
        }
      } else {
        run.add((r, c));
      }
    }
    if (run.isNotEmpty) out.add(run);
  }
  return out;
}

/// Generates a black-square pattern (§4.2).
///
/// Two independent controls, and **both are required**. Phase 1 caps entry
/// length by splitting over-long runs; on its own it yields grids that
/// satisfy the cap with *minimal* black squares (85-87% white at 17x17) and
/// those **fail to fill** — 0/8 measured. Phase 2's density top-up is what
/// breaks the grid into semi-independent regions; the same grids topped up
/// to ~72% white filled in ~0.05s.
///
/// [reservedWhite] protects cells an anchor entry must occupy, as flat
/// `r * n + c` indices. Plumbed but unused by the current orchestration,
/// which fits anchors after generation (§7.2) — wiring it up is §A.2's
/// requirement 4, a known gap.
List<List<bool>>? generateSkeletonCapped(
  int n,
  int maxEntryLen,
  double? whiteTarget,
  Random rng, {
  Set<int> reservedWhite = const {},
  int maxAttempts = 800,
}) {
  final maxBlack = whiteTarget == null ? null : (n * n * (1 - whiteTarget)).floor();

  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final black = List.generate(n, (_) => List.filled(n, false));
    var stuck = false;

    // ---- Phase 1: cap entry length by splitting over-long runs ----
    while (true) {
      final tooLong = [
        for (final run in enumerateRuns(black, n))
          if (run.length > maxEntryLen) run,
      ];
      if (tooLong.isEmpty) break;
      // Longest run first, ties broken randomly: shuffle, then a *stable*
      // sort by descending length.
      tooLong.shuffle(rng);
      _stableSortByLengthDesc(tooLong);
      final cells = tooLong.first;

      // Plain random ordering of split positions. Cleverer schemes were
      // tried and lost badly (§10.2): "most balanced split first" dropped
      // 9x9 skeleton success from 26/30 to 0/30. Restarts cost ~2ms, so
      // random ordering plus a high maxAttempts wins.
      final options = [for (var i = 0; i < cells.length; i++) i]..shuffle(rng);
      var placed = false;
      for (final i in options) {
        final (r, c) = cells[i];
        final pr = n - 1 - r;
        final pc = n - 1 - c;
        if (reservedWhite.contains(r * n + c) || reservedWhite.contains(pr * n + pc)) continue;
        if (black[r][c]) continue;
        black[r][c] = true;
        black[pr][pc] = true;
        if (_rowRunsOk(black, n, r) &&
            _colRunsOk(black, n, c) &&
            _rowRunsOk(black, n, pr) &&
            _colRunsOk(black, n, pc)) {
          placed = true;
          break;
        }
        black[r][c] = false;
        black[pr][pc] = false;
      }
      if (!placed) {
        stuck = true;
        break;
      }
    }
    if (stuck) continue;

    // ---- Phase 2: top up black density ----
    if (maxBlack != null) {
      final half = [
        for (var r = 0; r < n; r++)
          for (var c = 0; c < n; c++)
            if (r * n + c <= (n * n - 1) ~/ 2) (r, c),
      ]..shuffle(rng);
      var blackCount = _countBlack(black, n);
      for (final (r, c) in half) {
        if (blackCount >= maxBlack) break;
        final pr = n - 1 - r;
        final pc = n - 1 - c;
        if (black[r][c]) continue;
        if (reservedWhite.contains(r * n + c) || reservedWhite.contains(pr * n + pc)) continue;
        black[r][c] = true;
        black[pr][pc] = true;
        if (_rowRunsOk(black, n, r) &&
            _colRunsOk(black, n, c) &&
            _rowRunsOk(black, n, pr) &&
            _colRunsOk(black, n, pc)) {
          blackCount = _countBlack(black, n);
        } else {
          black[r][c] = false;
          black[pr][pc] = false;
        }
      }
    }

    // ---- Validate ----
    if (!isConnected(black, n)) continue;
    final slots = extractSlots(black, n);
    if (slots.isEmpty) continue;
    var minLen = 1 << 30;
    var maxLen = 0;
    for (final s in slots) {
      if (s.length < minLen) minLen = s.length;
      if (s.length > maxLen) maxLen = s.length;
    }
    if (minLen < 3) continue;
    // Phase 2 can't lengthen a run, but check anyway — cheap, and it is the
    // invariant the whole design rests on.
    if (maxLen > maxEntryLen) continue;
    return black;
  }
  return null;
}

void _stableSortByLengthDesc(List<List<(int, int)>> runs) {
  // Dart's List.sort is not stable, which matters here: the shuffle above is
  // what breaks ties randomly, and an unstable sort would discard it.
  final indexed = [for (var i = 0; i < runs.length; i++) (i, runs[i])];
  indexed.sort((a, b) {
    final byLength = b.$2.length.compareTo(a.$2.length);
    return byLength != 0 ? byLength : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < runs.length; i++) {
    runs[i] = indexed[i].$2;
  }
}

int _countBlack(List<List<bool>> black, int n) {
  var count = 0;
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (black[r][c]) count++;
    }
  }
  return count;
}

/// Standard crossword numbering (§4.4): scan cells in raster order; a white
/// cell takes the next number if it *starts* an across or a down entry, and
/// both directions at one cell share the number.
List<CrosswordSlot> extractSlots(List<List<bool>> black, int n) {
  final slots = <CrosswordSlot>[];
  final numberAt = <int, int>{};
  var nextNumber = 1;
  var slotId = 0;

  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (black[r][c]) continue;
      final startsAcross = (c == 0 || black[r][c - 1]) && (c + 1 < n && !black[r][c + 1]);
      final startsDown = (r == 0 || black[r - 1][c]) && (r + 1 < n && !black[r + 1][c]);
      if (!startsAcross && !startsDown) continue;

      final number = numberAt.putIfAbsent(r * n + c, () => nextNumber++);
      if (startsAcross) {
        var len = 0;
        while (c + len < n && !black[r][c + len]) {
          len++;
        }
        slots.add(CrosswordSlot(
          slotId: slotId++,
          number: number,
          direction: CrosswordDirection.across,
          row: r,
          col: c,
          length: len,
        ));
      }
      if (startsDown) {
        var len = 0;
        while (r + len < n && !black[r + len][c]) {
          len++;
        }
        slots.add(CrosswordSlot(
          slotId: slotId++,
          number: number,
          direction: CrosswordDirection.down,
          row: r,
          col: c,
          length: len,
        ));
      }
    }
  }

  computeCrossings(slots);
  return slots;
}

/// Fills in each slot's `crossings` map: for every cell, the slot running
/// through it in the other direction and the index it occupies there.
void computeCrossings(List<CrosswordSlot> slots) {
  final owner = <(int, int), Map<CrosswordDirection, (CrosswordSlot, int)>>{};
  for (final slot in slots) {
    final cells = slot.cells();
    for (var i = 0; i < cells.length; i++) {
      owner.putIfAbsent(cells[i], () => {})[slot.direction] = (slot, i);
    }
  }
  for (final slot in slots) {
    final cells = slot.cells();
    for (var i = 0; i < cells.length; i++) {
      final other = owner[cells[i]]![oppositeOf(slot.direction)];
      if (other != null) slot.crossings[i] = (other.$1.slotId, other.$2);
    }
  }
}

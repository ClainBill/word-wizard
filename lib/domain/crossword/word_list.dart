import 'crossword_models.dart';

/// Parses the scored word list asset and builds the pattern index the solver
/// searches against — PORTING_SPEC.md §2 and §5.

/// The runtime fill pool floor (§6.3, *measured*). Restricting the index to
/// entries at or above this Zipf frequency is half of the quality fix:
/// because every word in the pool is recognizable, **any valid fill is a
/// publishable fill**. Combined with the grid shapes in `skeleton.dart` it
/// costs nothing in solvability.
///
/// Anchors (§7) are drawn from the *full* list, not the fill pool, and are
/// pre-assigned, so they never need to be in the index.
const double fillMinZipf = 2.5;

/// Higher floors for the shortest entries, over [fillMinZipf].
///
/// The spec's flat 2.5 was measured against ENABLE1 — a Scrabble word list,
/// which is *curated*: membership already means "this is a word". This app's
/// list comes from Wiktionary, which documents every attested token, so at
/// length 3 a flat 2.5 admits 2,637 entries of which the great majority are
/// initialisms and fragments (NCP, RNS, TPC, BHD, LAU, SES). They passed the
/// §9.1 gate too, so Mega grids shipped with four or five of them.
///
/// Raising the floor only at lengths 3-4 is the remedy §2.4 itself
/// prescribes — "short lengths are where obscure fill is both most jarring
/// and most avoidable (thousands of alternatives exist)" — and its warning
/// about frequency floors applies specifically to lengths above 6, where the
/// solver needs every scrap of letter-pattern diversity. 3.5/3.0 leaves 664
/// three-letter and 1,991 four-letter options, far more than the ~55 threes
/// a 17x17 consumes, and the offender count drops to zero.
const Map<int, double> fillMinZipfByLength = {3: 3.5, 4: 3.0};

/// Per-length recognizability floors (§9.1) — a completed grid is rejected
/// and regenerated if any **non-anchor** entry falls below its length's
/// floor. Lengths above 9 have no floor.
///
/// Lives beside the pool floors rather than in the orchestrator because the
/// two describe the same judgement from different ends. Deliberately *not*
/// folded into [inFillPool]: making pool membership imply a passing score
/// would leave the gate unable to fail, and its whole job is to notice when
/// something has gone wrong upstream.
const Map<int, double> qualityFloorByLength = {
  3: 2.5,
  4: 2.2,
  5: 1.8,
  6: 1.4,
  7: 1.0,
  8: 0.7,
  9: 0.5,
};

/// Whether [entry] belongs in the solver's fill pool.
bool inFillPool(CrosswordEntry entry) =>
    entry.freqZipf >= (fillMinZipfByLength[entry.length] ?? fillMinZipf);

/// Parses `assets/crossword/wordlist.tsv`.
///
/// Tab-separated rather than the JSON §2 suggests: same fields, but it is
/// the "packed format" the spec recommends for app size, and it parses with
/// a split per line instead of building a throwaway object graph for 49k
/// entries. One `#`-prefixed header line, then
/// `text, display, entryId, zipf, senses, flags, score, tags`.
List<CrosswordEntry> parseWordList(String contents) {
  final entries = <CrosswordEntry>[];
  for (final line in contents.split('\n')) {
    if (line.isEmpty || line.codeUnitAt(0) == 0x23) continue; // '#'
    final f = line.split('\t');
    if (f.length < 8) continue;
    final flags = int.parse(f[5]);
    final tags = f[7];
    entries.add(CrosswordEntry(
      text: f[0],
      display: f[1],
      entryId: int.parse(f[2]),
      freqZipf: double.parse(f[3]),
      synsetCount: int.parse(f[4]),
      isProper: flags & 1 != 0,
      isPhrase: flags & 2 != 0,
      isAcronym: flags & 4 != 0,
      tags: tags.isEmpty ? const [] : tags.split(','),
      score: double.parse(f[6]),
    ));
  }
  return entries;
}

/// Fast "which words match `C.T`?" lookups (§5).
///
/// A trie/DAWG is *not* needed — set intersection over per-position letter
/// buckets is fast enough and far simpler to port. Letters are stored as
/// codes 0-25 rather than single-character strings, per §12's note that this
/// is one of the two hottest paths in the whole generator.
class CrosswordPatternIndex {
  /// length -> position -> letterCode -> texts
  final Map<int, List<List<Set<String>>>> _byLetter;
  final Map<int, List<String>> _byLength;
  final Map<String, CrosswordEntry> byText;

  CrosswordPatternIndex._(this._byLetter, this._byLength, this.byText);

  factory CrosswordPatternIndex.build(Iterable<CrosswordEntry> entries) {
    final byLetter = <int, List<List<Set<String>>>>{};
    final byLength = <int, List<String>>{};
    final byText = <String, CrosswordEntry>{};

    for (final entry in entries) {
      final text = entry.text;
      // First writer wins, matching the exporter's own dedupe: the list is
      // already one row per grid form, so this only guards a caller that
      // concatenates pools.
      if (byText.containsKey(text)) continue;
      byText[text] = entry;

      final length = text.length;
      byLength.putIfAbsent(length, () => <String>[]).add(text);
      final positions = byLetter.putIfAbsent(
        length,
        () => List.generate(length, (_) => List.generate(26, (_) => <String>{})),
      );
      for (var i = 0; i < length; i++) {
        positions[i][text.codeUnitAt(i) - 65].add(text);
      }
    }
    return CrosswordPatternIndex._(byLetter, byLength, byText);
  }

  /// Every entry matching [pattern] ('.' is a wildcard) that isn't in
  /// [exclude]. Buckets are intersected smallest-first and short-circuit as
  /// soon as the running set empties (§5, §12).
  List<CrosswordEntry> candidates(String pattern, Set<String> exclude) {
    final length = pattern.length;
    final positions = _byLetter[length];
    if (positions == null) return const [];

    // Collect the constrained positions, then walk them cheapest-first so the
    // running set starts as small as possible.
    List<Set<String>>? buckets;
    for (var i = 0; i < length; i++) {
      final code = pattern.codeUnitAt(i);
      if (code == 0x2E) continue; // '.'
      final bucket = positions[i][code - 65];
      if (bucket.isEmpty) return const [];
      (buckets ??= <Set<String>>[]).add(bucket);
    }

    if (buckets == null) {
      // Unconstrained slot — every word of this length.
      final all = _byLength[length];
      if (all == null) return const [];
      return [
        for (final text in all)
          if (!exclude.contains(text)) byText[text]!,
      ];
    }

    buckets.sort((a, b) => a.length.compareTo(b.length));
    Set<String> running = buckets.first;
    for (var i = 1; i < buckets.length; i++) {
      running = running.intersection(buckets[i]);
      if (running.isEmpty) return const [];
    }
    return [
      for (final text in running)
        if (!exclude.contains(text)) byText[text]!,
    ];
  }
}

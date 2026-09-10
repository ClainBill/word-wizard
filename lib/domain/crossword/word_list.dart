import 'dart:typed_data';

import 'crossword_models.dart';

/// Parses the Crosswordler word-list asset and builds the pattern index the
/// solver searches against — PORTING_SPEC.md §2, §5 and §6.3.

/// The runtime fill pool's frequency floor (§6.3, *measured*). "Is this
/// attested at all?"
const double fillMinZipf = 2.5;

/// Minimum familiarity rating to enter the fill pool, by entry length (§6.3).
///
/// Short entries are held to a higher bar because that is where the ratings
/// say the problem actually is — 9.4% of three-letter entries rate 2 against
/// ~2.5% at every other length — and because short entries are where obscure
/// fill is both most jarring and most avoidable. Long entries get the looser
/// bar because that is where the solver has least slack, and a long word is
/// self-evidently a real word anyway.
const Map<int, int> familiarityFloorByLength = {3: 4, 4: 4};
const int defaultFamiliarityFloor = 3;

int familiarityFloor(int length) =>
    familiarityFloorByLength[length] ?? defaultFamiliarityFloor;

/// The Nediger tier that is excluded outright: "entries I'll use only if
/// absolutely necessary". It removes fill that frequency alone waves through
/// — ONI, MES and HET all clear the zipf floor but are tier 25 — without
/// removing everything that merely *looks* odd: OLA, RES and SSE are tier 51,
/// i.e. a working constructor would use them. (Tier 49, "too racy for many
/// mainstream venues", never reaches the asset: it is dropped at build time.)
const int lastResortTier = 25;

/// Per-length recognizability floors (§9.1) — a completed grid is rejected
/// and regenerated if any **non-anchor** entry falls below its length's
/// floor. Lengths above 9 have no floor.
///
/// Deliberately *not* folded into [inFillPool]: making pool membership imply
/// a passing score would leave the gate unable to fail, and its whole job is
/// to notice when something has gone wrong upstream. With the §4 grid shapes
/// and the pool below it now reports zero offenders at all three sizes, so it
/// functions as insurance rather than as the main quality mechanism.
const Map<int, double> qualityFloorByLength = {
  3: 2.5,
  4: 2.2,
  5: 1.8,
  6: 1.4,
  7: 1.0,
  8: 0.7,
  9: 0.5,
};

/// Whether [entry] belongs in the solver's fill pool — §6.3's four bars, plus
/// the crosswordese list.
///
/// Each bar catches what the others miss, which is why all of them are here
/// rather than collapsed into the score:
///
/// - **frequency** asks whether the word is attested at all, and is nearly
///   useless below five characters, where it counts letter sequences in
///   running text rather than words;
/// - **a clue** is what removes placeholder clues entirely — a word we cannot
///   clue is a word we simply never select;
/// - **the constructor's tier** encodes "would a professional use this",
///   which frequency cannot express;
/// - **familiarity** is the only one of the four that asks whether a person
///   knows the word, and it is the one that rejects ERG, PAP, ABA, DES, AIN
///   and NEE — every one of which clears the other three.
///
/// Because every word in the pool is recognizable *and* cluable, **any valid
/// fill is a publishable fill**. Combined with the grid shapes in
/// `skeleton.dart` this costs nothing in solvability. Anchors (§7) are drawn
/// from the *full* list rather than the pool, and are pre-assigned, so they
/// never need to be in the index.
bool inFillPool(CrosswordEntry entry) =>
    entry.freqZipf >= fillMinZipf &&
    entry.clues.isNotEmpty &&
    entry.editorTier != lastResortTier &&
    entry.familiarity >= familiarityFloor(entry.length) &&
    !entry.isCrosswordese;

/// Parses `assets/crossword/wordlist.tsv`.
///
/// Tab-separated rather than the JSON §2 describes: same fields, but it is
/// the "packed format" the spec recommends for app size (8.9 MB against 22.8
/// MB) and it parses with a split per line instead of building a throwaway
/// object graph for 72,000 entries. Comment lines document the layout; see
/// `tool/pipeline/export_crossword_wordlist.py`, which writes it.
List<CrosswordEntry> parseWordList(String contents) {
  final entries = <CrosswordEntry>[];
  for (final line in contents.split('\n')) {
    if (line.isEmpty || line.codeUnitAt(0) == 0x23) continue; // '#'
    final f = line.split('\t');
    if (f.length < 9) continue;
    final flags = int.parse(f[4]);
    final familiarity = f[7];
    final tags = f[8];
    entries.add(CrosswordEntry(
      text: f[0],
      display: f[1],
      freqZipf: double.parse(f[2]),
      synsetCount: int.parse(f[3]),
      isProper: flags & 1 != 0,
      isPhrase: flags & 2 != 0,
      isCrosswordese: flags & 4 != 0,
      tags: tags.isEmpty ? const [] : tags.split(','),
      score: double.parse(f[5]),
      editorTier: int.parse(f[6]),
      // An unrated word is not evidence against the word: the ratings pass
      // covers 71,303 of 72,214 entries, and treating the remainder as a 5
      // is what the reference implementation does.
      familiarity: familiarity.isEmpty ? 5 : int.parse(familiarity),
      clues: [
        for (var i = 9; i < f.length; i++)
          if (f[i].length > 2)
            CrosswordClue(f[i].substring(2), CrosswordClueType.fromCode(f[i][0])),
      ],
    ));
  }
  return entries;
}

/// Per-length, per-position letter buckets as **integer bitmasks** — §5.2,
/// and the single change that makes the solver affordable.
///
/// Entries of one length are ordered by score, descending, and each gets a
/// bit index in that order. A slot's domain is then one bitmask:
/// intersection is `&`, size is a popcount, excluding a word is clearing a
/// bit, and — because bit order *is* score order — iterating set bits from
/// the low end yields candidates best-first with no sort at all. The old
/// set-of-strings form sorted a candidate list, sometimes thousands of
/// entries long, at every single node.
///
/// Dart has no arbitrary-precision integer arithmetic worth using here
/// (`BigInt` allocates on every operation), so a mask is a `Uint32List` and
/// the five operations §5.2 lists are written against it. Nothing in the
/// algorithm depends on the mask being a single value.
class _LengthMasks {
  final int wordCount;

  /// `[position * 26 + letter]` -> bitmask, or null where no word of this
  /// length has that letter in that position.
  final List<Uint32List?> posLetter;

  /// Position -> the letter codes that actually have a bucket. Propagation
  /// iterates these rather than all 26; most positions use far fewer.
  final List<Uint32List> lettersAt;

  final Uint32List full;

  _LengthMasks({
    required this.wordCount,
    required this.posLetter,
    required this.lettersAt,
    required this.full,
  });

  int get maskWords => full.length;
}

/// Number of 32-bit words a mask over [bitCount] bits needs.
int maskWordCount(int bitCount) => (bitCount + 31) >> 5;

/// True if every word of [mask] is zero — i.e. the domain is empty.
bool maskIsEmpty(Uint32List mask) {
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] != 0) return false;
  }
  return true;
}

/// How many words a domain still holds — the MRV comparison (§6.5).
int maskPopCount(Uint32List mask) {
  var total = 0;
  for (var i = 0; i < mask.length; i++) {
    // Standard SWAR popcount; Dart has no intrinsic for it.
    var v = mask[i];
    v -= (v >> 1) & 0x55555555;
    v = (v & 0x33333333) + ((v >> 2) & 0x33333333);
    v = (v + (v >> 4)) & 0x0F0F0F0F;
    total += (v * 0x01010101) >> 24 & 0xFF;
  }
  return total;
}

/// Fast "which words match `C.T`?" lookups (§5).
class CrosswordPatternIndex {
  /// Entries of each length, **score-descending** — bit `i` of a domain over
  /// this length is `entriesByLength[length][i]`.
  final Map<int, List<CrosswordEntry>> entriesByLength;

  /// Grid text -> its bit index within its own length.
  final Map<String, int> bitOf;

  final Map<String, CrosswordEntry> byText;

  final Map<int, _LengthMasks> _masks = {};

  CrosswordPatternIndex._(this.entriesByLength, this.bitOf, this.byText);

  factory CrosswordPatternIndex.build(Iterable<CrosswordEntry> entries) {
    final byText = <String, CrosswordEntry>{};
    final byLength = <int, List<CrosswordEntry>>{};

    for (final entry in entries) {
      // First writer wins, matching the exporter's own dedupe: the asset is
      // already one row per grid form, so this only guards a caller that
      // concatenates pools.
      if (byText.containsKey(entry.text)) continue;
      byText[entry.text] = entry;
      byLength.putIfAbsent(entry.length, () => <CrosswordEntry>[]).add(entry);
    }

    final bitOf = <String, int>{};
    for (final list in byLength.values) {
      list.sort((a, b) => b.score.compareTo(a.score));
      for (var i = 0; i < list.length; i++) {
        bitOf[list[i].text] = i;
      }
    }
    return CrosswordPatternIndex._(byLength, bitOf, byText);
  }

  /// Masks for one length, built on first use.
  ///
  /// A 5x5 puzzle only ever asks about lengths 3-5, so building all fifteen
  /// lengths up front would be waste — and at 17x17 the lengths a given
  /// skeleton uses are a small subset too.
  _LengthMasks _masksFor(int length) {
    final cached = _masks[length];
    if (cached != null) return cached;

    final words = entriesByLength[length] ?? const <CrosswordEntry>[];
    final n = words.length;
    final wordCount = maskWordCount(n);

    final posLetter = List<Uint32List?>.filled(length * 26, null);
    for (var i = 0; i < n; i++) {
      final text = words[i].text;
      final wordIndex = i >> 5;
      final bit = 1 << (i & 31);
      for (var pos = 0; pos < length; pos++) {
        final slot = pos * 26 + (text.codeUnitAt(pos) - 65);
        final bucket = posLetter[slot] ??= Uint32List(wordCount);
        bucket[wordIndex] |= bit;
      }
    }

    final lettersAt = <Uint32List>[];
    for (var pos = 0; pos < length; pos++) {
      final present = <int>[];
      for (var letter = 0; letter < 26; letter++) {
        if (posLetter[pos * 26 + letter] != null) present.add(letter);
      }
      lettersAt.add(Uint32List.fromList(present));
    }

    final full = Uint32List(wordCount);
    for (var i = 0; i < n; i++) {
      full[i >> 5] |= 1 << (i & 31);
    }

    return _masks[length] = _LengthMasks(
      wordCount: n,
      posLetter: posLetter,
      lettersAt: lettersAt,
      full: full,
    );
  }

  /// How many words of [length] the pool holds — the bit width of a domain
  /// over that length.
  int wordCountFor(int length) => _masksFor(length).wordCount;

  /// A fresh, empty (all-zero) mask sized for [length].
  Uint32List emptyMask(int length) => Uint32List(_masksFor(length).maskWords);

  /// The bucket for one letter at one position, or null if no word of this
  /// length has it there. Never mutate the result — it is the index's own
  /// storage.
  Uint32List? letterMask(int length, int position, int letterCode) =>
      _masksFor(length).posLetter[position * 26 + letterCode];

  /// The letter codes that have a bucket at [position] (§6.4: iterate these,
  /// not all 26).
  Uint32List lettersAt(int length, int position) => _masksFor(length).lettersAt[position];

  /// Bitmask of every word matching [pattern] ('.' is a wildcard), as a fresh
  /// mask the caller owns.
  Uint32List maskFor(String pattern) {
    final length = pattern.length;
    final masks = _masksFor(length);
    final result = Uint32List.fromList(masks.full);
    for (var pos = 0; pos < length; pos++) {
      final code = pattern.codeUnitAt(pos);
      if (code == 0x2E) continue; // '.'
      final bucket = masks.posLetter[pos * 26 + (code - 65)];
      if (bucket == null) return Uint32List(masks.maskWords); // no such letter here
      var empty = true;
      for (var i = 0; i < result.length; i++) {
        empty &= (result[i] &= bucket[i]) == 0;
      }
      if (empty) return result;
    }
    return result;
  }

  /// The entries whose bits are set in [mask], **best score first**, stopping
  /// after [limit] (0 = no limit).
  ///
  /// Callers that may need more take another slice rather than paying for the
  /// whole domain up front — see the solver's chunked value ordering.
  List<CrosswordEntry> entriesIn(int length, Uint32List mask, {int limit = 0}) {
    final words = entriesByLength[length] ?? const <CrosswordEntry>[];
    final out = <CrosswordEntry>[];
    for (var w = 0; w < mask.length; w++) {
      var bits = mask[w];
      while (bits != 0) {
        final lowest = bits & -bits;
        // Bit position within this word, from the number of trailing zeros.
        final index = (w << 5) + _trailingZeros(lowest);
        if (index >= words.length) return out; // padding bits, if any
        out.add(words[index]);
        if (limit != 0 && out.length >= limit) return out;
        bits ^= lowest;
      }
    }
    return out;
  }

  /// Every entry matching [pattern] that isn't in [exclude].
  ///
  /// §5.1 keeps a second, set-of-strings representation of the same buckets
  /// for this one caller (the refinement pass and the quality gate). It is
  /// not ported: the same candidate set comes out of [maskFor], and a second
  /// index over 68,742 entries costs tens of megabytes on a phone to save a
  /// few milliseconds on a pass that runs twice per puzzle.
  List<CrosswordEntry> candidates(String pattern, Set<String> exclude) {
    final matches = entriesIn(pattern.length, maskFor(pattern));
    if (exclude.isEmpty) return matches;
    return [
      for (final entry in matches)
        if (!exclude.contains(entry.text)) entry,
    ];
  }
}

/// Trailing-zero count for a value with exactly one bit set.
int _trailingZeros(int lowestBit) {
  var n = 0;
  var v = lowestBit;
  if (v & 0x0000FFFF == 0) {
    n += 16;
    v >>= 16;
  }
  if (v & 0x000000FF == 0) {
    n += 8;
    v >>= 8;
  }
  if (v & 0x0000000F == 0) {
    n += 4;
    v >>= 4;
  }
  if (v & 0x00000003 == 0) {
    n += 2;
    v >>= 2;
  }
  if (v & 0x00000001 == 0) n += 1;
  return n;
}

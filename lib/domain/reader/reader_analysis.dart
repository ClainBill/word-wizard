import 'tokenizer.dart';

/// Words ranked past this are "uncommon" — roughly where the frequency list
/// runs out of everyday vocabulary and into the GRE tier ("scrutiny" and
/// "paradigm" sit just above the line; "candid", "meticulous", "ephemeral"
/// well below it). Ranks are dense over every (headword, pos) row, so the
/// number is larger than a count of distinct words would suggest.
const uncommonRankThreshold = 100000;

/// A word on the page resolved to its dictionary entry.
class ResolvedWord {
  final String headword;

  /// The canonical entry id for [headword] — the same id lists, study cards
  /// and notes key on, so marks line up with what "Add to list" wrote.
  final int entryId;
  final String pos;
  final String? gloss;
  final int? frequencyRank;

  /// When the page's word is itself a headword *and* an inflection of some
  /// other headword ("running" is an adjective, and a form of "run"), the
  /// inflected-from entry lands here. The page prefers it whenever it's the
  /// one that's in a list or being studied: a reader who saved "run" wants
  /// "running" lit up, and the direct entry's card is one tap away either
  /// way.
  final ResolvedWord? lemma;

  const ResolvedWord({
    required this.headword,
    required this.entryId,
    required this.pos,
    this.gloss,
    this.frequencyRank,
    this.lemma,
  });

  bool get isUncommon => frequencyRank == null || frequencyRank! > uncommonRankThreshold;
}

class AnalyzedToken {
  final WordToken token;
  final ResolvedWord? word;

  const AnalyzedToken(this.token, this.word);
}

/// Every word of a document, block by block, with its dictionary
/// resolution — computed once per document, since the dictionary doesn't
/// change. What *does* change (which of those words are in lists or being
/// studied) is layered on separately by [WordMarks].
class ReaderAnalysis {
  final List<List<AnalyzedToken>> blocks;

  const ReaderAnalysis(this.blocks);

  Iterable<AnalyzedToken> get allTokens => blocks.expand((b) => b);

  int get wordCount => blocks.fold(0, (n, b) => n + b.length);

  /// Distinct uncommon words — the same number the legend shows.
  int get uncommonCount =>
      {for (final t in allTokens) if (t.word?.isUncommon ?? false) t.word!.entryId}.length;

  /// Every entry id a token could count as — direct entries and lemmas.
  Set<int> get entryIds => {
        for (final t in allTokens)
          if (t.word != null) ...[t.word!.entryId, if (t.word!.lemma != null) t.word!.lemma!.entryId],
      };
}

/// Which entries are in which lists, and which are being studied — the
/// live half of the page's marks, watched from the user database so a word
/// added to a list from the peek panel lights up on the page immediately.
class WordMarks {
  final Map<int, List<int>> listIdsByEntry;
  final Set<int> studyingEntryIds;

  const WordMarks({this.listIdsByEntry = const {}, this.studyingEntryIds = const {}});

  static const empty = WordMarks();

  bool isMarked(int entryId) =>
      studyingEntryIds.contains(entryId) || (listIdsByEntry[entryId]?.isNotEmpty ?? false);

  /// The entry the page should treat [word] as — see [ResolvedWord.lemma].
  ResolvedWord effective(ResolvedWord word) {
    final lemma = word.lemma;
    if (lemma != null && !isMarked(word.entryId) && isMarked(lemma.entryId)) return lemma;
    return word;
  }

  List<int> listsFor(int entryId) => listIdsByEntry[entryId] ?? const [];

  bool isStudying(int entryId) => studyingEntryIds.contains(entryId);
}

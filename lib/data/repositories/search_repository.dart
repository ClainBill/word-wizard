import '../../domain/models/daily_word.dart';
import '../../domain/models/entry.dart';
import '../dictionary/dictionary_database.dart';
import 'slang_repository.dart';

class SearchRepository {
  final DictionaryDatabase _db;

  /// The person's Slang Stack, folded into every lookup here so a word
  /// they added is found, opened and clued like any other. Null only in
  /// tests that don't need it.
  final SlangRepository? _slang;

  SearchRepository(this._db, {SlangRepository? slang}) : _slang = slang;

  Future<List<EntrySummary>> search(String query) => _db.search(query);

  /// The card for [headword]: the dictionary's, with the person's own
  /// meanings added when they have some for it, or — for a word only the
  /// Slang Stack knows — the slang word's own card. A spelling or form the
  /// person filed under a slang word reaches that word.
  Future<WordEntry?> loadWord(String headword) async {
    final word = await _db.loadWord(headword);
    final slang = _slang;
    if (slang == null) return word;
    if (word != null) {
      final own = await slang.byHeadword(word.headword);
      return own == null ? word : word.withSlang(own);
    }
    final own = await slang.byHeadword(headword) ?? await slang.byForm(headword);
    if (own == null) return null;
    if (own.headword != headword) {
      // Reached by one of its spellings or forms: open the word itself,
      // and say so for a spelling ("fina is a spelling of finna").
      final target = await loadWord(own.headword);
      return own.spellings.contains(headword) ? target?.reachedAs(headword) : target;
    }
    return WordEntry.fromSlang(own);
  }

  /// The featured word for [day] — see `DictionaryDatabase.wordOfTheDay`.
  Future<DailyWord?> wordOfTheDay(DateTime day) => _db.wordOfTheDay(day);

  /// Random words for the landing board — see `DictionaryDatabase.boardWords`.
  Future<List<String>> boardWords({int count = 90}) => _db.boardWords(count: count);

  /// Resolves a single word tapped inside a gloss, example, or etymology
  /// line to its full entry — tries the exact headword first, then falls
  /// back to resolving an inflected surface form (tapping "ran" finds
  /// "run"). Returns null if the word isn't in the dictionary at all.
  Future<WordEntry?> lookupTappedWord(String word) async {
    final lower = word.toLowerCase();
    final direct = await loadWord(lower);
    if (direct != null) return direct;
    final resolved = await _db.resolveForm(lower);
    if (resolved.isEmpty) return null;
    return loadWord(resolved.first.headword);
  }

  /// Wrong-answer options for the study session's definition-match mini
  /// exercise — random glosses from unrelated entries.
  Future<List<String>> randomDistractorGlosses(
    int excludeEntryId, {
    required String excludeGloss,
    int count = 2,
  }) =>
      _db.randomGlosses(excludeEntryId: excludeEntryId, excludeGloss: excludeGloss, count: count);

  /// Blanked example sentences belonging to other words — the wrong answers
  /// in the study session's "which sentence is it?" comprehension game.
  Future<List<String>> randomDistractorExamples(int excludeEntryId, {int count = 2}) =>
      _db.randomBlankedExamples(excludeEntryId: excludeEntryId, count: count);

  /// The same, but chosen to be about the same things as [example] — see
  /// `DictionaryDatabase.similarBlankedExamples`. Topped up from the random
  /// sample when the index has fewer than [count] usable neighbours, so the
  /// game always has its choices.
  Future<List<String>> similarDistractorExamples(
    String example, {
    required int excludeEntryId,
    required String headword,
    int count = 2,
  }) async {
    final similar = await _db.similarBlankedExamples(
      example,
      excludeEntryId: excludeEntryId,
      excludeHeadword: headword,
      count: count,
    );
    if (similar.length >= count) return similar;
    final random = await _db.randomBlankedExamples(
      excludeEntryId: excludeEntryId,
      excludeHeadword: headword,
      count: count - similar.length + 2,
    );
    return [...similar, ...random.where((r) => !similar.contains(r))].take(count).toList();
  }

  /// A common real word ending in the same letters as [headword], for the
  /// study session's phonological "sounds like" recall cue. Null if nothing
  /// common enough shares a suffix.
  Future<String?> similarSoundingWord(int excludeEntryId, String headword) =>
      _db.similarSoundingWord(headword, excludeEntryId: excludeEntryId);

  /// Alternate clue phrasings per entry (other senses, fill-in-the-blank
  /// example sentences) so the crossword doesn't always show the same
  /// first-sense definition.
  ///
  /// A word with the person's own meanings gets those too — after the
  /// dictionary's, and as its only clues when the dictionary doesn't know
  /// the word at all.
  Future<Map<int, List<String>>> crosswordClueOptions(Map<int, String> headwordsByEntryId) async {
    final options = await _db.crosswordClueOptions(headwordsByEntryId);
    final slang = await _slang?.clueOptions(headwordsByEntryId.keys);
    if (slang == null || slang.isEmpty) return options;
    return {
      ...options,
      for (final MapEntry(:key, :value) in slang.entries) key: [...?options[key], ...value],
    };
  }

  /// Search results with inflection resolution folded in, in the order a
  /// reader wants them: the headword that is exactly the query, then the
  /// lemmas the query is an inflection of ("ran" → "run", tagged with the
  /// form so the row can say so), then the prefix matches.
  ///
  /// Used to fall back to forms only when the prefix search came back
  /// empty, which for any short inflection it never did — "ran*" always
  /// matches "range" — so "run" never appeared for "ran" at all.
  ///
  /// Slang Stack words are folded in alongside: a dictionary row the person
  /// added their own meaning to is marked as theirs, and a word only the
  /// Slang Stack knows goes with the exact match when it is one, else
  /// straight after the lemmas — the person's own words are the likeliest
  /// thing they're looking for, ahead of the dictionary's long tail.
  Future<List<EntrySummary>> searchOrResolve(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final results = await _db.search(query);
    final lemmas = await _db.resolveForm(trimmed);
    final slang = await _slang?.search(trimmed) ?? const <EntrySummary>[];

    final lower = trimmed.toLowerCase();
    final slangHeadwords = {for (final s in slang) s.headword};
    EntrySummary mark(EntrySummary r) => slangHeadwords.contains(r.headword) ? r.asSlang() : r;
    final seen = <String>{};
    final merged = <EntrySummary>[];
    for (final r in [...results, ...slang]) {
      if (r.headword.toLowerCase() == lower && seen.add(r.headword)) merged.add(mark(r));
    }
    for (final l in lemmas) {
      if (seen.add(l.headword)) merged.add(mark(l.withMatchedForm(trimmed)));
    }
    for (final r in [...slang, ...results]) {
      if (seen.add(r.headword)) merged.add(mark(r));
    }
    return merged;
  }
}

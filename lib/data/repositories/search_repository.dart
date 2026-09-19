import '../../domain/models/daily_word.dart';
import '../../domain/models/entry.dart';
import '../dictionary/dictionary_database.dart';

class SearchRepository {
  final DictionaryDatabase _db;

  SearchRepository(this._db);

  Future<List<EntrySummary>> search(String query) => _db.search(query);

  Future<WordEntry?> loadWord(String headword) => _db.loadWord(headword);

  /// The featured word for [day] — see `DictionaryDatabase.wordOfTheDay`.
  Future<DailyWord?> wordOfTheDay(DateTime day) => _db.wordOfTheDay(day);

  /// Resolves a single word tapped inside a gloss, example, or etymology
  /// line to its full entry — tries the exact headword first, then falls
  /// back to resolving an inflected surface form (tapping "ran" finds
  /// "run"). Returns null if the word isn't in the dictionary at all.
  Future<WordEntry?> lookupTappedWord(String word) async {
    final lower = word.toLowerCase();
    final direct = await _db.loadWord(lower);
    if (direct != null) return direct;
    final resolved = await _db.resolveForm(lower);
    if (resolved.isEmpty) return null;
    return _db.loadWord(resolved.first.headword);
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
  Future<Map<int, List<String>>> crosswordClueOptions(Map<int, String> headwordsByEntryId) =>
      _db.crosswordClueOptions(headwordsByEntryId);

  /// Search results with inflection resolution folded in, in the order a
  /// reader wants them: the headword that is exactly the query, then the
  /// lemmas the query is an inflection of ("ran" → "run", tagged with the
  /// form so the row can say so), then the prefix matches.
  ///
  /// Used to fall back to forms only when the prefix search came back
  /// empty, which for any short inflection it never did — "ran*" always
  /// matches "range" — so "run" never appeared for "ran" at all.
  Future<List<EntrySummary>> searchOrResolve(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final results = await _db.search(query);
    final lemmas = await _db.resolveForm(trimmed);
    if (lemmas.isEmpty) return results;

    final lower = trimmed.toLowerCase();
    final seen = <String>{};
    final merged = <EntrySummary>[];
    for (final r in results) {
      if (r.headword.toLowerCase() == lower && seen.add(r.headword)) merged.add(r);
    }
    for (final l in lemmas) {
      if (seen.add(l.headword)) merged.add(l.withMatchedForm(trimmed));
    }
    for (final r in results) {
      if (seen.add(r.headword)) merged.add(r);
    }
    return merged;
  }
}

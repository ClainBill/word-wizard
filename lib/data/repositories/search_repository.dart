import '../../domain/models/entry.dart';
import '../dictionary/dictionary_database.dart';

class SearchRepository {
  final DictionaryDatabase _db;

  SearchRepository(this._db);

  Future<List<EntrySummary>> search(String query) => _db.search(query);

  Future<WordEntry?> loadWord(String headword) => _db.loadWord(headword);

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

  /// Falls back to inflection resolution when a direct headword search
  /// comes back empty — lets a lookup of "ran" surface "run".
  Future<List<EntrySummary>> searchOrResolve(String query) async {
    final direct = await _db.search(query);
    if (direct.isNotEmpty) return direct;
    return _db.resolveForm(query);
  }
}

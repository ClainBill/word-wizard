import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../domain/crossword/clues.dart';
import '../../domain/crossword/crossword_models.dart';
import '../../domain/crossword/generator.dart';
import '../user/user_database.dart';
import 'search_repository.dart';
import 'study_repository.dart';

/// A loaded puzzle plus whatever progress the user's already saved for it.
typedef CrosswordSession = ({CrosswordPuzzle puzzle, Map<String, String> progress, bool completed});

/// One day's entry in a difficulty's history list.
typedef CrosswordHistoryEntry = ({String date, bool completed});

/// The scored word list the generator searches — built offline by
/// `tool/pipeline/export_crossword_wordlist.py`, see PORTING_SPEC.md §1-§2.
const _wordListAsset = 'assets/crossword/wordlist.tsv';

// A word only makes sense as an SRS anchor if it's a single run of letters —
// multi-word entries ("an apple a day") or ones with hyphens can't occupy a
// straight run of cells. Apostrophes are fine; they're simply dropped from
// the grid form, which is the spec's `text` vs `display` split.
final _anchorable = RegExp(r"^[A-Za-z']+$");

/// How many previous puzzles' answers are barred from reappearing (§A.2
/// requirement 10). These reach the *solver*, not just anchor selection —
/// the reference implementation's own gap, and §A.4's one-line fix.
const _recentPuzzleCount = 10;

/// Common English function words have no dedicated part-of-speech in this
/// dictionary's schema (only noun/adj/verb/adv), so their best-ranked entry
/// is often some leftover noun sense instead — frequently a niche technical
/// initialism (the bundled data's top-ranked "FOR" entry glosses as
/// "Initialism of frame of reference", "HIS" as "health information
/// system"). These are exactly the words a score-ordered solver reaches for
/// constantly, so a small hand-written override covers the highest-traffic
/// case cheaply, leaving the dictionary-derived clue pipeline for everything
/// else.
const _commonWordClues = {
  'A': 'Indefinite article',
  'AN': 'Indefinite article before a vowel sound',
  'THE': 'Definite article',
  'AND': 'Plus',
  'OR': 'One option or the other',
  'BUT': 'However',
  'IF': 'In the event that',
  'SO': 'Therefore',
  'AS': 'In the same way that',
  'AT': 'Preposition of location',
  'BY': 'Near, or via',
  'TO': 'Toward',
  'OF': 'Belonging to',
  'IN': 'Not outside',
  'ON': 'Atop',
  'UP': 'Not down',
  'IS': 'Exists',
  'ARE': 'Exist (plural)',
  'WAS': 'Existed, once',
  'WERE': 'Existed, in the past',
  'BE': 'Exist',
  'HIS': "Belonging to him",
  'HER': "Belonging to her",
  'ITS': "Belonging to it",
  'OUR': 'Belonging to us',
  'YOUR': 'Belonging to you',
  'THEIR': 'Belonging to them',
  'THEM': 'Those people, objectively',
  'SHE': 'Female pronoun',
  'HIM': 'Objective pronoun for a male',
  'DID': 'Performed, in the past',
  'HAS': 'Possesses',
  'HAD': 'Possessed, in the past',
  'NOT': 'In no way',
  'NO': 'Negative reply',
  'YES': 'Affirmative reply',
  'ALL': 'Every one',
  'ANY': 'Some, of any kind',
  'EACH': 'Every single one',
  'WHO': 'Which person',
  'WHAT': 'Which thing',
  'WHEN': 'At what time',
  'WHERE': 'In what place',
  'WHY': 'For what reason',
  'HOW': 'In what way',
  'CAN': 'Is able to',
  'MAY': 'Might',
  'MUST': 'Has to',
  'WILL': 'Shall',
  'SHALL': 'Will, formally',
  'WOULD': 'Might, conditionally',
  'COULD': 'Was able to',
  'SHOULD': 'Ought to',
  'ETC': 'And so on, for short',
  'VIA': 'By way of',
  'PER': 'For each',
  'USA': 'America, in brief',
};

// Deliberately top-level, not a method or a closure written inline inside
// one: Isolate.run refuses to send a closure whose captured-variable context
// includes an unsendable object, and a closure created inside an instance
// method shares its context with the rest of that method's captures —
// including `this` — even if the closure itself never touches `this`. A
// genuinely top-level function has no such context to leak.
Future<CrosswordPuzzle?> _runGenerateInIsolate(CrosswordIsolateRequest request) {
  return Isolate.run(() => generateCrosswordFromSource(request));
}

class CrosswordRepository {
  final UserDatabase _db;
  final StudyRepository _studyRepository;
  final SearchRepository _searchRepository;
  final _rand = Random();

  /// Cached across generations — the asset is ~1.8 MB and Flutter caches the
  /// decoded string itself, but keeping the reference avoids a re-decode on
  /// every regenerate.
  String? _wordListSource;

  CrosswordRepository(this._db, this._studyRepository, this._searchRepository);

  static String today() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<CrosswordPuzzleRow?> _row(CrosswordDifficulty difficulty, String date) {
    return (_db.select(_db.crosswordPuzzles)
          ..where((t) => t.puzzleDate.equals(date) & t.difficulty.equals(difficulty.storageKey)))
        .getSingleOrNull();
  }

  CrosswordSession _sessionFromRow(CrosswordPuzzleRow row) => (
        puzzle: CrosswordPuzzle.fromJson(jsonDecode(row.gridJson) as Map<String, dynamic>),
        progress: Map<String, String>.from(jsonDecode(row.progressJson) as Map),
        completed: row.completed,
      );

  /// Loads today's puzzle for [difficulty] if one's already been generated,
  /// otherwise builds one and persists it.
  Future<CrosswordSession?> loadOrGenerate(CrosswordDifficulty difficulty) async {
    final existing = await _row(difficulty, today());
    if (existing != null) return _sessionFromRow(existing);
    return _generateAndSave(difficulty, today());
  }

  /// Loads a past day's puzzle for [difficulty], or `null` if none was ever
  /// generated for that day — history only ever shows days that actually
  /// happened, it never generates one for an arbitrary past date.
  Future<CrosswordSession?> loadForDate(CrosswordDifficulty difficulty, String date) async {
    final row = await _row(difficulty, date);
    return row == null ? null : _sessionFromRow(row);
  }

  /// Replaces today's puzzle for [difficulty] with a freshly generated one —
  /// discards whatever progress was saved against the old one. Only ever
  /// applies to today; regenerating a past day wouldn't make sense since
  /// history is meant to reflect what that day actually looked like.
  Future<CrosswordSession?> regenerate(CrosswordDifficulty difficulty) async {
    await (_db.delete(_db.crosswordPuzzles)
          ..where((t) => t.puzzleDate.equals(today()) & t.difficulty.equals(difficulty.storageKey)))
        .go();
    // A fresh random seed rather than the day's deterministic one, so "Start
    // new" actually produces a different puzzle.
    return _generateAndSave(difficulty, today(), seed: _rand.nextInt(1 << 30));
  }

  Future<CrosswordSession?> _generateAndSave(
    CrosswordDifficulty difficulty,
    String date, {
    int? seed,
  }) async {
    final puzzle = await _generate(difficulty, date, seed: seed);
    if (puzzle == null) return null;

    await _db.into(_db.crosswordPuzzles).insertOnConflictUpdate(
          CrosswordPuzzlesCompanion.insert(
            puzzleDate: date,
            difficulty: difficulty.storageKey,
            gridJson: jsonEncode(puzzle.toJson()),
          ),
        );

    return (puzzle: puzzle, progress: const <String, String>{}, completed: false);
  }

  /// Every day a puzzle's been generated for [difficulty], most recent
  /// first, with whether it was ever completed — for the history list.
  Future<List<CrosswordHistoryEntry>> history(CrosswordDifficulty difficulty, {int limit = 60}) async {
    final rows = await (_db.select(_db.crosswordPuzzles)
          ..where((t) => t.difficulty.equals(difficulty.storageKey))
          ..orderBy([(t) => OrderingTerm.desc(t.puzzleDate)])
          ..limit(limit))
        .get();
    return [for (final r in rows) (date: r.puzzleDate, completed: r.completed)];
  }

  /// Answers used by the last [_recentPuzzleCount] puzzles at this size.
  Future<Set<String>> _recentAnswers(CrosswordDifficulty difficulty) async {
    final rows = await (_db.select(_db.crosswordPuzzles)
          ..where((t) => t.difficulty.equals(difficulty.storageKey))
          ..orderBy([(t) => OrderingTerm.desc(t.puzzleDate)])
          ..limit(_recentPuzzleCount))
        .get();
    final answers = <String>{};
    for (final row in rows) {
      // Never let a historical row stop today's puzzle being built. This is
      // the only place generation reads back puzzles the app wrote in earlier
      // versions, so it is the one place where a schema drift that was
      // harmless when it happened turns into "no crossword, ever" — which is
      // exactly what a missing `entryId` on year-old rows did. Repeat
      // avoidance is a nicety; shipping a puzzle is not.
      try {
        final puzzle = CrosswordPuzzle.fromJson(jsonDecode(row.gridJson) as Map<String, dynamic>);
        answers.addAll(puzzle.words.map((w) => w.answer));
      } catch (_) {
        continue;
      }
    }
    return answers;
  }

  Future<String> _loadWordList() async =>
      _wordListSource ??= await rootBundle.loadString(_wordListAsset);

  Future<CrosswordPuzzle?> _generate(
    CrosswordDifficulty difficulty,
    String date, {
    int? seed,
  }) async {
    final due = await _studyRepository.dueQueue(limit: 200);
    final all = await _studyRepository.allStudyingCards(limit: 200);

    // Due cards first, then the rest of the study pool. Only `maxAnchors` of
    // these are ever placed (§7.1: 1 / 2 / 3 by size), but the extras give
    // `fitAnchors` alternatives when a skeleton has no slot of the right
    // length — see its graceful degradation.
    final seenEntryIds = <int>{};
    final srsWords = <(String, String, int)>[];
    for (final source in [due, all]) {
      for (final card in source) {
        if (srsWords.length >= 12) break;
        if (!seenEntryIds.add(card.entryId)) continue;
        if (!_anchorable.hasMatch(card.headword)) continue;
        final text = card.headword.replaceAll("'", '').toUpperCase();
        if (text.length < 3 || text.length > difficulty.size) continue;
        srsWords.add((text, card.headword, card.entryId));
      }
    }

    final request = CrosswordIsolateRequest(
      wordListSource: await _loadWordList(),
      difficulty: difficulty,
      srsWords: srsWords,
      recentUsage: await _recentAnswers(difficulty),
      weekday: DateTime.parse(date).weekday,
      // Seeded from the date and size so a given day's puzzle is
      // reproducible (§12), unless the user asked for a new one.
      seed: seed ?? Object.hash(date, difficulty.storageKey),
    );

    // Real CPU-bound backtracking search — seconds on a Mega grid — so it
    // goes on its own isolate rather than freezing the UI. Routed through a
    // top-level function (see _runGenerateInIsolate) rather than an inline
    // closure, which would drag `this` and its unsendable database
    // connection across the boundary.
    final puzzle = await _runGenerateInIsolate(request);
    if (puzzle == null) return null;

    return _withClues(puzzle);
  }

  /// Resolves clue text for the ~10-100 words that actually made it into the
  /// grid — not the whole 49,000-entry pool.
  ///
  /// The spec bakes a clue into the word list asset because its clue source
  /// (WordNet) isn't available at runtime, and is candid that the result is
  /// the system's weakest part (§8) and the highest-value thing to replace
  /// (§A.4). This app's clue source *is* available at runtime: the bundled
  /// dictionary yields definition, synonym, "___, for short" and
  /// fill-in-the-blank phrasings from each word's earliest senses. What is
  /// ported verbatim is the part §8 says to port exactly — the giveaway
  /// filter, applied here as the final gate.
  Future<CrosswordPuzzle> _withClues(CrosswordPuzzle puzzle) async {
    final headwordsByEntryId = <int, String>{
      for (final w in puzzle.words)
        if (w.entryId >= 0) w.entryId: w.answer,
    };
    final clueOptions = await _searchRepository.crosswordClueOptions(headwordsByEntryId);

    String pickClue(int entryId, String answer) {
      final override = _commonWordClues[answer];
      if (override != null) return override;
      final options = [
        for (final option in clueOptions[entryId] ?? const <String>[])
          if (!isGiveaway(option, answer)) option,
      ];
      if (options.isEmpty) return 'A ${answer.length}-letter word.';
      return options[_rand.nextInt(options.length)];
    }

    return CrosswordPuzzle(
      width: puzzle.width,
      height: puzzle.height,
      words: [for (final w in puzzle.words) w.copyWith(clue: pickClue(w.entryId, w.answer))],
      themeName: puzzle.themeName,
      themeKind: puzzle.themeKind,
      qualityScore: puzzle.qualityScore,
    );
  }

  Future<void> saveProgress(CrosswordDifficulty difficulty, String date, Map<String, String> filledLetters) async {
    await (_db.update(_db.crosswordPuzzles)
          ..where((t) => t.puzzleDate.equals(date) & t.difficulty.equals(difficulty.storageKey)))
        .write(CrosswordPuzzlesCompanion(progressJson: Value(jsonEncode(filledLetters))));
  }

  Future<void> markCompleted(CrosswordDifficulty difficulty, String date) async {
    await (_db.update(_db.crosswordPuzzles)
          ..where((t) => t.puzzleDate.equals(date) & t.difficulty.equals(difficulty.storageKey)))
        .write(const CrosswordPuzzlesCompanion(completed: Value(true)));
  }
}

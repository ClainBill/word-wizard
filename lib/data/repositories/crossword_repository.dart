import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:drift/drift.dart';

import '../../domain/crossword/crossword_generator.dart';
import '../../domain/crossword/crossword_models.dart';
import '../user/user_database.dart';
import 'search_repository.dart';
import 'study_repository.dart';

/// A loaded puzzle plus whatever progress the user's already saved for it.
typedef CrosswordSession = ({CrosswordPuzzle puzzle, Map<String, String> progress, bool completed});

/// One day's entry in a difficulty's history list.
typedef CrosswordHistoryEntry = ({String date, bool completed});

// A word only makes sense in a crossword if it's a single run of letters —
// multi-word entries ("an apple a day") or ones with hyphens/apostrophes
// can't occupy a straight run of cells. Mirrors the check the "Spell it"
// study exercise already applies to headwords for the same reason.
final _pureAlpha = RegExp(r'^[A-Za-z]+$');

// "A few" study-pool words mixed into an otherwise dictionary-filled grid —
// enough to feel personal without requiring a big study pool to unlock any
// difficulty.
const _maxSeedWords = 6;

// Common English function words (articles, conjunctions, prepositions,
// pronouns, auxiliary verbs) have no dedicated part-of-speech in this
// dictionary's schema (only noun/adj/verb/adv) — so their best-ranked entry
// is often some leftover noun sense instead, frequently a niche technical
// acronym (e.g. the bundled data's top-ranked "FOR" entry glosses as
// "Initialism of frame of reference", "HIS" as "health information
// system"). Since these are exactly the words the frequency-biased solver
// now reaches for constantly (see crossword_generator.dart), a small
// hand-written override for the ones actually short enough to place covers
// the highest-traffic case cheaply, leaving the dictionary-derived clue
// pipeline for everything else.
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
// one: Isolate.run refuses to send a closure whose captured-variable
// context includes an unsendable object, and a closure created inside an
// instance method shares its context with the rest of that method's
// captures — including `this` — even if the closure itself never touches
// `this`. A genuinely top-level function has no such context to leak.
Future<CrosswordPuzzle?> _runGenerateInIsolate(List<CrosswordCandidate> candidates, CrosswordDifficulty difficulty) {
  return Isolate.run(
    () => generateCrossword(CrosswordGenerationRequest(candidates: candidates, difficulty: difficulty)),
  );
}

class CrosswordRepository {
  final UserDatabase _db;
  final StudyRepository _studyRepository;
  final SearchRepository _searchRepository;
  final _rand = Random();

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
  /// otherwise builds one and persists it — a handful of study-pool words
  /// first, the rest of the grid filled in with generic dictionary words so
  /// every difficulty is always playable regardless of study-pool size.
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
    return _generateAndSave(difficulty, today());
  }

  Future<CrosswordSession?> _generateAndSave(CrosswordDifficulty difficulty, String date) async {
    final puzzle = await _generate(difficulty);
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

  Future<CrosswordPuzzle?> _generate(CrosswordDifficulty difficulty) async {
    final due = await _studyRepository.dueQueue(limit: 200);
    final all = await _studyRepository.allStudyingCards(limit: 200);

    final seenEntryIds = <int>{};
    final seeds = <CrosswordCandidate>[];
    outer:
    for (final source in [due, all]) {
      for (final card in source) {
        if (seeds.length >= _maxSeedWords) break outer;
        if (!seenEntryIds.add(card.entryId)) continue;
        if (!_pureAlpha.hasMatch(card.headword)) continue;
        seeds.add(CrosswordCandidate(
          entryId: card.entryId,
          headword: card.headword,
          isDueToday: due.any((d) => d.entryId == card.entryId),
          fromStudyPool: true,
        ));
      }
    }

    // The solver needs close to the dictionary's full variety to reliably
    // fill a grid at real crossword density (see allCrosswordWords) — this
    // is genuinely hundreds of thousands of candidates, which is exactly
    // why generation runs on a background isolate below rather than being
    // built eagerly per-candidate like the old sampled approach was.
    final filler = await _searchRepository.allCrosswordWords(
      minLength: difficulty.minWordLength,
      maxLength: difficulty.maxWordLength,
    );
    final acronymOnly = await _searchRepository.acronymOnlyEntryIds();

    final candidates = <CrosswordCandidate>[
      ...seeds,
      for (final f in filler)
        if (seenEntryIds.add(f.entryId))
          CrosswordCandidate(
            entryId: f.entryId,
            headword: f.headword,
            isDueToday: false,
            fromStudyPool: false,
            isAcronymOnly: acronymOnly.contains(f.entryId),
          ),
    ];

    // The actual pattern generation + backtracking solve is real CPU-bound
    // search over hundreds of thousands of candidates and can take several
    // seconds — running it on the calling (UI) isolate would freeze the
    // app, so it goes on its own isolate. Routed through a top-level
    // function (_runGenerateInIsolate), not an inline closure here: a
    // closure written inside an instance method shares its enclosing
    // method's captured-variable context, which pulls in `this` (and, via
    // `this`, the unsendable database connection) even when the closure's
    // own body never references it — Isolate.run then refuses to send it.
    final puzzle = await _runGenerateInIsolate(candidates, difficulty);
    if (puzzle == null) return null;

    // Only now — for the ~40-90 words that actually made it into the grid,
    // not the whole candidate pool — fetch clue text.
    final headwordsByEntryId = <int, String>{for (final w in puzzle.words) w.entryId: w.answer};
    final clueOptions = await _searchRepository.crosswordClueOptions(headwordsByEntryId);
    String pickClue(int entryId, String answer) {
      final override = _commonWordClues[answer];
      if (override != null) return override;
      final options = clueOptions[entryId];
      if (options == null || options.isEmpty) return 'A ${answer.length}-letter word.';
      return options[_rand.nextInt(options.length)];
    }

    return CrosswordPuzzle(
      width: puzzle.width,
      height: puzzle.height,
      words: [for (final w in puzzle.words) w.copyWith(clue: pickClue(w.entryId, w.answer))],
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

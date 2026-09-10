import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../domain/crossword/clues.dart';
import '../../domain/crossword/crossword_models.dart';
import '../../domain/crossword/editorial.dart';
import '../../domain/crossword/generator.dart';
import '../../domain/crossword/history.dart';
import '../../domain/srs/sm2.dart';
import '../../services/crossword_review_service.dart';
import '../user/user_database.dart';
import 'search_repository.dart';
import 'settings_repository.dart';
import 'study_repository.dart';

/// A loaded puzzle plus whatever progress the user's already saved for it,
/// including which answers they had revealed rather than worked out.
///
/// [id] is the puzzle's own row: everything the screen writes back — progress,
/// completion, solve events, editorial runs — is keyed on it rather than on
/// the day, because a day can now hold several generations.
typedef CrosswordSession = ({
  int id,
  String date,
  CrosswordPuzzle puzzle,
  Map<String, String> progress,
  bool completed,
  Set<String> revealed,
});

/// One generated puzzle in a difficulty's history, with what the editorial
/// pass did to it.
typedef CrosswordHistoryEntry = ({
  int id,
  String date,
  DateTime generatedAt,
  bool completed,

  /// True when an earlier puzzle exists for the same day — i.e. this one came
  /// from "Start new".
  bool isRegeneration,
  List<CrosswordReviewRun> reviews,
});

/// One banned answer: the grid form, why it was rejected, where the verdict
/// came from ('manual' when a person added it), and when.
typedef CrosswordBannedAnswer = ({
  String answer,
  String reason,
  String difficulty,
  DateTime at,
});

/// What [CrosswordRepository.reviewInBackground] did, so the screen can say
/// so rather than leaving the user guessing whether the pass ran at all.
typedef CrosswordReviewReport = ({
  /// Non-null when clues actually changed and were saved.
  CrosswordPuzzle? revised,

  /// 'off' | 'no_key' | 'already_reviewed' | 'unsupported' | or the run's own
  /// outcome ('applied' | 'no_edits' | 'all_rejected' | 'not_applied' |
  /// 'failed').
  String status,
  CrosswordReviewRun? run,
});

/// One run of the editorial pass, read back out of the debug log.
typedef CrosswordReviewRun = ({
  int id,
  int puzzleId,
  String date,
  String difficulty,

  /// The seed of the puzzle reviewed — the same identity the generator uses,
  /// and what tells two runs of one day apart at a glance.
  int puzzleSeed,
  DateTime at,
  String model,
  String outcome,
  String error,
  int latencyMs,
  int promptTokens,
  int completionTokens,
  int reasoningTokens,
  double costUsd,
  double entertainment,
  String notes,
  int cluesProposed,
  int cluesApplied,
  int wordsProposed,
  int wordsApplied,
  List<CrosswordProposedEdit> edits,
});

/// Totals across a difficulty's review log — the "what has this cost me"
/// readout.
typedef CrosswordReviewTotals = ({
  int runs,
  int failures,
  int promptTokens,
  int completionTokens,
  int reasoningTokens,
  double costUsd,
  int cluesApplied,
  int cluesProposed,
});

/// The Crosswordler word list the generator searches — built offline, see
/// `tool/pipeline/export_crossword_wordlist.py` and PORTING_SPEC.md §1-§2.
const _wordListAsset = 'assets/crossword/wordlist.tsv';

// A word only makes sense as an SRS anchor if it's a single run of letters —
// multi-word entries ("an apple a day") or ones with hyphens can't occupy a
// straight run of cells. Apostrophes are fine; they're simply dropped from
// the grid form, which is the spec's `text` vs `display` split.
final _anchorable = RegExp(r"^[A-Za-z']+$");

// Deliberately top-level, not a method or a closure written inline inside
// one: Isolate.run refuses to send a closure whose captured-variable context
// includes an unsendable object, and a closure created inside an instance
// method shares its context with the rest of that method's captures —
// including `this` — even if the closure itself never touches `this`. A
// genuinely top-level function has no such context to leak.
Future<CrosswordPuzzle?> _runGenerateInIsolate(CrosswordIsolateRequest request) {
  return Isolate.run(() => generateCrosswordFromSource(request));
}

Future<CrosswordRevision> _runReviseInIsolate(CrosswordRevisionRequest request) {
  return Isolate.run(() => reviseCrosswordFromSource(request));
}

class CrosswordRepository {
  final UserDatabase _db;
  final StudyRepository _studyRepository;
  final SearchRepository _searchRepository;
  final SettingsRepository _settingsRepository;
  final CrosswordReviewService _reviewService;
  final _rand = Random();

  /// Cached across generations — the asset is 8.9 MB and Flutter caches the
  /// decoded string itself, but keeping the reference avoids a re-decode on
  /// every regenerate.
  String? _wordListSource;

  /// Puzzles a review is already in flight for, so a rebuild of the screen
  /// can't start a second one.
  final Set<String> _reviewsInFlight = {};

  CrosswordRepository(
    this._db,
    this._studyRepository,
    this._searchRepository,
    this._settingsRepository, {
    CrosswordReviewService reviewService = const CrosswordReviewService(),
  }) : _reviewService = reviewService;

  static String today() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// The newest puzzle generated for a day, or null if there is none.
  Future<CrosswordPuzzleRow?> _latestRow(CrosswordDifficulty difficulty, String date) {
    return (_db.select(_db.crosswordPuzzles)
          ..where((t) => t.puzzleDate.equals(date) & t.difficulty.equals(difficulty.storageKey))
          ..orderBy([(t) => OrderingTerm.desc(t.id)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<CrosswordSession> _sessionFromRow(CrosswordPuzzleRow row) async {
    final event = await (_db.select(_db.crosswordSolveEvents)
          ..where((t) => t.puzzleId.equals(row.id)))
        .getSingleOrNull();
    return (
      id: row.id,
      date: row.puzzleDate,
      puzzle: CrosswordPuzzle.fromJson(jsonDecode(row.gridJson) as Map<String, dynamic>),
      progress: Map<String, String>.from(jsonDecode(row.progressJson) as Map),
      completed: row.completed,
      revealed: event == null ? const <String>{} : _decodeAnswers(event.revealedJson),
    );
  }

  /// Loads the current puzzle for [difficulty] — the newest one generated for
  /// today — building one if today has none yet.
  Future<CrosswordSession?> loadOrGenerate(CrosswordDifficulty difficulty) async {
    final existing = await _latestRow(difficulty, today());
    if (existing != null) return await _sessionFromRow(existing);
    return _generateAndSave(difficulty, today());
  }

  /// Loads one specific generated puzzle, or null if it has been deleted.
  /// History addresses puzzles this way, since a day can hold several.
  Future<CrosswordSession?> loadPuzzle(int puzzleId) async {
    final row = await (_db.select(_db.crosswordPuzzles)..where((t) => t.id.equals(puzzleId)))
        .getSingleOrNull();
    return row == null ? null : await _sessionFromRow(row);
  }

  /// Generates an additional puzzle for today at [difficulty] and makes it the
  /// current one.
  ///
  /// The previous puzzle is **kept**, with its progress and its editorial
  /// runs: it is a history entry of its own, which is the only way to compare
  /// what regenerating actually changed. It used to be deleted, and then a
  /// second generation was indistinguishable from the first ever having
  /// happened.
  Future<CrosswordSession?> regenerate(CrosswordDifficulty difficulty) {
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
    final id = await _insert(difficulty, date, puzzle);
    return (
      id: id,
      date: date,
      puzzle: puzzle,
      progress: const <String, String>{},
      completed: false,
      revealed: const <String>{},
    );
  }

  Future<int> _insert(
    CrosswordDifficulty difficulty,
    String date,
    CrosswordPuzzle puzzle,
  ) {
    return _db.into(_db.crosswordPuzzles).insert(
          CrosswordPuzzlesCompanion.insert(
            puzzleDate: date,
            difficulty: difficulty.storageKey,
            gridJson: jsonEncode(puzzle.toJson()),
          ),
        );
  }

  /// Replaces the stored grid for one puzzle, leaving its progress alone —
  /// how a reviewed puzzle's new clues are persisted.
  Future<void> _updateGrid(int puzzleId, CrosswordPuzzle puzzle) async {
    await (_db.update(_db.crosswordPuzzles)..where((t) => t.id.equals(puzzleId)))
        .write(CrosswordPuzzlesCompanion(gridJson: Value(jsonEncode(puzzle.toJson()))));
  }

  /// Every puzzle generated for [difficulty], newest first, with whether it
  /// was completed and every editorial run against it.
  ///
  /// One entry per *generation*, not per day: "Start new" adds a row, so a
  /// day with three attempts shows three entries and each carries its own
  /// review. That is the whole point of the list while the editorial pass is
  /// being tuned — two runs of the same day sitting next to each other is how
  /// you see what changed.
  Future<List<CrosswordHistoryEntry>> history(CrosswordDifficulty difficulty,
      {int limit = 60}) async {
    final rows = await (_db.select(_db.crosswordPuzzles)
          ..where((t) => t.difficulty.equals(difficulty.storageKey))
          ..orderBy([(t) => OrderingTerm.desc(t.id)])
          ..limit(limit))
        .get();

    final runsByPuzzle = <int, List<CrosswordReviewRun>>{};
    final runsByDate = <String, List<CrosswordReviewRun>>{};
    for (final run in await reviewRuns(difficulty)) {
      runsByPuzzle.putIfAbsent(run.puzzleId, () => []).add(run);
      runsByDate.putIfAbsent(run.date, () => []).add(run);
    }

    // Oldest generation for a day is the original; anything after it came
    // from "Start new".
    final earliestForDate = <String, int>{};
    for (final row in rows) {
      final current = earliestForDate[row.puzzleDate];
      if (current == null || row.id < current) earliestForDate[row.puzzleDate] = row.id;
    }

    return [
      for (final row in rows)
        (
          id: row.id,
          date: row.puzzleDate,
          generatedAt: row.createdAt,
          completed: row.completed,
          isRegeneration: earliestForDate[row.puzzleDate] != row.id,
          // Runs logged before puzzles had ids fall back to their day, so old
          // history doesn't lose its costs.
          reviews: runsByPuzzle[row.id] ??
              (runsByDate[row.puzzleDate]?.where((r) => r.puzzleId == 0).toList() ??
                  const <CrosswordReviewRun>[]),
        ),
    ];
  }

  // -------------------------------------------------------------------
  // Solve events (PORTING_SPEC.md §6.2a, APP_INTEGRATION.md §3)
  // -------------------------------------------------------------------

  /// Answers the user has **worked out unaided** in the last
  /// [solveHistoryWindow] puzzles at this size.
  ///
  /// Scoped per difficulty, unlike the reference implementation's single
  /// stream: the app runs three daily puzzles side by side, and one Mega
  /// carries ~100 answers, so a shared window would blank most of a Mini's
  /// vocabulary for a week.
  Future<Set<String>> _blockedAnswers(CrosswordDifficulty difficulty) async {
    final rows = await (_db.select(_db.crosswordSolveEvents)
          ..where((t) => t.difficulty.equals(difficulty.storageKey))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
          ..limit(solveHistoryWindow))
        .get();
    final events = [
      for (final row in rows)
        CrosswordSolveEvent(
          puzzleId: '${row.puzzleDate}/${row.difficulty}',
          solved: _decodeAnswers(row.solvedJson),
          revealed: _decodeAnswers(row.revealedJson),
        ),
    ];
    return blockedAnswersFrom(events);
  }

  Set<String> _decodeAnswers(String json) {
    try {
      return {for (final a in jsonDecode(json) as List) a as String};
    } catch (_) {
      // Never let a malformed historical row stop today's puzzle being
      // built. Repeat avoidance is a nicety; shipping a puzzle is not.
      return const {};
    }
  }

  /// Records what the user has solved and revealed so far in one puzzle.
  ///
  /// Called as they play rather than only at completion, because a puzzle
  /// they solve most of and abandon still taught them those answers.
  Future<void> recordSolveState(
    int puzzleId,
    CrosswordDifficulty difficulty,
    String date, {
    required Set<String> solved,
    required Set<String> revealed,
  }) async {
    final companion = CrosswordSolveEventsCompanion(
      puzzleId: Value(puzzleId),
      puzzleDate: Value(date),
      difficulty: Value(difficulty.storageKey),
      solvedJson: Value(jsonEncode(solved.toList()..sort())),
      revealedJson: Value(jsonEncode(revealed.toList()..sort())),
      updatedAt: Value(DateTime.now()),
    );
    // One row per puzzle, updated as they play. Written as an explicit
    // select-then-write rather than an upsert because the table has no unique
    // key to conflict on any more — puzzles are addressed by id.
    final existing = await (_db.select(_db.crosswordSolveEvents)
          ..where((t) => t.puzzleId.equals(puzzleId)))
        .getSingleOrNull();
    if (existing == null) {
      await _db.into(_db.crosswordSolveEvents).insert(companion);
    } else {
      await (_db.update(_db.crosswordSolveEvents)..where((t) => t.id.equals(existing.id)))
          .write(companion);
    }
  }

  /// Credits the SRS for study words the user solved unaided.
  ///
  /// An answer worked out in a crossword is a genuine retrieval event for
  /// that word, which is exactly what the schedule wants to know
  /// (APP_INTEGRATION.md §3). Graded [Grade.good] rather than `easy`: they
  /// had the crossings to help.
  Future<void> creditStudyWords(Iterable<int> entryIds) async {
    if (entryIds.isEmpty) return;
    final cards = await _studyRepository.allStudyingCards(limit: 500);
    final wanted = entryIds.toSet();
    for (final card in cards) {
      if (!wanted.contains(card.entryId)) continue;
      // Only credit a card that is actually due; grading one that isn't
      // would push its interval out on a review the schedule never asked
      // for.
      if (card.dueAt.isAfter(DateTime.now())) continue;
      await _studyRepository.grade(card, Grade.good);
    }
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
    final candidates = <({String text, String display, int entryId})>[];
    for (final source in [due, all]) {
      for (final card in source) {
        if (candidates.length >= 12) break;
        if (!seenEntryIds.add(card.entryId)) continue;
        if (!_anchorable.hasMatch(card.headword)) continue;
        final text = card.headword.replaceAll("'", '').toUpperCase();
        if (text.length < 3 || text.length > difficulty.size) continue;
        candidates.add((text: text, display: card.headword, entryId: card.entryId));
      }
    }

    // §7.2 is explicit that an unclued anchor lands a stub clue in the
    // puzzle's most prominent slot. A study word the asset has never heard of
    // would do exactly that, so a clue is resolved here — from the app's own
    // dictionary, which is the one clue source the asset doesn't have and the
    // generator's isolate can't reach.
    final clueOptions = await _searchRepository.crosswordClueOptions({
      for (final candidate in candidates) candidate.entryId: candidate.text,
    });
    final srsWords = <CrosswordSrsWord>[
      for (final candidate in candidates)
        (
          text: candidate.text,
          display: candidate.display,
          entryId: candidate.entryId,
          clue: (clueOptions[candidate.entryId] ?? const <String>[])
              .where((option) => !isGiveaway(option, candidate.text))
              .firstOrNull,
        ),
    ];

    final request = CrosswordIsolateRequest(
      wordListSource: await _loadWordList(),
      difficulty: difficulty,
      srsWords: srsWords,
      // The cooldown and the ban list are both "never put this in the grid",
      // so the solver takes their union — but they mean different things and
      // are kept apart everywhere else: one expires after ten puzzles, the
      // other is a standing verdict.
      blockedAnswers: {
        ...await _blockedAnswers(difficulty),
        ...await _bannedAnswerSet(),
      },
      weekday: DateTime.parse(date).weekday,
      // Seeded from the date and size so a given day's puzzle is
      // reproducible (§12), unless the user asked for a new one. The seed is
      // stored on the puzzle: (seed, size, weekday, srsWords, blockedAnswers)
      // is the whole of a puzzle's identity.
      seed: seed ?? Object.hash(date, difficulty.storageKey),
    );

    // Real CPU-bound backtracking search — up to seconds on a Mega grid — so
    // it goes on its own isolate rather than freezing the UI. Routed through
    // a top-level function (see _runGenerateInIsolate) rather than an inline
    // closure, which would drag `this` and its unsendable database
    // connection across the boundary.
    return _runGenerateInIsolate(request);
  }

  // -------------------------------------------------------------------
  // The editorial pass (PORTING_SPEC.md §9.3-§9.4)
  // -------------------------------------------------------------------

  /// Whether a review could run at all — no key, no pass, and no complaint.
  bool get reviewConfigured => _reviewService.isConfigured;

  /// Whether the debug switch currently allows the pass to spend money.
  Future<bool> get reviewEnabled => _settingsRepository.crosswordReviewEnabled();

  /// Reviews a puzzle in the background and, if anything survives
  /// verification, persists the revision.
  ///
  /// **Never call this on the click path.** The measured latency is ~15
  /// seconds and flat in puzzle size, so fifteen seconds between tapping Play
  /// and seeing a grid is what putting it there would cost. The caller shows
  /// the deterministic puzzle first and swaps the clues in only if the review
  /// lands before the user has started — never mid-solve.
  ///
  /// Always reports what happened, including the reasons it did nothing:
  /// silence is indistinguishable from a broken key, and the whole point of
  /// the debug switch is being able to tell.
  Future<CrosswordReviewReport> reviewInBackground(
    int puzzleId,
    CrosswordDifficulty difficulty,
    String date,
    CrosswordPuzzle puzzle,
  ) async {
    const nothing = (revised: null, run: null);
    if (puzzle.reviewed) return (revised: null, status: 'already_reviewed', run: null);
    if (!reviewConfigured) return (revised: null, status: 'no_key', run: null);
    // A puzzle saved before slot ids were persisted can't be reviewed: the
    // reviewer keys its edits by them.
    if (puzzle.words.any((w) => w.slotId < 0)) {
      return (revised: null, status: 'unsupported', run: null);
    }
    // The debug switch. Deliberately checked *before* the puzzle is marked
    // reviewed, so turning the pass back on later still reviews this puzzle
    // rather than skipping it forever.
    if (!await _settingsRepository.crosswordReviewEnabled()) {
      return (revised: null, status: 'off', run: null);
    }

    final key = '$puzzleId';
    if (!_reviewsInFlight.add(key)) {
      return (revised: null, status: 'already_reviewed', run: null);
    }
    try {
      final weekday = DateTime.parse(date).weekday;
      final result = await _reviewService.review(puzzle, weekday: weekday);
      final verdict = result.verdict;

      if (result.error.isNotEmpty) {
        // A failed call is not an answer, so the puzzle is left unreviewed
        // and will be tried again next time it is opened.
        final run = await _logReview(puzzleId, difficulty, date, puzzle, result,
            outcome: 'failed');
        return (revised: null, status: 'failed', run: run);
      }

      if (verdict.isEmpty) {
        // An empty verdict *is* a real answer ("this puzzle is fine"), so the
        // puzzle is marked reviewed and not paid for twice.
        final run = await _logReview(puzzleId, difficulty, date, puzzle, result,
            outcome: 'no_edits');
        await _updateGrid(puzzleId, puzzle.copyWith(reviewed: true));
        return (revised: null, status: 'no_edits', run: run);
      }

      // The words this verdict rejects are recorded before the re-fill, so
      // they stay out of future puzzles even if this grid can't lose them.
      final byId = {for (final w in puzzle.words) w.slotId: w};
      final anchors = puzzle.anchors.toSet();
      await _banAnswers(difficulty, {
        for (final ban in verdict.bannedAnswers.entries)
          if (byId[ban.key] != null && !anchors.contains(byId[ban.key]!.answer))
            byId[ban.key]!.answer: ban.value,
      });

      final revision = await _runReviseInIsolate(CrosswordRevisionRequest(
        wordListSource: await _loadWordList(),
        puzzle: puzzle,
        verdict: verdict,
        blockedAnswers: {
          ...await _blockedAnswers(difficulty),
          ...await _bannedAnswerSet(),
        },
        seed: puzzle.seed,
      ));

      if (revision.wordsRejectedReason.isNotEmpty) {
        debugPrint('crossword review: word edits rejected '
            '(${revision.wordsRejectedReason})');
      }

      if (!revision.changed) {
        final run = await _logReview(puzzleId, difficulty, date, puzzle, result,
            outcome: 'all_rejected', revision: revision);
        await _updateGrid(puzzleId, revision.puzzle.copyWith(reviewed: true));
        return (revised: null, status: 'all_rejected', run: run);
      }

      // Never change a puzzle underneath someone who has started it. Word
      // edits re-solve the grid, so letters they have already entered would
      // stop matching their own puzzle; even a pure clue swap is disorienting
      // mid-solve. The review is dropped rather than deferred: it was written
      // against this exact grid, and re-reviewing a fresh puzzle is cheaper
      // than reasoning about a stale verdict.
      final current = await (_db.select(_db.crosswordPuzzles)
            ..where((t) => t.id.equals(puzzleId)))
          .getSingleOrNull();
      final started = current == null ||
          current.completed ||
          (jsonDecode(current.progressJson) as Map).isNotEmpty;
      if (started) {
        final run = await _logReview(puzzleId, difficulty, date, puzzle, result,
            outcome: 'not_applied', revision: revision);
        if (current != null) {
          await _updateGrid(puzzleId, puzzle.copyWith(reviewed: true));
        }
        return (revised: null, status: 'not_applied', run: run);
      }

      final run = await _logReview(puzzleId, difficulty, date, puzzle, result,
          outcome: 'applied', revision: revision);
      await _updateGrid(puzzleId, revision.puzzle);
      return (revised: revision.puzzle, status: 'applied', run: run);
    } catch (error) {
      // The pass is an upgrade and nothing more: any failure leaves the
      // deterministic puzzle exactly as it was.
      debugPrint('crossword review failed: $error');
      return (revised: nothing.revised, status: 'failed', run: nothing.run);
    } finally {
      _reviewsInFlight.remove(key);
    }
  }

  /// Records what one run did and what it billed — the debug log behind the
  /// history screen's cost readout.
  ///
  /// Failures are logged too, and deliberately: a call that returned HTTP 429
  /// or timed out after 45s is exactly what you want to see when the pass
  /// appears to be doing nothing.
  Future<CrosswordReviewRun> _logReview(
    int puzzleId,
    CrosswordDifficulty difficulty,
    String date,
    CrosswordPuzzle puzzle,
    CrosswordReviewResult result, {
    required String outcome,
    CrosswordRevision? revision,
  }) async {
    final id = await _db.into(_db.crosswordReviewLog).insert(
          CrosswordReviewLogCompanion.insert(
            puzzleId: Value(puzzleId),
            puzzleDate: date,
            difficulty: difficulty.storageKey,
            puzzleSeed: Value(puzzle.seed),
            model: Value(result.model),
            outcome: outcome,
            error: Value(result.error),
            latencyMs: Value(result.latencyMs),
            promptTokens: Value(result.promptTokens),
            completionTokens: Value(result.completionTokens),
            reasoningTokens: Value(result.reasoningTokens),
            costUsd: Value(estimateCostUsd(
              model: result.model,
              promptTokens: result.promptTokens,
              completionTokens: result.completionTokens,
            )),
            entertainment: Value(result.verdict.entertainment),
            notes: Value(result.verdict.notes),
            cluesProposed: Value(
                revision?.cluesProposed ?? result.verdict.clueEdits.length),
            cluesApplied: Value(revision?.cluesApplied ?? 0),
            wordsProposed: Value(
                revision?.wordsProposed ?? result.verdict.bannedAnswers.length),
            wordsApplied: Value(revision?.wordsApplied ?? 0),
            editsJson: Value(jsonEncode(
                [for (final edit in revision?.edits ?? const []) edit.toJson()])),
          ),
        );
    final row = await (_db.select(_db.crosswordReviewLog)..where((t) => t.id.equals(id)))
        .getSingle();
    return _runFromRow(row);
  }

  /// The editorial runs against one specific puzzle, newest first.
  Future<List<CrosswordReviewRun>> reviewRunsForPuzzle(int puzzleId) async {
    final rows = await (_db.select(_db.crosswordReviewLog)
          ..where((t) => t.puzzleId.equals(puzzleId))
          ..orderBy([(t) => OrderingTerm.desc(t.id)]))
        .get();
    return [for (final row in rows) _runFromRow(row)];
  }

  /// Every logged review for one difficulty, most recent first.
  Future<List<CrosswordReviewRun>> reviewRuns(
    CrosswordDifficulty difficulty, {
    int limit = 200,
  }) async {
    final rows = await (_db.select(_db.crosswordReviewLog)
          ..where((t) => t.difficulty.equals(difficulty.storageKey))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
    return [for (final row in rows) _runFromRow(row)];
  }

  CrosswordReviewRun _runFromRow(CrosswordReviewLogRow row) {
    List<CrosswordProposedEdit> edits;
    try {
      edits = [
        for (final edit in jsonDecode(row.editsJson) as List)
          CrosswordProposedEdit.fromJson(edit as Map<String, dynamic>),
      ];
    } catch (_) {
      edits = const [];
    }
    return (
      id: row.id,
      puzzleId: row.puzzleId,
      date: row.puzzleDate,
      difficulty: row.difficulty,
      puzzleSeed: row.puzzleSeed,
      at: row.createdAt,
      model: row.model,
      outcome: row.outcome,
      error: row.error,
      latencyMs: row.latencyMs,
      promptTokens: row.promptTokens,
      completionTokens: row.completionTokens,
      reasoningTokens: row.reasoningTokens,
      costUsd: row.costUsd,
      entertainment: row.entertainment,
      notes: row.notes,
      cluesProposed: row.cluesProposed,
      cluesApplied: row.cluesApplied,
      wordsProposed: row.wordsProposed,
      wordsApplied: row.wordsApplied,
      edits: edits,
    );
  }

  /// Totals across [difficulty]'s whole review log.
  ///
  /// Reads the rows rather than going through [reviewRuns]: that would parse
  /// every run's stored edit list — a hundred clue rewrites apiece — only to
  /// add up token counts.
  Future<CrosswordReviewTotals> reviewTotals(CrosswordDifficulty difficulty) async {
    final rows = await (_db.select(_db.crosswordReviewLog)
          ..where((t) => t.difficulty.equals(difficulty.storageKey)))
        .get();
    var prompt = 0, completion = 0, reasoning = 0, applied = 0, proposed = 0, failures = 0;
    var cost = 0.0;
    for (final row in rows) {
      prompt += row.promptTokens;
      completion += row.completionTokens;
      reasoning += row.reasoningTokens;
      cost += row.costUsd;
      applied += row.cluesApplied + row.wordsApplied;
      proposed += row.cluesProposed + row.wordsProposed;
      if (row.outcome == 'failed') failures++;
    }
    return (
      runs: rows.length,
      failures: failures,
      promptTokens: prompt,
      completionTokens: completion,
      reasoningTokens: reasoning,
      costUsd: cost,
      cluesApplied: applied,
      cluesProposed: proposed,
    );
  }

  /// Every banned answer, newest first.
  Future<List<CrosswordBannedAnswer>> bannedAnswers() async {
    final rows = await (_db.select(_db.crosswordBannedAnswers)
          ..orderBy([(t) => OrderingTerm.desc(t.bannedAt)]))
        .get();
    return [
      for (final r in rows)
        (answer: r.answer, reason: r.reason, difficulty: r.difficulty, at: r.bannedAt),
    ];
  }

  /// Bans an answer by hand — the editorial pass is one source of verdicts,
  /// not the only one. A word that keeps turning up badly is quicker to add
  /// here than to round-trip through the word-list export.
  ///
  /// Normalizes to grid form, so "I do's" and IDOS are the same ban. Returns
  /// the normalized answer, or null if there were no letters in it.
  Future<String?> banAnswer(String answer, {String reason = ''}) async {
    final text = normalizeAnswer(answer);
    if (text.isEmpty) return null;
    await _db.into(_db.crosswordBannedAnswers).insert(
          CrosswordBannedAnswersCompanion.insert(
            answer: text,
            reason: Value(reason),
            difficulty: const Value('manual'),
          ),
          mode: InsertMode.insertOrReplace,
        );
    return text;
  }

  /// Rewrites the note on an existing ban.
  Future<void> updateBanReason(String answer, String reason) async {
    await (_db.update(_db.crosswordBannedAnswers)..where((t) => t.answer.equals(answer)))
        .write(CrosswordBannedAnswersCompanion(reason: Value(reason)));
  }

  Future<Set<String>> _bannedAnswerSet() async {
    final rows = await _db.select(_db.crosswordBannedAnswers).get();
    return {for (final r in rows) r.answer};
  }

  /// Records the reviewer's verdict on an answer so it stays out of future
  /// puzzles.
  ///
  /// Written even when the re-fill failed: the word is no less unfair for the
  /// grid having been unable to lose it, and the next puzzle simply won't
  /// contain it.
  Future<void> _banAnswers(
    CrosswordDifficulty difficulty,
    Map<String, String> answersAndReasons,
  ) async {
    if (answersAndReasons.isEmpty) return;
    await _db.batch((batch) {
      for (final entry in answersAndReasons.entries) {
        batch.insert(
          _db.crosswordBannedAnswers,
          CrosswordBannedAnswersCompanion.insert(
            answer: entry.key,
            reason: Value(entry.value),
            difficulty: Value(difficulty.storageKey),
          ),
          // First verdict wins; a later run re-banning the same word doesn't
          // overwrite the reason that was actually given for it.
          mode: InsertMode.insertOrIgnore,
        );
      }
    });
  }

  /// Lifts a ban — the debug screen's undo, for when the reviewer was wrong.
  Future<void> unbanAnswer(String answer) async {
    await (_db.delete(_db.crosswordBannedAnswers)..where((t) => t.answer.equals(answer)))
        .go();
  }

  Future<void> clearBannedAnswers() async {
    await _db.delete(_db.crosswordBannedAnswers).go();
  }

  /// Clears the review log for one difficulty — the debug screen's reset.
  Future<void> clearReviewLog(CrosswordDifficulty difficulty) async {
    await (_db.delete(_db.crosswordReviewLog)
          ..where((t) => t.difficulty.equals(difficulty.storageKey)))
        .go();
  }

  Future<void> saveProgress(int puzzleId, Map<String, String> filledLetters) async {
    await (_db.update(_db.crosswordPuzzles)..where((t) => t.id.equals(puzzleId)))
        .write(CrosswordPuzzlesCompanion(progressJson: Value(jsonEncode(filledLetters))));
  }

  Future<void> markCompleted(int puzzleId) async {
    await (_db.update(_db.crosswordPuzzles)..where((t) => t.id.equals(puzzleId)))
        .write(const CrosswordPuzzlesCompanion(completed: Value(true)));
  }
}

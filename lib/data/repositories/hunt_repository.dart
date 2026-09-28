import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../domain/crossword/clues.dart' show isGiveaway;
import '../../domain/games/daily_limit.dart';
import '../../domain/hunt/hunt_generator.dart';
import '../../domain/hunt/hunt_lexicon.dart';
import '../../domain/hunt/hunt_models.dart';
import '../../domain/hunt/hunt_themes.dart';
import '../../domain/models/study_direction.dart';
import '../user/user_database.dart';
import 'crossword_repository.dart' show CrosswordRepository;
import 'study_repository.dart';

/// A loaded board plus the player's progress on it.
typedef HuntSession = ({
  int id,
  String date,
  HuntPuzzle puzzle,

  /// Every word traced so far, any class.
  Set<String> found,

  /// Required words the player gave up on and was shown.
  Set<String> revealed,

  /// Whether a hint was ever spent on this board. Like a reveal, it makes
  /// the solve assisted: the board no longer ranks as clean.
  bool hinted,

  /// Required words with a hint showing — start tile and first step — that
  /// haven't been found yet.
  Set<String> hints,

  /// Hints spent so far. The budget is derived, not stored: the starting
  /// allowance plus one per bonus word found, minus this.
  int hintsUsed,

  /// Whether the halfway unlock (per-tile start counts) has been announced,
  /// so reopening the board doesn't announce it again.
  bool halfwayAnnounced,
  bool completed,

  /// Active time already banked in earlier sittings.
  int activeMs,
});

/// How far one board got, for history.
typedef HuntPlayState = ({
  int foundRequired,
  int requiredTotal,
  int bonusFound,
  int score,
  bool completed,
  bool aided,
  int? activeMs,
});

typedef HuntHistoryEntry = ({
  int id,
  String date,
  DateTime generatedAt,
  String? themeLabel,
  int studyWords,
  bool isRegeneration,
  HuntPlayState play,
});

/// What the progress JSON on a puzzle row decodes to.
typedef _Progress = ({
  Set<String> found,
  Set<String> revealed,
  bool hinted,
  Set<String> hints,
  int hintsUsed,
  bool halfwayAnnounced,
});

const _acceptedAsset = 'assets/hunt/accepted.txt';
const _mainAsset = 'assets/hunt/main.txt';
const _themesAsset = 'assets/hunt/themes.tsv';

// A study word can only be traced if it's one run of letters. Apostrophes
// are dropped from the board form, as the crossword does.
final _anchorable = RegExp(r"^[A-Za-z']+$");

// Top-level, not closures inside methods, for the reason
// crossword_repository.dart gives: an inline closure drags the method's
// whole context — `this` and its database connection — to the isolate.
Future<HuntLexicon> _buildLexicon(HuntLexiconSources sources) =>
    Isolate.run(() => buildHuntLexicon(sources));

Future<HuntGeneration> _generate(HuntIsolateRequest request) =>
    Isolate.run(() => generateHuntInIsolate(request));

/// Hints a fresh board starts with; every bonus word found earns one more.
const int huntStartingHints = 2;

/// The hint budget left on a board: the starting allowance plus one per
/// bonus word found, less what's been spent. Never negative.
int huntHintsLeft(HuntPuzzle puzzle, Iterable<String> found, int hintsUsed) {
  final bonus = found.where(puzzle.bonus.containsKey).length;
  final left = huntStartingHints + bonus - hintsUsed;
  return left < 0 ? 0 : left;
}

/// Whether half the required words are found — the point at which the
/// per-tile start counts unlock.
bool huntHalfwayReached(HuntPuzzle puzzle, Iterable<String> found) {
  final total = puzzle.requiredCount;
  if (total == 0) return false;
  final foundRequired =
      found.where((w) => puzzle.anchorWords.containsKey(w) || puzzle.main.containsKey(w)).length;
  return foundRequired * 2 >= total;
}

/// The score a set of found words is worth on a puzzle: required words
/// (anchors and main) score their length, bonus words one point each.
int huntScore(HuntPuzzle puzzle, Iterable<String> found) {
  var score = 0;
  for (final word in found) {
    switch (puzzle.classify(word)) {
      case HuntWordClass.anchor || HuntWordClass.main:
        score += word.length;
      case HuntWordClass.bonus:
        score += 1;
      case null:
        break;
    }
  }
  return score;
}

class HuntRepository {
  final UserDatabase _db;
  final StudyRepository _studyRepository;
  final _rand = Random();

  /// Built once per app session, off the UI isolate, and reused for every
  /// generation (research contract §8). Held as a future so two screens
  /// asking at once share one build.
  Future<HuntLexicon>? _lexicon;
  HuntThemeSet? _themes;

  HuntRepository(this._db, this._studyRepository);

  static const _game = 'hunt';
  static const _difficulty = 'daily';

  /// How many study words to ask for. Research milestone 0.4's provisional
  /// decision: two, with fallback. The theme word makes three requested;
  /// the generator drops from the end, so the order below is the priority.
  static const _studyAnchors = 2;

  /// Theme anchors used in this many recent boards are avoided when the
  /// theme has other words to offer.
  static const _themeCooldown = 14;

  Future<HuntLexicon> lexicon() => _lexicon ??= () async {
        final accepted = await rootBundle.loadString(_acceptedAsset);
        final main = await rootBundle.loadString(_mainAsset);
        return _buildLexicon((acceptedText: accepted, mainText: main));
      }();

  Future<HuntThemeSet> themes() async =>
      _themes ??= HuntThemeSet.parse(await rootBundle.loadString(_themesAsset));

  // -------------------------------------------------------------------
  // Loading
  // -------------------------------------------------------------------

  /// Whether a row is this person's own board rather than a group's: a
  /// group board is imported under today's date like any other, but is
  /// never "today's board" and never counts against the daily allowance.
  Expression<bool> _ownBoard($HuntPuzzlesTable t) => t.id.isNotInQuery(
        _db.selectOnly(_db.groupPuzzleLinks)
          ..addColumns([_db.groupPuzzleLinks.localPuzzleId])
          ..where(_db.groupPuzzleLinks.kind.equals('hunt')),
      );

  Future<HuntPuzzleRow?> _latestRow(String date) {
    return (_db.select(_db.huntPuzzles)
          ..where((t) => t.puzzleDate.equals(date) & _ownBoard(t))
          ..orderBy([(t) => OrderingTerm.desc(t.id)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// How many of this person's own boards exist for today.
  Future<int> boardsToday() async {
    final count = _db.huntPuzzles.id.count();
    final query = _db.selectOnly(_db.huntPuzzles)
      ..addColumns([count])
      ..where(_db.huntPuzzles.puzzleDate.equals(CrosswordRepository.today()) &
          _ownBoard(_db.huntPuzzles));
    return (await query.getSingle()).read(count) ?? 0;
  }

  /// Whether "New board" may make another board today.
  Future<bool> canStartNew() async => await boardsToday() < puzzlesPerDay;

  Future<HuntSession> _sessionFromRow(HuntPuzzleRow row) async {
    final play = await _playRow(row.id);
    final progress = _decodeProgress(row.progressJson);
    return (
      id: row.id,
      date: row.puzzleDate,
      puzzle: HuntPuzzle.fromJson(jsonDecode(row.puzzleJson) as Map<String, dynamic>),
      found: progress.found,
      revealed: progress.revealed,
      hinted: progress.hinted,
      // A hint on a word since found has nothing left to point at.
      hints: progress.hints.difference(progress.found),
      hintsUsed: progress.hintsUsed,
      halfwayAnnounced: progress.halfwayAnnounced,
      completed: row.completed,
      activeMs: play?.activeMs ?? 0,
    );
  }

  _Progress _decodeProgress(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return (
        found: {for (final w in map['found'] as List? ?? const []) w as String},
        revealed: {for (final w in map['revealed'] as List? ?? const []) w as String},
        hinted: map['hinted'] as bool? ?? false,
        hints: {for (final w in map['hints'] as List? ?? const []) w as String},
        hintsUsed: map['hintsUsed'] as int? ?? 0,
        halfwayAnnounced: map['halfwayAnnounced'] as bool? ?? false,
      );
    } catch (_) {
      return (
        found: const {},
        revealed: const {},
        hinted: false,
        hints: const {},
        hintsUsed: 0,
        halfwayAnnounced: false,
      );
    }
  }

  /// Today's board — the newest generated for today — building one if
  /// today has none yet.
  Future<HuntSession?> loadOrGenerate() async {
    final date = CrosswordRepository.today();
    final existing = await _latestRow(date);
    if (existing != null) return _sessionFromRow(existing);
    return _generateAndSave(date);
  }

  Future<HuntSession?> loadPuzzle(int puzzleId) async {
    final row = await (_db.select(_db.huntPuzzles)..where((t) => t.id.equals(puzzleId)))
        .getSingleOrNull();
    return row == null ? null : await _sessionFromRow(row);
  }

  /// Another board for today, keeping the previous one in history. At
  /// most [puzzlesPerDay] a day, counting the day's own: past that it
  /// throws [DailyPuzzleLimitReached].
  Future<HuntSession?> regenerate() async {
    if (!await canStartNew()) throw const DailyPuzzleLimitReached('Word Hunt');
    return _generateAndSave(CrosswordRepository.today(), seed: _rand.nextInt(1 << 30));
  }

  Future<HuntSession?> _generateAndSave(String date, {int? seed}) async {
    final generation = await generate(date, seed: seed);
    final puzzle = generation.puzzle;
    if (puzzle == null) return null;
    final id = await _db.into(_db.huntPuzzles).insert(
          HuntPuzzlesCompanion.insert(
            puzzleDate: date,
            puzzleJson: jsonEncode(puzzle.toJson()),
          ),
        );
    return (
      id: id,
      date: date,
      puzzle: puzzle,
      found: const <String>{},
      revealed: const <String>{},
      hinted: false,
      hints: const <String>{},
      hintsUsed: 0,
      halfwayAnnounced: false,
      completed: false,
      activeMs: 0,
    );
  }

  // -------------------------------------------------------------------
  // Generation: study words + the day's theme, into the engine
  // -------------------------------------------------------------------

  /// Builds a board for [date]. Public so the debug/history side can show
  /// diagnostics; the screens go through [loadOrGenerate].
  Future<HuntGeneration> generate(String date, {int? seed}) async {
    final lexicon = await this.lexicon();
    final resolvedSeed = seed ?? _seedFor(date);
    final rng = Random(resolvedSeed);

    final study = await _studyAnchorsFor(lexicon);
    final theme = await _themeAnchorFor(date, rng, lexicon);

    // Priority order — what the generator drops from the end of: the first
    // study word matters most, then the day's theme, then a second study
    // word. A board with one study word and a theme beats one with two
    // study words and none.
    final anchors = <HuntAnchor>[
      if (study.isNotEmpty) study.first,
      if (theme != null) theme.anchor,
      ...study.skip(1),
    ];

    return _generate((
      lexicon: lexicon,
      request: HuntGenerationRequest(
        seed: resolvedSeed,
        anchors: anchors,
        themeLabel: theme?.theme.label,
        themeWords: theme?.theme.words ?? const {},
      ),
    ));
  }

  // -------------------------------------------------------------------
  // Group boards (docs/Group Puzzles v1.1.md)
  // -------------------------------------------------------------------

  /// How many pool words a group board asks for. One more than a personal
  /// board's study words, since there's no theme anchor to make room for.
  static const _poolAnchors = 3;

  /// Builds a board anchored on a group's shared words instead of this
  /// person's study pool: same lexicon, same engine, same quality gate.
  ///
  /// Everything here must come out the same on every member's device, so
  /// the anchors are chosen from the pool sorted and shuffled by [seed],
  /// and the day's theme only colours the board (its words light up when
  /// found) — it contributes no anchor, because picking one depends on
  /// this device's recent boards.
  Future<HuntGeneration> generateFromPool(
    List<({String headword, String? gloss})> pool, {
    required String date,
    required int seed,
  }) async {
    final lexicon = await this.lexicon();
    final sorted = [...pool]..sort((a, b) => a.headword.compareTo(b.headword));
    final seen = <String>{};
    final candidates = <HuntAnchor>[];
    for (final word in sorted) {
      if (!_anchorable.hasMatch(word.headword)) continue;
      final text = word.headword.replaceAll("'", '').toUpperCase();
      if (!lexicon.isAnchorable(text) || !seen.add(text)) continue;
      final gloss = word.gloss;
      candidates.add(HuntAnchor(
        text: text,
        display: word.headword,
        kind: HuntAnchorKind.study,
        clue: gloss == null || gloss.isEmpty || isGiveaway(gloss, text) ? null : gloss,
      ));
    }
    candidates.shuffle(Random(seed));
    final theme = (await themes()).forDate(date);
    return _generate((
      lexicon: lexicon,
      request: HuntGenerationRequest(
        seed: seed,
        anchors: candidates.take(_poolAnchors).toList(),
        themeLabel: theme?.label,
        themeWords: theme?.words ?? const {},
      ),
    ));
  }

  /// Stores a board that came from elsewhere — the group's published one —
  /// as a board of this device's own, playable and timed like any other.
  /// Returns its local id.
  Future<int> importPuzzle(String date, HuntPuzzle puzzle) => _db.into(_db.huntPuzzles).insert(
        HuntPuzzlesCompanion.insert(puzzleDate: date, puzzleJson: jsonEncode(puzzle.toJson())),
      );

  /// How far one board has been played, for the group leaderboard. Null if
  /// the row is gone.
  Future<HuntPlayState?> playState(int puzzleId) async {
    final row = await (_db.select(_db.huntPuzzles)..where((t) => t.id.equals(puzzleId)))
        .getSingleOrNull();
    if (row == null) return null;
    return _historyEntry(row, await _playRow(puzzleId), row.id).play;
  }

  /// Up to [_studyAnchors] of the user's study words the lexicon can vouch
  /// for: due cards first, then the rest of the pool, every direction.
  Future<List<HuntAnchor>> _studyAnchorsFor(HuntLexicon lexicon) async {
    final due = await _studyRepository.dueQueue(
      directions: StudyDirection.values.toSet(),
      limit: 200,
    );
    final all = await _studyRepository.allStudyingCards(limit: 200);
    final seen = <int>{};
    final anchors = <HuntAnchor>[];
    for (final source in [due, all]) {
      for (final card in source) {
        if (anchors.length >= _studyAnchors) break;
        if (!seen.add(card.entryId)) continue;
        if (!_anchorable.hasMatch(card.headword)) continue;
        final text = card.headword.replaceAll("'", '').toUpperCase();
        // Unknown to the accepted lexicon means unknown to the board: it
        // would be placed and then not recognised. Skipped, not forced.
        if (!lexicon.isAnchorable(text)) continue;
        final gloss = card.gloss;
        anchors.add(HuntAnchor(
          text: text,
          display: card.headword,
          kind: HuntAnchorKind.study,
          entryId: card.entryId,
          clue: gloss == null || gloss.isEmpty || isGiveaway(gloss, text) ? null : gloss,
        ));
      }
    }
    return anchors;
  }

  Future<({HuntTheme theme, HuntAnchor anchor})?> _themeAnchorFor(
    String date,
    Random rng,
    HuntLexicon lexicon,
  ) async {
    final theme = (await themes()).forDate(date);
    if (theme == null) return null;
    final recent = await _recentThemeAnchors();
    // A theme word the lexicon doesn't accept can't be an anchor; try a
    // few picks before giving the day up as themeless.
    for (var i = 0; i < 8; i++) {
      final word = HuntThemeSet.pickAnchor(theme, rng, exclude: recent);
      if (word == null) return null;
      if (!lexicon.isAnchorable(word)) {
        recent.add(word);
        continue;
      }
      return (
        theme: theme,
        anchor: HuntAnchor(text: word, display: word.toLowerCase(), kind: HuntAnchorKind.theme),
      );
    }
    return null;
  }

  Future<Set<String>> _recentThemeAnchors() async {
    final rows = await (_db.select(_db.huntPuzzles)
          ..orderBy([(t) => OrderingTerm.desc(t.id)])
          ..limit(_themeCooldown))
        .get();
    final used = <String>{};
    for (final row in rows) {
      try {
        final json = jsonDecode(row.puzzleJson) as Map<String, dynamic>;
        for (final a in json['anchors'] as List) {
          final anchor = HuntAnchor.fromJson(a as Map<String, dynamic>);
          if (anchor.kind == HuntAnchorKind.theme) used.add(anchor.text);
        }
      } catch (_) {
        // A row that won't decode can't tell us what it used.
      }
    }
    return used;
  }

  /// The day's deterministic seed — the same date always asks for the same
  /// board, so reopening the app mid-generation can't produce a different
  /// one. FNV-1a over the date rather than `hashCode`, which the language
  /// doesn't promise is stable.
  static int _seedFor(String date) {
    var hash = 0x811c9dc5;
    for (final c in 'hunt:$date'.codeUnits) {
      hash = ((hash ^ c) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  // -------------------------------------------------------------------
  // Progress
  // -------------------------------------------------------------------

  Future<void> saveProgress(
    int puzzleId, {
    required Set<String> found,
    required Set<String> revealed,
    required bool hinted,
    Set<String> hints = const {},
    int hintsUsed = 0,
    bool halfwayAnnounced = false,
    required bool completed,
  }) async {
    await (_db.update(_db.huntPuzzles)..where((t) => t.id.equals(puzzleId))).write(
      HuntPuzzlesCompanion(
        progressJson: Value(jsonEncode({
          'found': found.toList()..sort(),
          'revealed': revealed.toList()..sort(),
          'hinted': hinted,
          'hints': hints.toList()..sort(),
          'hintsUsed': hintsUsed,
          'halfwayAnnounced': halfwayAnnounced,
        })),
        completed: Value(completed),
      ),
    );
  }

  // -------------------------------------------------------------------
  // Play records — the same `game_results` ledger the crossword writes,
  // so the progress screen counts hunts with no code of its own.
  // -------------------------------------------------------------------

  Future<GameResultRow?> _playRow(int puzzleId) => (_db.select(_db.gameResults)
        ..where((t) => t.game.equals(_game) & t.refId.equals(puzzleId)))
      .getSingleOrNull();

  Future<void> startPlay(int puzzleId) async {
    await _db.into(_db.gameResults).insert(
          GameResultsCompanion.insert(
            game: _game,
            difficulty: const Value(_difficulty),
            refId: puzzleId,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<void> recordPlayTime(int puzzleId, int activeMs, {required bool aided}) async {
    await (_db.update(_db.gameResults)
          ..where((t) =>
              t.game.equals(_game) & t.refId.equals(puzzleId) & t.completedAt.isNull()))
        .write(GameResultsCompanion(activeMs: Value(activeMs), aided: Value(aided)));
  }

  Future<void> completePlay(int puzzleId, int activeMs, {required bool aided}) async {
    await (_db.update(_db.gameResults)
          ..where((t) =>
              t.game.equals(_game) & t.refId.equals(puzzleId) & t.completedAt.isNull()))
        .write(GameResultsCompanion(
          activeMs: Value(activeMs),
          aided: Value(aided),
          completedAt: Value(DateTime.now()),
        ));
  }

  // -------------------------------------------------------------------
  // History
  // -------------------------------------------------------------------

  Future<List<HuntHistoryEntry>> history({int limit = 60}) async {
    final rows = await (_db.select(_db.huntPuzzles)
          ..orderBy([(t) => OrderingTerm.desc(t.id)])
          ..limit(limit))
        .get();
    final ids = [for (final row in rows) row.id];
    final plays = {
      for (final p in await (_db.select(_db.gameResults)
            ..where((t) => t.game.equals(_game) & t.refId.isIn(ids)))
          .get())
        p.refId: p,
    };
    final earliestForDate = <String, int>{};
    for (final row in rows) {
      final current = earliestForDate[row.puzzleDate];
      if (current == null || row.id < current) earliestForDate[row.puzzleDate] = row.id;
    }

    return [
      for (final row in rows) _historyEntry(row, plays[row.id], earliestForDate[row.puzzleDate]),
    ];
  }

  HuntHistoryEntry _historyEntry(HuntPuzzleRow row, GameResultRow? play, int? earliestId) {
    String? themeLabel;
    var studyWords = 0;
    var foundRequired = 0;
    var requiredTotal = 0;
    var bonusFound = 0;
    var score = 0;
    final progress = _decodeProgress(row.progressJson);
    try {
      final puzzle = HuntPuzzle.fromJson(jsonDecode(row.puzzleJson) as Map<String, dynamic>);
      themeLabel = puzzle.themeLabel;
      studyWords = puzzle.studyAnchors.length;
      requiredTotal = puzzle.requiredCount;
      for (final word in progress.found) {
        switch (puzzle.classify(word)) {
          case HuntWordClass.anchor || HuntWordClass.main:
            foundRequired++;
          case HuntWordClass.bonus:
            bonusFound++;
          case null:
            break;
        }
      }
      score = huntScore(puzzle, progress.found);
    } catch (_) {
      // A row that won't decode still gets a history line.
    }
    return (
      id: row.id,
      date: row.puzzleDate,
      generatedAt: row.createdAt,
      themeLabel: themeLabel,
      studyWords: studyWords,
      isRegeneration: earliestId != row.id,
      play: (
        foundRequired: row.completed ? requiredTotal : foundRequired,
        requiredTotal: requiredTotal,
        bonusFound: bonusFound,
        score: score,
        completed: row.completed,
        aided: (play?.aided ?? false) || progress.revealed.isNotEmpty || progress.hinted,
        activeMs: play?.activeMs,
      ),
    );
  }
}

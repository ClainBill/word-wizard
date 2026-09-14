import 'package:drift/drift.dart';

import '../../domain/models/progress.dart';
import '../../domain/models/study_direction.dart';
import '../user/user_database.dart';
import 'study_repository.dart' show masteredClause;

/// Aggregates the user's activity into the numbers the progress surfaces
/// show, and owns the two ledgers nothing else writes: searches and lookups.
///
/// Nothing is stored pre-summed. Every figure is a query over an append-only
/// table, which is what makes "this week against last week" possible later
/// and what lets the numbers be recomputed if a definition changes. The
/// whole thing is local; when a server exists these tables sync up, they
/// don't move.
class ProgressRepository {
  final UserDatabase _db;

  ProgressRepository(this._db);

  /// Reviews on cards this far out count as mature for the retention
  /// figure — Anki's line, and the point past which a lapse means a memory
  /// was actually lost rather than never formed.
  static const matureIntervalDays = 21;

  // ---------------------------------------------------------------------
  // Ledgers
  // ---------------------------------------------------------------------

  /// Remembers a query for the recent-searches list. One row per distinct
  /// query, re-searching just moves it to the top.
  ///
  /// Re-inserted rather than updated in place so the row takes a fresh id:
  /// timestamps are stored to the second, and two searches in the same
  /// second would otherwise tie — the id is what "most recent" orders by.
  Future<void> logSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    await _db.transaction(() async {
      await (_db.delete(_db.searchLog)..where((t) => t.query.equals(q))).go();
      await _db.into(_db.searchLog).insert(SearchLogCompanion.insert(query: q));
    });
  }

  Stream<List<String>> watchRecentSearches({int limit = 12}) {
    return (_db.select(_db.searchLog)
          ..orderBy([(t) => OrderingTerm.desc(t.id)])
          ..limit(limit))
        .watch()
        .map((rows) => [for (final r in rows) r.query]);
  }

  Future<void> removeSearch(String query) =>
      (_db.delete(_db.searchLog)..where((t) => t.query.equals(query.trim()))).go();

  Future<void> clearSearches() => _db.delete(_db.searchLog).go();

  /// A word searched for and opened. Only the Search tab calls this — see
  /// [LookupLog] for why browsing to a word elsewhere doesn't count.
  Future<void> logLookup(int entryId, String headword) async {
    await _db.into(_db.lookupLog).insert(
          LookupLogCompanion.insert(entryId: entryId, headword: headword),
        );
  }

  // ---------------------------------------------------------------------
  // Aggregates
  // ---------------------------------------------------------------------

  /// The Study tab's bar. [directions] scopes the card states the same way
  /// the dashboard does, so a direction that is switched off doesn't hold a
  /// word back from "mastered".
  Stream<ProgressOverview> watchOverview(Set<StudyDirection> directions) {
    final filter = directions.isEmpty
        ? '1'
        : 'direction IN (${directions.map((d) => "'${d.storageKey}'").join(', ')})';
    return _db
        .customSelect(
          '''
          WITH per_word AS (
            SELECT entry_id,
              MIN(CASE WHEN $masteredClause THEN 1 ELSE 0 END) AS all_mastered,
              MAX(repetitions) AS max_reps
            FROM study_cards WHERE $filter GROUP BY entry_id
          )
          SELECT
            COALESCE(SUM(all_mastered), 0) AS mastered,
            COALESCE(SUM(CASE WHEN all_mastered = 0 AND max_reps >= 2 THEN 1 ELSE 0 END), 0)
              AS reviewing,
            COALESCE(SUM(CASE WHEN all_mastered = 0 AND max_reps < 2 THEN 1 ELSE 0 END), 0)
              AS learning,
            (SELECT COUNT(DISTINCT entry_id) FROM list_items
               WHERE entry_id NOT IN (SELECT entry_id FROM study_cards)) AS unstudied
          FROM per_word
          ''',
          readsFrom: {_db.studyCards, _db.listItems},
        )
        .watchSingle()
        .map((r) => ProgressOverview(
              mastered: r.read<int>('mastered'),
              reviewing: r.read<int>('reviewing'),
              learning: r.read<int>('learning'),
              unstudied: r.read<int>('unstudied'),
            ));
  }

  /// Everything on the progress screen. Re-emits whenever any table it
  /// reads changes; the work is a handful of small aggregate queries, so a
  /// refresh per review is fine.
  Stream<ProgressSummary> watchSummary(Set<StudyDirection> directions) {
    return _db
        .customSelect(
          'SELECT 1',
          readsFrom: {
            _db.studyCards,
            _db.listItems,
            _db.reviewLog,
            _db.gameResults,
            _db.lookupLog,
            _db.readerDocuments,
            _db.entryNotes,
          },
        )
        .watch()
        .asyncMap((_) => _loadSummary(directions));
  }

  Future<ProgressSummary> _loadSummary(Set<StudyDirection> directions) async {
    final overview = await watchOverview(directions).first;

    final study = await _db.customSelect(
      '''
      SELECT
        COUNT(*) AS reviews,
        COALESCE(SUM(duration_ms), 0) AS study_ms,
        SUM(CASE WHEN prior_interval >= $matureIntervalDays THEN 1 ELSE 0 END) AS mature,
        SUM(CASE WHEN prior_interval >= $matureIntervalDays AND grade > 0 THEN 1 ELSE 0 END)
          AS mature_ok
      FROM review_log
      ''',
    ).getSingle();
    final mature = study.read<int?>('mature') ?? 0;
    final matureOk = study.read<int?>('mature_ok') ?? 0;

    final days = await _db.customSelect(
      '''
      SELECT COUNT(*) AS active_days, MIN(d) AS first_day FROM (
        SELECT DISTINCT date(reviewed_at, 'unixepoch', 'localtime') AS d FROM review_log
        UNION
        SELECT DISTINCT date(looked_up_at, 'unixepoch', 'localtime') FROM lookup_log
        UNION
        SELECT DISTINCT date(completed_at, 'unixepoch', 'localtime') FROM game_results
          WHERE completed_at IS NOT NULL
      )
      ''',
    ).getSingle();
    final firstDay = days.read<String?>('first_day');

    final lookups = await _db.customSelect(
      'SELECT COUNT(*) AS total, COUNT(DISTINCT entry_id) AS distinct_words FROM lookup_log',
    ).getSingle();

    final repeats = await _db.customSelect(
      '''
      SELECT l.entry_id, l.headword, COUNT(*) AS n, MAX(l.looked_up_at) AS last_at,
        EXISTS(SELECT 1 FROM study_cards s WHERE s.entry_id = l.entry_id) AS studying
      FROM lookup_log l
      GROUP BY l.entry_id
      HAVING n >= 2
      ORDER BY studying ASC, n DESC, last_at DESC
      LIMIT 8
      ''',
    ).get();

    final reader = await _db.customSelect(
      'SELECT COUNT(*) AS docs, COALESCE(SUM(word_count), 0) AS words FROM reader_documents',
    ).getSingle();

    final collecting = await _db.customSelect(
      '''
      SELECT
        (SELECT COUNT(DISTINCT entry_id) FROM list_items) AS list_words,
        (SELECT COUNT(*) FROM entry_notes WHERE length(trim(markdown)) > 0) AS notes
      ''',
    ).getSingle();

    return ProgressSummary(
      overview: overview,
      reviews: study.read<int>('reviews'),
      studyTime: Duration(milliseconds: study.read<int>('study_ms')),
      retention: mature == 0 ? null : matureOk / mature,
      activeDays: days.read<int>('active_days'),
      firstActivity: firstDay == null ? null : DateTime.parse(firstDay),
      games: await _gameStats(),
      lookups: lookups.read<int>('total'),
      distinctLookups: lookups.read<int>('distinct_words'),
      repeatLookups: [
        for (final r in repeats)
          RepeatLookup(
            entryId: r.read<int>('entry_id'),
            headword: r.read<String>('headword'),
            count: r.read<int>('n'),
            lastAt: DateTime.fromMillisecondsSinceEpoch(r.read<int>('last_at') * 1000),
            studying: r.read<int>('studying') == 1,
          ),
      ],
      readerDocuments: reader.read<int>('docs'),
      readerWords: reader.read<int>('words'),
      listWords: collecting.read<int>('list_words'),
      notes: collecting.read<int>('notes'),
    );
  }

  Future<List<GameDifficultyStats>> _gameStats() async {
    final groups = await _db.customSelect(
      '''
      SELECT game, difficulty,
        SUM(CASE WHEN completed_at IS NOT NULL THEN 1 ELSE 0 END) AS completed,
        SUM(CASE WHEN completed_at IS NOT NULL AND aided = 0 THEN 1 ELSE 0 END) AS clean,
        SUM(CASE WHEN completed_at IS NULL THEN 1 ELSE 0 END) AS unfinished,
        COALESCE(SUM(active_ms), 0) AS total_ms
      FROM game_results
      GROUP BY game, difficulty
      ''',
    ).get();
    if (groups.isEmpty) return const [];

    // Clean, timed finishes, for the medians. Rows backfilled from before
    // timing existed carry active_ms = 0 and are left out — a best of
    // 0:00 would be the first thing anyone noticed.
    final timed = await _db.customSelect(
      '''
      SELECT game, difficulty, active_ms FROM game_results
      WHERE completed_at IS NOT NULL AND aided = 0 AND active_ms > 0
      ORDER BY game, difficulty, active_ms
      ''',
    ).get();
    final timesByGroup = <String, List<int>>{};
    for (final r in timed) {
      timesByGroup
          .putIfAbsent('${r.read<String>('game')}/${r.read<String>('difficulty')}', () => [])
          .add(r.read<int>('active_ms'));
    }

    return [
      for (final g in groups)
        () {
          final game = g.read<String>('game');
          final difficulty = g.read<String>('difficulty');
          final times = timesByGroup['$game/$difficulty'] ?? const <int>[];
          return GameDifficultyStats(
            game: game,
            difficulty: difficulty,
            completed: g.read<int>('completed'),
            clean: g.read<int>('clean'),
            unfinished: g.read<int>('unfinished'),
            best: times.isEmpty ? null : Duration(milliseconds: times.first),
            median: times.isEmpty ? null : Duration(milliseconds: _median(times)),
            totalTime: Duration(milliseconds: g.read<int>('total_ms')),
          );
        }(),
    ];
  }

  static int _median(List<int> sorted) {
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) ~/ 2;
  }

  /// Per-day activity for the last [days] days, oldest first, every day
  /// present even when empty.
  Stream<List<ActivityDay>> watchActivity({int days = 84}) {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day).subtract(Duration(days: days - 1));
    final since = start.millisecondsSinceEpoch ~/ 1000;
    return _db
        .customSelect(
          '''
          SELECT d, SUM(r) AS r, SUM(l) AS l, SUM(g) AS g FROM (
            SELECT date(reviewed_at, 'unixepoch', 'localtime') AS d, COUNT(*) AS r, 0 AS l, 0 AS g
              FROM review_log WHERE reviewed_at >= $since GROUP BY d
            UNION ALL
            SELECT date(looked_up_at, 'unixepoch', 'localtime'), 0, COUNT(*), 0
              FROM lookup_log WHERE looked_up_at >= $since GROUP BY 1
            UNION ALL
            SELECT date(completed_at, 'unixepoch', 'localtime'), 0, 0, COUNT(*)
              FROM game_results WHERE completed_at IS NOT NULL AND completed_at >= $since
              GROUP BY 1
          ) GROUP BY d
          ''',
          readsFrom: {_db.reviewLog, _db.lookupLog, _db.gameResults},
        )
        .watch()
        .map((rows) {
          final byDay = {
            for (final r in rows)
              r.read<String>('d'): (
                reviews: r.read<int>('r'),
                lookups: r.read<int>('l'),
                games: r.read<int>('g'),
              ),
          };
          return [
            for (var i = 0; i < days; i++)
              () {
                final day = DateTime(start.year, start.month, start.day + i);
                final key = '${day.year.toString().padLeft(4, '0')}-'
                    '${day.month.toString().padLeft(2, '0')}-'
                    '${day.day.toString().padLeft(2, '0')}';
                final counts = byDay[key];
                return ActivityDay(
                  day: day,
                  reviews: counts?.reviews ?? 0,
                  lookups: counts?.lookups ?? 0,
                  games: counts?.games ?? 0,
                );
              }(),
          ];
        });
  }
}

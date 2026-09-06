import 'package:drift/drift.dart';

import '../../domain/models/reminder_word.dart';
import '../../domain/models/study_card.dart';
import '../../domain/models/study_card_summary.dart';
import '../../domain/models/study_dashboard.dart';
import '../../domain/srs/sm2.dart';
import '../user/user_database.dart';

// A card counts as mastered once it clears both SM-2 thresholds from the
// design doc's card lifecycle: interval >= 90 days and ease factor >= 2.5.
const _masteredClause = 'interval_days >= 90 AND ease_factor >= 2.5';

class StudyRepository {
  final UserDatabase _db;

  StudyRepository(this._db);

  Stream<int> watchDueCount() {
    return _db
        .customSelect(
          // Paused cards keep their SRS state but are excluded from "due" —
          // they're snoozed, not ready for review.
          //
          // "now" has to be computed on the SQL side, not bound as a Dart
          // `Variable.withDateTime(DateTime.now())`: this query re-runs
          // whenever study_cards changes, but a bound parameter is captured
          // once, when the stream is first built, and never refreshed — so
          // a card added minutes after the dashboard first subscribed would
          // be compared against a stale "now" from before it existed and
          // never show up as due until the app restarted. `strftime` is
          // evaluated fresh on every run. It's CAST to INTEGER because
          // `due_at` is stored as a unix-epoch integer by drift, and
          // comparing it against SQLite's own CURRENT_TIMESTAMP-style TEXT
          // would always be true regardless of the actual date, since
          // SQLite's type-affinity ordering ranks every INTEGER below every
          // TEXT value.
          "SELECT COUNT(*) AS c FROM study_cards "
          "WHERE due_at <= CAST(strftime('%s', 'now') AS INTEGER) AND paused = 0",
          readsFrom: {_db.studyCards},
        )
        .watchSingle()
        .map((r) => r.read<int>('c'));
  }

  /// Adds an entry to the study pool if it isn't already in it. The new
  /// card is immediately due, matching renzo's "+ Study" behavior.
  Future<void> ensureCard(int entryId) {
    return _db.into(_db.studyCards).insert(
          StudyCardsCompanion.insert(entryId: entryId),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<bool> isStudying(int entryId) async {
    final row = await (_db.select(_db.studyCards)
          ..where((t) => t.entryId.equals(entryId)))
        .getSingleOrNull();
    return row != null;
  }

  Future<List<StudyCard>> dueQueue({int? listId, int limit = 50}) async {
    final now = Variable.withDateTime(DateTime.now());
    final rows = await _db
        .customSelect(
          listId == null
              ? '''
                SELECT sc.id AS card_id, sc.entry_id, sc.repetitions, sc.ease_factor,
                       sc.interval_days, sc.due_at, e.headword, e.pos, p.ipa, en.markdown AS note,
                  (SELECT gloss FROM dict.senses WHERE entry_id = e.id ORDER BY sense_order LIMIT 1) AS gloss,
                  (SELECT x.text FROM dict.examples x
                     JOIN dict.senses s2 ON s2.id = x.sense_id
                     WHERE s2.entry_id = e.id ORDER BY s2.sense_order LIMIT 1) AS example
                FROM study_cards sc
                JOIN dict.entries e ON e.id = sc.entry_id
                LEFT JOIN dict.pronunciations p ON p.entry_id = e.id
                LEFT JOIN entry_notes en ON en.entry_id = sc.entry_id
                WHERE sc.due_at <= ? AND sc.paused = 0
                ORDER BY sc.due_at
                LIMIT ?
                '''
              : '''
                SELECT sc.id AS card_id, sc.entry_id, sc.repetitions, sc.ease_factor,
                       sc.interval_days, sc.due_at, e.headword, e.pos, p.ipa, en.markdown AS note,
                  (SELECT gloss FROM dict.senses WHERE entry_id = e.id ORDER BY sense_order LIMIT 1) AS gloss,
                  (SELECT x.text FROM dict.examples x
                     JOIN dict.senses s2 ON s2.id = x.sense_id
                     WHERE s2.entry_id = e.id ORDER BY s2.sense_order LIMIT 1) AS example
                FROM study_cards sc
                JOIN dict.entries e ON e.id = sc.entry_id
                JOIN list_items li ON li.entry_id = sc.entry_id AND li.list_id = ?
                LEFT JOIN dict.pronunciations p ON p.entry_id = e.id
                LEFT JOIN entry_notes en ON en.entry_id = sc.entry_id
                WHERE sc.due_at <= ? AND sc.paused = 0
                ORDER BY sc.due_at
                LIMIT ?
                ''',
          variables: listId == null
              ? [now, Variable.withInt(limit)]
              : [Variable.withInt(listId), now, Variable.withInt(limit)],
          readsFrom: {_db.studyCards, _db.listItems, _db.entryNotes},
        )
        .get();

    return rows.map(_rowToCard).toList();
  }

  /// Every non-paused card in the study pool regardless of due date — used
  /// to pad out the daily crossword when today's due queue alone isn't
  /// enough words for the requested puzzle size.
  Future<List<StudyCard>> allStudyingCards({int limit = 200}) async {
    final rows = await _db
        .customSelect(
          '''
          SELECT sc.id AS card_id, sc.entry_id, sc.repetitions, sc.ease_factor,
                 sc.interval_days, sc.due_at, e.headword, e.pos, p.ipa, en.markdown AS note,
            (SELECT gloss FROM dict.senses WHERE entry_id = e.id ORDER BY sense_order LIMIT 1) AS gloss,
            (SELECT x.text FROM dict.examples x
               JOIN dict.senses s2 ON s2.id = x.sense_id
               WHERE s2.entry_id = e.id ORDER BY s2.sense_order LIMIT 1) AS example
          FROM study_cards sc
          JOIN dict.entries e ON e.id = sc.entry_id
          LEFT JOIN dict.pronunciations p ON p.entry_id = e.id
          LEFT JOIN entry_notes en ON en.entry_id = sc.entry_id
          WHERE sc.paused = 0
          ORDER BY sc.due_at
          LIMIT ?
          ''',
          variables: [Variable.withInt(limit)],
          readsFrom: {_db.studyCards, _db.entryNotes},
        )
        .get();

    return rows.map(_rowToCard).toList();
  }

  /// Enrolls every word in [listId] into the study pool (skipping ones
  /// already there) so a whole list can be targeted for daily review at
  /// once, rather than requiring each word to be added individually first.
  /// Goes through the typed batch-insert API rather than a raw INSERT
  /// statement so drift's reactive watchers pick up the change immediately
  /// — see the comment on [setListPaused].
  Future<void> enrollList(int listId) async {
    final rows = await _db.customSelect(
      'SELECT entry_id FROM list_items WHERE list_id = ?',
      variables: [Variable.withInt(listId)],
      readsFrom: {_db.listItems},
    ).get();
    if (rows.isEmpty) return;
    await _db.batch((b) {
      b.insertAll(
        _db.studyCards,
        [for (final r in rows) StudyCardsCompanion.insert(entryId: r.read<int>('entry_id'))],
        mode: InsertMode.insertOrIgnore,
      );
    });
  }

  StudyCard _rowToCard(QueryRow r) {
    return StudyCard(
      cardId: r.read<int>('card_id'),
      entryId: r.read<int>('entry_id'),
      headword: r.read<String>('headword'),
      pos: r.read<String>('pos'),
      ipa: r.readNullable<String>('ipa'),
      gloss: r.readNullable<String>('gloss'),
      example: r.readNullable<String>('example'),
      note: r.readNullable<String>('note'),
      srs: StudyCardState(
        repetitions: r.read<int>('repetitions'),
        easeFactor: r.read<double>('ease_factor'),
        intervalDays: r.read<int>('interval_days'),
      ),
      dueAt: r.read<DateTime>('due_at'),
    );
  }

  /// Picks one random word due within the next 24h — for the daily
  /// notification, which wants variety rather than always the same
  /// earliest-due card. Returns null if nothing is due that soon.
  Future<ReminderWord?> pickReminderWord() async {
    final rows = await _db
        .customSelect(
          '''
          SELECT e.headword,
            (SELECT gloss FROM dict.senses WHERE entry_id = e.id ORDER BY sense_order LIMIT 1) AS gloss,
            (SELECT x.text FROM dict.examples x
               JOIN dict.senses s2 ON s2.id = x.sense_id
               WHERE s2.entry_id = e.id ORDER BY s2.sense_order LIMIT 1) AS example
          FROM study_cards sc
          JOIN dict.entries e ON e.id = sc.entry_id
          WHERE sc.due_at <= ? AND sc.paused = 0
          ORDER BY RANDOM()
          LIMIT 1
          ''',
          variables: [Variable.withDateTime(DateTime.now().add(const Duration(days: 1)))],
          readsFrom: {_db.studyCards},
        )
        .getSingleOrNull();
    if (rows == null) return null;
    final gloss = rows.readNullable<String>('gloss');
    if (gloss == null) return null;
    return ReminderWord(
      headword: rows.read<String>('headword'),
      meaning: gloss,
      example: rows.readNullable<String>('example'),
    );
  }

  Stream<StudyDashboardStats> watchStats() {
    return _db
        .customSelect(
          '''
          SELECT
            (SELECT COUNT(*) FROM study_cards
               WHERE due_at <= CAST(strftime('%s', 'now') AS INTEGER) AND paused = 0) AS due_today,
            (SELECT COUNT(*) FROM study_cards WHERE $_masteredClause) AS mastered,
            (SELECT COUNT(*) FROM study_cards
               WHERE NOT ($_masteredClause) AND repetitions < 2) AS learning,
            (SELECT COUNT(*) FROM study_cards
               WHERE NOT ($_masteredClause) AND repetitions >= 2) AS reviewing,
            (SELECT COUNT(*) FROM study_cards) AS total
          ''',
          // See watchDueCount for why "now" is computed in SQL rather than
          // bound as a Dart parameter — same staleness bug applies here.
          readsFrom: {_db.studyCards},
        )
        .watchSingle()
        .map((r) => StudyDashboardStats(
              dueToday: r.read<int>('due_today'),
              mastered: r.read<int>('mastered'),
              learning: r.read<int>('learning'),
              reviewing: r.read<int>('reviewing'),
              total: r.read<int>('total'),
            ));
  }

  /// Cards due per day for the next [days] days (today = index 0). Anything
  /// already overdue folds into today's bucket rather than being dropped,
  /// since it will surface in the same session as today's cards. Paused
  /// cards never show up here — they won't actually come due on their own.
  Stream<List<int>> watchForecast({int days = 14}) {
    return _db
        .customSelect(
          "SELECT date(due_at, 'unixepoch', 'localtime') AS d, COUNT(*) AS c "
          "FROM study_cards WHERE paused = 0 GROUP BY d",
          readsFrom: {_db.studyCards},
        )
        .watch()
        .map((rows) {
          final today = DateTime.now();
          final todayDate = DateTime(today.year, today.month, today.day);
          final result = List<int>.filled(days, 0);
          for (final r in rows) {
            final d = DateTime.parse(r.read<String>('d'));
            final c = r.read<int>('c');
            final offset = d.difference(todayDate).inDays;
            if (offset < 0) {
              result[0] += c;
            } else if (offset < days) {
              result[offset] += c;
            }
          }
          return result;
        });
  }

  /// Consecutive days, ending today or yesterday, with at least one review
  /// logged. A gap of two or more days resets the streak to zero; today not
  /// yet having a review doesn't break a streak still active as of
  /// yesterday.
  Stream<int> watchStreak() {
    return _db
        .customSelect(
          "SELECT DISTINCT date(reviewed_at, 'unixepoch', 'localtime') AS d "
          "FROM review_log ORDER BY d DESC",
          readsFrom: {_db.reviewLog},
        )
        .watch()
        .map((rows) {
          if (rows.isEmpty) return 0;
          final reviewedDays = rows.map((r) => DateTime.parse(r.read<String>('d'))).toSet();
          final today = DateTime.now();
          final todayDate = DateTime(today.year, today.month, today.day);
          final yesterday = todayDate.subtract(const Duration(days: 1));

          var cursor = reviewedDays.contains(todayDate)
              ? todayDate
              : reviewedDays.contains(yesterday)
                  ? yesterday
                  : null;
          if (cursor == null) return 0;

          var streak = 0;
          while (reviewedDays.contains(cursor)) {
            streak++;
            cursor = cursor!.subtract(const Duration(days: 1));
          }
          return streak;
        });
  }

  Future<void> grade(StudyCard card, Grade grade) async {
    final update = gradeCard(card.srs, grade);
    await _db.batch((b) {
      b.update(
        _db.studyCards,
        StudyCardsCompanion(
          repetitions: Value(update.state.repetitions),
          easeFactor: Value(update.state.easeFactor),
          intervalDays: Value(update.state.intervalDays),
          dueAt: Value(update.dueAt),
        ),
        where: (t) => t.id.equals(card.cardId),
      );
      b.insert(
        _db.reviewLog,
        ReviewLogCompanion.insert(
          cardId: card.cardId,
          grade: grade.q,
          priorInterval: card.srs.intervalDays,
        ),
      );
    });
  }

  // ---------------------------------------------------------------------
  // SRS management: browsing every word in the pool, its history, and
  // resetting/pausing/removing it (individually or for a whole list).
  // ---------------------------------------------------------------------

  /// Every word currently in the study pool, newest-added first, with a
  /// review count for the "how many times has this been reviewed" summary.
  Stream<List<StudyCardSummary>> watchAllCards() {
    return _db
        .customSelect(
          '''
          SELECT sc.id AS card_id, sc.entry_id, sc.repetitions, sc.ease_factor,
                 sc.interval_days, sc.due_at, sc.created_at, sc.paused, e.headword, e.pos,
            (SELECT COUNT(*) FROM review_log rl WHERE rl.card_id = sc.id) AS review_count
          FROM study_cards sc
          JOIN dict.entries e ON e.id = sc.entry_id
          ORDER BY sc.created_at DESC
          ''',
          readsFrom: {_db.studyCards},
        )
        .watch()
        .map((rows) => rows
            .map((r) => StudyCardSummary(
                  cardId: r.read<int>('card_id'),
                  entryId: r.read<int>('entry_id'),
                  headword: r.read<String>('headword'),
                  pos: r.read<String>('pos'),
                  createdAt: r.read<DateTime>('created_at'),
                  dueAt: r.read<DateTime>('due_at'),
                  paused: r.read<bool>('paused'),
                  reviewCount: r.read<int>('review_count'),
                  srs: StudyCardState(
                    repetitions: r.read<int>('repetitions'),
                    easeFactor: r.read<double>('ease_factor'),
                    intervalDays: r.read<int>('interval_days'),
                  ),
                ))
            .toList());
  }

  /// Full grading history for one card, most recent first.
  Stream<List<ReviewLogEntry>> watchReviewHistory(int cardId) {
    return (_db.select(_db.reviewLog)
          ..where((t) => t.cardId.equals(cardId))
          ..orderBy([(t) => OrderingTerm.desc(t.reviewedAt)]))
        .watch()
        .map((rows) => rows
            .map((r) => ReviewLogEntry(
                  reviewedAt: r.reviewedAt,
                  grade: GradeFromQuality.fromQ(r.grade),
                  priorInterval: r.priorInterval,
                ))
            .toList());
  }

  /// Wipes a card's review history and SRS progress, putting it back to
  /// brand-new (immediately due), the same way Anki's "forget card" works.
  /// Leaves its paused flag untouched — resetting and pausing are
  /// independent actions.
  Future<void> resetCard(int cardId) async {
    await _db.batch((b) {
      b.deleteWhere(_db.reviewLog, (t) => t.cardId.equals(cardId));
      b.update(
        _db.studyCards,
        StudyCardsCompanion(
          repetitions: const Value(0),
          easeFactor: const Value(2.5),
          intervalDays: const Value(0),
          dueAt: Value(DateTime.now()),
        ),
        where: (t) => t.id.equals(cardId),
      );
    });
  }

  Future<void> setPaused(int cardId, bool paused) {
    return (_db.update(_db.studyCards)..where((t) => t.id.equals(cardId)))
        .write(StudyCardsCompanion(paused: Value(paused)));
  }

  /// Removes a word from the SRS pool entirely, along with its review
  /// history. The word itself, its list memberships, and its notes are
  /// untouched — this only un-enrolls it from studying.
  Future<void> removeCard(int cardId) async {
    await _db.batch((b) {
      b.deleteWhere(_db.reviewLog, (t) => t.cardId.equals(cardId));
      b.deleteWhere(_db.studyCards, (t) => t.id.equals(cardId));
    });
  }

  Future<void> resetListCards(int listId) async {
    final cardIds = await _cardIdsForList(listId);
    if (cardIds.isEmpty) return;
    await _db.batch((b) {
      for (final id in cardIds) {
        b.deleteWhere(_db.reviewLog, (t) => t.cardId.equals(id));
      }
      b.update(
        _db.studyCards,
        StudyCardsCompanion(
          repetitions: const Value(0),
          easeFactor: const Value(2.5),
          intervalDays: const Value(0),
          dueAt: Value(DateTime.now()),
        ),
        where: (t) => t.id.isIn(cardIds),
      );
    });
  }

  // Goes through the typed `update().write()` API (like the single-card
  // setPaused above) rather than a raw customStatement — drift only
  // notifies reactive watchers (dueQueue, watchStats, etc.) of writes made
  // through its own query builders, not of hand-written SQL statements.
  Future<void> setListPaused(int listId, bool paused) async {
    final cardIds = await _cardIdsForList(listId);
    if (cardIds.isEmpty) return;
    await (_db.update(_db.studyCards)..where((t) => t.id.isIn(cardIds)))
        .write(StudyCardsCompanion(paused: Value(paused)));
  }

  Future<void> removeListCards(int listId) async {
    final cardIds = await _cardIdsForList(listId);
    if (cardIds.isEmpty) return;
    await _db.batch((b) {
      for (final id in cardIds) {
        b.deleteWhere(_db.reviewLog, (t) => t.cardId.equals(id));
      }
      b.deleteWhere(_db.studyCards, (t) => t.id.isIn(cardIds));
    });
  }

  Future<List<int>> _cardIdsForList(int listId) async {
    final rows = await _db.customSelect(
      '''
      SELECT sc.id FROM study_cards sc
      JOIN list_items li ON li.entry_id = sc.entry_id
      WHERE li.list_id = ?
      ''',
      variables: [Variable.withInt(listId)],
      readsFrom: {_db.studyCards, _db.listItems},
    ).get();
    return rows.map((r) => r.read<int>('id')).toList();
  }
}

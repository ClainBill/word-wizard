import 'dart:math';

import 'package:drift/drift.dart';

import '../../domain/board/word_board.dart' show Familiarity;
import '../../domain/models/entry.dart';
import '../../domain/models/reminder_word.dart';
import '../../domain/models/study_card.dart';
import '../../domain/models/study_card_summary.dart';
import '../../domain/models/study_dashboard.dart';
import '../../domain/models/study_direction.dart';
import '../../domain/srs/sm2.dart';
import '../user/user_database.dart';
import 'lexicon_sql.dart';
import 'list_hierarchy.dart';

// A card counts as mastered once it clears both SM-2 thresholds from the
// design doc's card lifecycle: interval >= 90 days and ease factor >= 2.5.
const masteredClause = 'interval_days >= 90 AND ease_factor >= 2.5';

/// Cards whose direction the user currently has switched off are excluded
/// the same way paused ones are: they keep every bit of their SM-2 state and
/// review history, they just stop being queued, counted or forecast. That's
/// what makes turning "both ways" on and back off a free, reversible
/// experiment rather than a decision that throws away scheduling.
///
/// [alias] is the table alias in the query being built (empty for an
/// unaliased `study_cards`). The values interpolated are
/// [StudyDirection.storageKey] constants, never anything user-supplied.
String _directionFilter(Set<StudyDirection> directions, {String alias = ''}) {
  final prefix = alias.isEmpty ? '' : '$alias.';
  final keys = directions.map((d) => "'${d.storageKey}'").join(', ');
  return '${prefix}direction IN ($keys)';
}

/// What the user has decided about one word's meanings — see [StudySenses].
class SenseChoices {
  final Set<int> pinned;
  final Set<int> excluded;

  const SenseChoices({required this.pinned, required this.excluded});

  static const none = SenseChoices(pinned: {}, excluded: {});
}

class StudyRepository {
  final UserDatabase _db;

  /// Source of the per-session sense draw — injectable so tests can pin it.
  final Random _random;

  StudyRepository(this._db, {Random? random}) : _random = random ?? Random();

  Stream<int> watchDueCount(Set<StudyDirection> directions) {
    if (directions.isEmpty) return Stream.value(0);
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
          "WHERE due_at <= CAST(strftime('%s', 'now') AS INTEGER) AND paused = 0 "
          "AND ${_directionFilter(directions)}",
          readsFrom: {_db.studyCards},
        )
        .watchSingle()
        .map((r) => r.read<int>('c'));
  }

  /// Adds an entry to the study pool if it isn't already in it, creating one
  /// card per requested direction. New cards are immediately due, matching
  /// renzo's "+ Study" behavior.
  Future<void> ensureCard(int entryId, Set<StudyDirection> directions) async {
    if (directions.isEmpty) return;
    await _db.batch((b) {
      b.insertAll(
        _db.studyCards,
        [
          for (final d in directions)
            StudyCardsCompanion.insert(entryId: entryId, direction: Value(d.storageKey)),
        ],
        mode: InsertMode.insertOrIgnore,
      );
    });
  }

  /// True if the word is in the study pool in *any* direction — the "Study"
  /// button is about the word, not about one of its cards.
  Future<bool> isStudying(int entryId) async {
    final row = await (_db.select(_db.studyCards)
          ..where((t) => t.entryId.equals(entryId)))
        .get();
    return row.isNotEmpty;
  }

  /// Backfills cards for every direction the user has switched on, for words
  /// already in the pool. Called whenever the direction setting changes.
  ///
  /// A newly created sibling inherits the *earliest* due date among the
  /// word's existing cards rather than becoming due immediately. Turning on
  /// "both ways" with 300 words already enrolled would otherwise dump 300
  /// brand-new reviews into today — the single fastest way to make someone
  /// abandon an SRS. Inheriting spreads the new direction across the
  /// schedule the word already has, so it arrives alongside a review you
  /// were going to do anyway.
  Future<void> syncDirections(Set<StudyDirection> directions) async {
    if (directions.isEmpty) return;
    final rows = await _db.customSelect(
      'SELECT entry_id, MIN(due_at) AS due_at FROM study_cards GROUP BY entry_id',
      readsFrom: {_db.studyCards},
    ).get();
    if (rows.isEmpty) return;

    // Goes through the typed batch-insert API rather than a raw
    // INSERT ... SELECT so drift's reactive watchers (the due count, the
    // dashboard, the forecast) see the change immediately — see the comment
    // on [setListPaused].
    await _db.batch((b) {
      b.insertAll(
        _db.studyCards,
        [
          for (final r in rows)
            for (final d in directions)
              StudyCardsCompanion.insert(
                entryId: r.read<int>('entry_id'),
                direction: Value(d.storageKey),
                dueAt: Value(r.read<DateTime>('due_at')),
              ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
    });
  }

  /// What a [StudyCard] is read from, over `study_cards sc` and
  /// [_cardJoins]. The word may be the dictionary's or one only the Slang
  /// Stack knows — see lexicon_sql.dart.
  static final _cardColumns = '''
    sc.id AS card_id, sc.entry_id, sc.direction, sc.repetitions, sc.ease_factor,
    sc.interval_days, sc.due_at, $lexHeadword AS headword, $lexPos AS pos, p.ipa, en.markdown AS note,
    ${lexFirstGloss('sc.entry_id')} AS gloss,
    ${lexFirstExample('sc.entry_id')} AS example''';

  static final _cardJoins = '''
    FROM study_cards sc
    ${lexJoins('sc.entry_id')}
    LEFT JOIN dict.pronunciations p ON p.entry_id = sc.entry_id
    LEFT JOIN entry_notes en ON en.entry_id = sc.entry_id''';

  /// [listId] may name a plain list or a folder — a folder pulls in every
  /// word nested inside it at any depth (see list_hierarchy.dart). Filters
  /// list membership with `EXISTS` rather than joining `list_items` directly:
  /// a folder's subtree can contain the same word via more than one nested
  /// list, and a join would duplicate that card in the queue once per match.
  Future<List<StudyCard>> dueQueue({
    required Set<StudyDirection> directions,
    int? listId,
    int limit = 50,
  }) async {
    if (directions.isEmpty) return const [];
    final now = Variable.withDateTime(DateTime.now());
    final filter = _directionFilter(directions, alias: 'sc');
    final rows = await _db
        .customSelect(
          listId == null
              ? '''
                SELECT $_cardColumns
                $_cardJoins
                WHERE sc.due_at <= ? AND sc.paused = 0 AND $filter AND $lexFound
                ORDER BY sc.due_at
                LIMIT ?
                '''
              : '''
                $listSubtreeCte
                SELECT $_cardColumns
                $_cardJoins
                WHERE sc.due_at <= ? AND sc.paused = 0 AND $filter AND $lexFound
                  AND EXISTS (
                    SELECT 1 FROM list_items li
                    WHERE li.entry_id = sc.entry_id AND li.list_id IN (SELECT id FROM list_subtree)
                  )
                ORDER BY sc.due_at
                LIMIT ?
                ''',
          variables: listId == null
              ? [now, Variable.withInt(limit)]
              : [Variable.withInt(listId), now, Variable.withInt(limit)],
          readsFrom: {_db.studyCards, _db.listItems, _db.entryNotes, _db.lists, _db.slangWords, _db.slangSenses},
        )
        .get();

    return spaceSiblings(await _applySenses(rows.map(_rowToCard).toList()));
  }

  // ---------------------------------------------------------------------
  // Which meanings a card carries.
  // ---------------------------------------------------------------------

  /// The sense ids the user pinned for [entryId] — empty means no pin, so
  /// the card draws one or two of the word's senses at random each review.
  Stream<Set<int>> watchChosenSenses(int entryId) =>
      watchSenseChoices(entryId).map((c) => c.pinned);

  /// Both of the user's decisions about a word's meanings: the ones pinned
  /// to the card and the ones kept off it.
  Stream<SenseChoices> watchSenseChoices(int entryId) {
    return (_db.select(_db.studySenses)..where((t) => t.entryId.equals(entryId)))
        .watch()
        .map((rows) => SenseChoices(
              pinned: {for (final r in rows) if (!r.excluded) r.senseId},
              excluded: {for (final r in rows) if (r.excluded) r.senseId},
            ));
  }

  /// Replaces the pinned senses for [entryId], keeping its exclusions. An
  /// empty set clears the pin and puts the card back on the random draw.
  Future<void> setChosenSenses(int entryId, Set<int> senseIds) async {
    final current = await watchSenseChoices(entryId).first;
    await setSenseChoices(entryId, pinned: senseIds, excluded: current.excluded);
  }

  /// Replaces every choice for [entryId]. A sense in both sets is treated
  /// as pinned — a pin is the more deliberate of the two gestures.
  Future<void> setSenseChoices(
    int entryId, {
    required Set<int> pinned,
    required Set<int> excluded,
  }) async {
    await _db.batch((b) {
      b.deleteWhere(_db.studySenses, (t) => t.entryId.equals(entryId));
      b.insertAll(
        _db.studySenses,
        [
          for (final id in pinned) StudySensesCompanion.insert(entryId: entryId, senseId: id),
          for (final id in excluded.difference(pinned))
            StudySensesCompanion.insert(
              entryId: entryId,
              senseId: id,
              excluded: const Value(true),
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
    });
  }

  /// Decides which meanings each card in the batch carries.
  ///
  /// A word the user pinned senses for gets exactly those. Any other word
  /// gets **one or two of its senses drawn at random** — across every POS
  /// row of the headword, the same set the entry screen shows — so a word
  /// with eight meanings isn't forever tested on whichever one the
  /// dictionary happened to list first. The draw happens once per batch,
  /// i.e. once per session, so the card is stable while it's on screen and
  /// different next time.
  ///
  /// Done as extra queries over the batch rather than inside each card
  /// query's SELECT: both the pin and the draw can span sibling POS rows and
  /// be several senses, neither of which a scalar subquery expresses well.
  /// Order within a card is the dictionary's own — the canonical entry's
  /// senses first, then any sibling POS row's — so a card reads the way the
  /// entry does.
  Future<List<StudyCard>> _applySenses(List<StudyCard> cards) async {
    if (cards.isEmpty) return cards;
    final entryIds = cards.map((c) => c.entryId).toSet().toList();
    final placeholders = entryIds.map((_) => '?').join(',');
    final variables = entryIds.map(Variable.withInt).toList();

    // The person's own Slang Stack meanings sort first, as they do on the
    // entry page; then the dictionary's, canonical row first.
    final pinnedRows = await _db
        .customSelect(
          '''
          SELECT ss.entry_id, s.id AS sense_id, s.gloss, s.pos,
                 0 AS k1, 0 AS k2, s.sense_order AS k3
          FROM study_senses ss
          JOIN slang_senses s ON s.id = ss.sense_id
          WHERE ss.entry_id IN ($placeholders) AND ss.excluded = 0
          UNION ALL
          SELECT ss.entry_id, s.id AS sense_id, s.gloss, e.pos,
                 CASE WHEN s.entry_id = ss.entry_id THEN 1 ELSE 2 END AS k1, s.entry_id AS k2,
                 s.sense_order AS k3
          FROM study_senses ss
          JOIN dict.senses s ON s.id = ss.sense_id
          JOIN dict.entries e ON e.id = s.entry_id
          WHERE ss.entry_id IN ($placeholders) AND ss.excluded = 0
          ORDER BY 1, k1, k2, k3
          ''',
          variables: [...variables, ...variables],
          readsFrom: {_db.studySenses, _db.slangSenses},
        )
        .get();
    final pinned = _groupSenses(pinnedRows, await _examplesFor(pinnedRows));

    final unpinnedIds = entryIds.where((id) => !pinned.containsKey(id)).toList();
    final drawn = <int, List<StudySense>>{};
    if (unpinnedIds.isNotEmpty) {
      final unpinnedPlaceholders = unpinnedIds.map((_) => '?').join(',');
      // Every sense of every entry row sharing the canonical row's headword
      // — the person's own Slang Stack meanings under that headword
      // included, and first — flagged where the user has excluded it.
      final unpinnedVars = unpinnedIds.map(Variable.withInt).toList();
      final rows = await _db
          .customSelect(
            '''
            WITH c(id, headword) AS (
              SELECT id, headword FROM dict.entries WHERE id IN ($unpinnedPlaceholders)
              UNION ALL
              SELECT id, headword FROM slang_words WHERE id IN ($unpinnedPlaceholders)
            )
            SELECT c.id AS entry_id, s.id AS sense_id, s.gloss, s.pos,
              EXISTS(SELECT 1 FROM study_senses ss
                     WHERE ss.entry_id = c.id AND ss.sense_id = s.id AND ss.excluded = 1) AS excluded,
              0 AS k1, 0 AS k2, s.sense_order AS k3
            FROM c
            JOIN slang_words w ON w.headword = c.headword
            JOIN slang_senses s ON s.word_id = w.id
            UNION ALL
            SELECT c.id AS entry_id, s.id AS sense_id, s.gloss, e.pos,
              EXISTS(SELECT 1 FROM study_senses ss
                     WHERE ss.entry_id = c.id AND ss.sense_id = s.id AND ss.excluded = 1) AS excluded,
              CASE WHEN e.id = c.id THEN 1 ELSE 2 END AS k1, e.id AS k2, s.sense_order AS k3
            FROM c
            JOIN dict.entries e ON e.headword = c.headword
            JOIN dict.senses s ON s.entry_id = e.id
            ORDER BY 1, k1, k2, k3
            ''',
            variables: [...unpinnedVars, ...unpinnedVars],
            readsFrom: {_db.studyCards, _db.studySenses, _db.slangWords, _db.slangSenses},
          )
          .get();
      final examples = await _examplesFor(rows);
      final all = _groupSenses(rows, examples);
      final allowed = _groupSenses([for (final r in rows) if (r.read<int>('excluded') == 0) r], examples);
      // A word with every meaning excluded still needs something on its
      // card — the exclusions are ignored rather than the card left blank.
      all.forEach((entryId, senses) {
        final pool = allowed[entryId] ?? const <StudySense>[];
        drawn[entryId] = drawSenses(pool.isEmpty ? senses : pool, _random);
      });
    }

    return [for (final c in cards) c.withSenses(pinned[c.entryId] ?? drawn[c.entryId] ?? const [])];
  }

  /// Every example of every sense in [senseRows], keyed by sense id and in
  /// dictionary order. All of them rather than the first: the card picks
  /// the one that can carry a recall game (see [StudyCard.example]), and
  /// the first is often a fragment or a period quote that can't.
  Future<Map<int, List<Example>>> _examplesFor(List<QueryRow> senseRows) async {
    final senseIds = senseRows.map((r) => r.read<int>('sense_id')).toSet().toList();
    if (senseIds.isEmpty) return const {};
    final placeholders = senseIds.map((_) => '?').join(',');
    final variables = senseIds.map(Variable.withInt).toList();
    final rows = await _db.customSelect(
      '''
      SELECT id, sense_id, text, source FROM dict.examples WHERE sense_id IN ($placeholders)
      UNION ALL
      SELECT id, sense_id, sentence, NULL FROM slang_examples WHERE sense_id IN ($placeholders)
      ORDER BY id
      ''',
      variables: [...variables, ...variables],
    ).get();
    final bySense = <int, List<Example>>{};
    for (final r in rows) {
      bySense.putIfAbsent(r.read<int>('sense_id'), () => []).add(Example(
            id: r.read<int>('id'),
            text: r.read<String>('text'),
            source: r.readNullable<String>('source'),
          ));
    }
    return bySense;
  }

  Map<int, List<StudySense>> _groupSenses(List<QueryRow> rows, Map<int, List<Example>> examples) {
    final byEntry = <int, List<StudySense>>{};
    for (final r in rows) {
      final senseId = r.read<int>('sense_id');
      byEntry.putIfAbsent(r.read<int>('entry_id'), () => []).add(StudySense(
            senseId: senseId,
            gloss: r.read<String>('gloss'),
            pos: r.read<String>('pos'),
            examples: examples[senseId] ?? const [],
          ));
    }
    return byEntry;
  }

  /// One or two of [senses] at random, kept in their original order. Two
  /// only when the word has at least two and a coin flip says so — a card
  /// that always showed two would be twice the reading for every review.
  ///
  /// Visible for testing.
  static List<StudySense> drawSenses(List<StudySense> senses, Random random) {
    if (senses.length <= 1) return senses;
    final count = random.nextBool() ? 2 : 1;
    final picked = (List.of(senses)..shuffle(random)).take(count).toSet();
    return [for (final s in senses) if (picked.contains(s)) s];
  }

  /// Drops sense choices for words no longer in the pool. A choice is a
  /// property of *studying* the word, so it goes when the last card does —
  /// re-adding the word later starts clean, the same as its review history.
  Future<void> _pruneChosenSenses() async {
    final enrolled = _db.selectOnly(_db.studyCards)..addColumns([_db.studyCards.entryId]);
    await (_db.delete(_db.studySenses)
          ..where((t) => t.entryId.isNotInQuery(enrolled)))
        .go();
  }

  /// Keeps a word's two directions from landing back to back in the queue.
  ///
  /// Both cards of a word usually come due on the same day, and answering
  /// "abstruse → ?" immediately after "? → abstruse" isn't a second
  /// retrieval — the answer is still on screen in your short-term memory, so
  /// the second card grades itself and its interval grows on evidence that
  /// doesn't exist. Anki calls the same problem sibling burying. This is the
  /// cheap version: keep the order otherwise intact, but pull a different
  /// word forward whenever the next card repeats the current one.
  ///
  /// Visible for testing.
  static List<StudyCard> spaceSiblings(List<StudyCard> cards) {
    final remaining = List.of(cards);
    final result = <StudyCard>[];
    while (remaining.isNotEmpty) {
      var pick = 0;
      if (result.isNotEmpty) {
        final lastEntry = result.last.entryId;
        if (remaining.first.entryId == lastEntry) {
          final alternative = remaining.indexWhere((c) => c.entryId != lastEntry);
          // -1 means every card left belongs to the same word; nothing to do
          // but take them in order.
          if (alternative != -1) pick = alternative;
        }
      }
      result.add(remaining.removeAt(pick));
    }
    return result;
  }

  /// Every non-paused card in the study pool regardless of due date — used
  /// to pad out the daily crossword when today's due queue alone isn't
  /// enough words for the requested puzzle size.
  Future<List<StudyCard>> allStudyingCards({
    Set<StudyDirection>? directions,
    int limit = 200,
  }) async {
    final filter = directions == null ? '' : 'AND ${_directionFilter(directions, alias: 'sc')}';
    final rows = await _db
        .customSelect(
          '''
          SELECT $_cardColumns
          $_cardJoins
          WHERE sc.paused = 0 $filter AND $lexFound
          ORDER BY sc.due_at
          LIMIT ?
          ''',
          variables: [Variable.withInt(limit)],
          readsFrom: {_db.studyCards, _db.entryNotes},
        )
        .get();

    return _applySenses(rows.map(_rowToCard).toList());
  }

  /// Enrolls every word in [listId] into the study pool (skipping ones
  /// already there) so a whole list — or, since [listId] may be a folder,
  /// everything nested inside it — can be targeted for daily review at once,
  /// rather than requiring each word to be added individually first. Goes
  /// through the typed batch-insert API rather than a raw INSERT statement so
  /// drift's reactive watchers pick up the change immediately — see the
  /// comment on [setListPaused].
  Future<void> enrollList(int listId, Set<StudyDirection> directions) async {
    if (directions.isEmpty) return;
    final rows = await _db.customSelect(
      '''
      $listSubtreeCte
      SELECT DISTINCT entry_id FROM list_items
      WHERE list_id IN (SELECT id FROM list_subtree)
      ''',
      variables: [Variable.withInt(listId)],
      readsFrom: {_db.listItems, _db.lists},
    ).get();
    if (rows.isEmpty) return;
    await _db.batch((b) {
      b.insertAll(
        _db.studyCards,
        [
          for (final r in rows)
            for (final d in directions)
              StudyCardsCompanion.insert(
                entryId: r.read<int>('entry_id'),
                direction: Value(d.storageKey),
              ),
        ],
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
      direction: StudyDirection.fromStorageKey(r.read<String>('direction')),
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
  ///
  /// Grouped by entry: a word studied both ways has two due cards but is
  /// still one word to be reminded about.
  Future<ReminderWord?> pickReminderWord() async {
    final rows = await _db
        .customSelect(
          '''
          SELECT $_cardColumns
          $_cardJoins
          WHERE sc.due_at <= ? AND sc.paused = 0 AND $lexFound
          GROUP BY sc.entry_id
          ORDER BY RANDOM()
          LIMIT 1
          ''',
          variables: [Variable.withDateTime(DateTime.now().add(const Duration(days: 1)))],
          readsFrom: {_db.studyCards},
        )
        .getSingleOrNull();
    if (rows == null) return null;
    // Through the same hydration as a session card, so the reminder talks
    // about the meaning the user chose to remember, not the dictionary's
    // first one.
    final card = (await _applySenses([_rowToCard(rows)])).single;
    final gloss = card.gloss;
    if (gloss == null) return null;
    return ReminderWord(headword: card.headword, meaning: gloss, example: card.example);
  }

  /// Dashboard counts. Card-level counts (due, mastered, learning,
  /// reviewing) cover only the directions currently switched on — they
  /// describe the workload you actually have. [StudyDashboardStats.total]
  /// deliberately counts *words*, not cards, so turning "both ways" on
  /// doesn't make it look like your vocabulary doubled overnight.
  Stream<StudyDashboardStats> watchStats(Set<StudyDirection> directions) {
    if (directions.isEmpty) {
      return Stream.value(
        const StudyDashboardStats(dueToday: 0, mastered: 0, learning: 0, reviewing: 0, total: 0),
      );
    }
    final filter = _directionFilter(directions);
    return _db
        .customSelect(
          '''
          SELECT
            (SELECT COUNT(*) FROM study_cards
               WHERE due_at <= CAST(strftime('%s', 'now') AS INTEGER) AND paused = 0
                 AND $filter) AS due_today,
            (SELECT COUNT(*) FROM study_cards WHERE $masteredClause AND $filter) AS mastered,
            (SELECT COUNT(*) FROM study_cards
               WHERE NOT ($masteredClause) AND repetitions < 2 AND $filter) AS learning,
            (SELECT COUNT(*) FROM study_cards
               WHERE NOT ($masteredClause) AND repetitions >= 2 AND $filter) AS reviewing,
            (SELECT COUNT(DISTINCT entry_id) FROM study_cards) AS total
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
  Stream<List<int>> watchForecast(Set<StudyDirection> directions, {int days = 14}) {
    if (directions.isEmpty) return Stream.value(List<int>.filled(days, 0));
    return _db
        .customSelect(
          "SELECT date(due_at, 'unixepoch', 'localtime') AS d, COUNT(*) AS c "
          "FROM study_cards WHERE paused = 0 AND ${_directionFilter(directions)} GROUP BY d",
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

  /// Reviews longer than this are logged as this long. Anki uses the same
  /// idea (its default is 60s): past a couple of minutes the card isn't
  /// being thought about, the phone has been put down.
  static const maxReviewDuration = Duration(minutes: 2);

  /// Applies [grade] to [card] and logs the review. Returns the resulting
  /// SM-2 state so the caller can tell the user when the card comes back
  /// without re-running the algorithm.
  ///
  /// [spent] is how long the card was on screen; omitted for reviews earned
  /// outside a session (a crossword solve), which have no meaningful time.
  Future<SrsUpdate> grade(StudyCard card, Grade grade, {Duration? spent}) async {
    final update = gradeCard(card.srs, grade);
    final durationMs = spent == null
        ? 0
        : (spent > maxReviewDuration ? maxReviewDuration : spent).inMilliseconds;
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
          durationMs: Value(durationMs),
        ),
      );
    });
    return update;
  }

  /// Takes back the last [grade] of [card]: the card's SM-2 state and due
  /// date go back to what [card] still carries from before the grade, and
  /// the review just logged is deleted. Only the most recent review of the
  /// card is removed — the session calls this right after grading, before
  /// anything else could have touched the card.
  Future<void> ungrade(StudyCard card) async {
    await _db.transaction(() async {
      await (_db.update(_db.studyCards)..where((t) => t.id.equals(card.cardId))).write(
        StudyCardsCompanion(
          repetitions: Value(card.srs.repetitions),
          easeFactor: Value(card.srs.easeFactor),
          intervalDays: Value(card.srs.intervalDays),
          dueAt: Value(card.dueAt),
        ),
      );
      final last = await (_db.select(_db.reviewLog)
            ..where((t) => t.cardId.equals(card.cardId))
            ..orderBy([(t) => OrderingTerm.desc(t.id)])
            ..limit(1))
          .getSingleOrNull();
      if (last != null) {
        await (_db.delete(_db.reviewLog)..where((t) => t.id.equals(last.id))).go();
      }
    });
  }

  /// Every word in the Lexery by headword, with how far along it is:
  /// mastered if any of its cards clears [masteredClause], studying
  /// otherwise. What the landing board tints its tiles by.
  Stream<Map<String, Familiarity>> watchFamiliarity() {
    return _db
        .customSelect(
          '''
          SELECT $lexHeadword AS headword, MAX(CASE WHEN $masteredClause THEN 1 ELSE 0 END) AS mastered
          FROM study_cards sc
          ${lexJoins('sc.entry_id')}
          WHERE $lexFound
          GROUP BY 1
          ''',
          readsFrom: {_db.studyCards, _db.slangWords},
        )
        .watch()
        .map(
          (rows) => {
            for (final r in rows)
              r.read<String>('headword'): r.read<int>('mastered') == 1
                  ? Familiarity.mastered
                  : Familiarity.studying,
          },
        );
  }

  // ---------------------------------------------------------------------
  // SRS management: browsing every word in the pool, its history, and
  // resetting/pausing/removing it (individually or for a whole list).
  // ---------------------------------------------------------------------

  /// Every card currently in the study pool — one row per (word,
  /// direction) — newest-added word first, with a review count for the "how
  /// many times has this been reviewed" summary.
  ///
  /// Sorted by *when the word was first enrolled*, not by each card's own
  /// `created_at`, so a word's two directions stay next to each other. They
  /// don't necessarily share a creation time: a reverse card backfilled by
  /// [syncDirections] months later would otherwise sort into its own block
  /// at the top of the list, separated from the card it belongs with.
  Stream<List<StudyCardSummary>> watchAllCards() {
    return _db
        .customSelect(
          '''
          SELECT sc.id AS card_id, sc.entry_id, sc.direction, sc.repetitions, sc.ease_factor,
                 sc.interval_days, sc.due_at, sc.created_at, sc.paused,
                 $lexHeadword AS headword, $lexPos AS pos,
            (SELECT COUNT(*) FROM review_log rl WHERE rl.card_id = sc.id) AS review_count
          FROM study_cards sc
          ${lexJoins('sc.entry_id')}
          WHERE $lexFound
          ORDER BY (SELECT MIN(s2.created_at) FROM study_cards s2
                     WHERE s2.entry_id = sc.entry_id) DESC,
                   sc.entry_id, sc.direction
          ''',
          readsFrom: {_db.studyCards, _db.slangWords, _db.slangSenses},
        )
        .watch()
        .map((rows) => rows
            .map((r) => StudyCardSummary(
                  cardId: r.read<int>('card_id'),
                  entryId: r.read<int>('entry_id'),
                  headword: r.read<String>('headword'),
                  pos: r.read<String>('pos'),
                  direction: StudyDirection.fromStorageKey(r.read<String>('direction')),
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

  /// The interval a card jumps to when the person says they've mastered
  /// the word: past the mastered threshold, and far enough that the check
  /// review is a real one.
  static const masteredIntervalDays = 120;

  /// "I know this one cold": every direction of the word goes straight to
  /// mastered — interval [masteredIntervalDays], ease at least 2.6 — and
  /// comes back for a single check review then. Logged as an Easy review
  /// on each card so the history says why the interval jumped. Not a
  /// removal: a failed check review brings it back like any other card.
  Future<void> masterEntry(int entryId) async {
    final cards = await (_db.select(_db.studyCards)..where((t) => t.entryId.equals(entryId)))
        .get();
    final dueAt = DateTime.now().add(const Duration(days: masteredIntervalDays));
    await _db.batch((b) {
      for (final card in cards) {
        b.update(
          _db.studyCards,
          StudyCardsCompanion(
            repetitions: Value(card.repetitions < 5 ? 5 : card.repetitions),
            easeFactor: Value(card.easeFactor < 2.6 ? 2.6 : card.easeFactor),
            intervalDays: const Value(masteredIntervalDays),
            dueAt: Value(dueAt),
            paused: const Value(false),
          ),
          where: (t) => t.id.equals(card.id),
        );
        b.insert(
          _db.reviewLog,
          ReviewLogCompanion.insert(
            cardId: card.id,
            grade: Grade.easy.q,
            priorInterval: card.intervalDays,
          ),
        );
      }
    });
  }

  Future<void> setPaused(int cardId, bool paused) {
    return (_db.update(_db.studyCards)..where((t) => t.id.equals(cardId)))
        .write(StudyCardsCompanion(paused: Value(paused)));
  }

  /// Removes one card — one word in one direction — along with its review
  /// history. The word's other direction, if it has one, is untouched.
  Future<void> removeCard(int cardId) async {
    await _db.batch((b) {
      b.deleteWhere(_db.reviewLog, (t) => t.cardId.equals(cardId));
      b.deleteWhere(_db.studyCards, (t) => t.id.equals(cardId));
    });
    await _pruneChosenSenses();
  }

  /// Removes a word from the SRS pool entirely — every direction, and their
  /// review history. The word itself, its list memberships, and its notes
  /// are untouched: this only un-enrols it from studying. This is what
  /// "remove from study" means to someone looking at a word, as opposed to
  /// [removeCard], which is about one scheduled card.
  Future<void> removeEntry(int entryId) async {
    final ids = await (_db.select(_db.studyCards)..where((t) => t.entryId.equals(entryId)))
        .get()
        .then((rows) => rows.map((r) => r.id).toList());
    if (ids.isEmpty) return;
    await _db.batch((b) {
      b.deleteWhere(_db.reviewLog, (t) => t.cardId.isIn(ids));
      b.deleteWhere(_db.studyCards, (t) => t.id.isIn(ids));
    });
    await _pruneChosenSenses();
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
    await _pruneChosenSenses();
  }

  /// Cards for every word in [listId] — a plain list, or, since a folder's
  /// subtree is resolved the same way as everywhere else in this class, a
  /// folder. `EXISTS` rather than a join on `list_items` so a word reachable
  /// through two different nested lists doesn't yield its card id twice.
  Future<List<int>> _cardIdsForList(int listId) async {
    final rows = await _db.customSelect(
      '''
      $listSubtreeCte
      SELECT sc.id FROM study_cards sc
      WHERE EXISTS (
        SELECT 1 FROM list_items li
        WHERE li.entry_id = sc.entry_id AND li.list_id IN (SELECT id FROM list_subtree)
      )
      ''',
      variables: [Variable.withInt(listId)],
      readsFrom: {_db.studyCards, _db.listItems, _db.lists},
    ).get();
    return rows.map((r) => r.read<int>('id')).toList();
  }
}

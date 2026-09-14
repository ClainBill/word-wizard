import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'user_database.g.dart';

// Every table below gets an explicit @DataClassName: drift's default
// singularization of "Lists" produces a data class literally named `List`,
// shadowing dart:core's List across the generated file.

@DataClassName('ListRow')
class Lists extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  // 'custom' | 'curated' | 'folder'
  TextColumn get kind => text().withDefault(const Constant('custom'))();
  // Null means top-level. Only a 'folder' row may be pointed at — enforced in
  // ListRepository, not here, since SQLite has no CHECK-across-rows. A folder
  // can nest plain lists or other folders, arbitrarily deep, via this same
  // self-reference — see list_hierarchy.dart for how that subtree is walked.
  IntColumn get parentId => integer().nullable().references(Lists, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('ListItemRow')
class ListItems extends Table {
  IntColumn get listId => integer().references(Lists, #id)();
  IntColumn get entryId => integer()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {listId, entryId};
}

@DataClassName('StudyCardRow')
class StudyCards extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get entryId => integer()();

  /// Which way round this card is asked — [StudyDirection.storageKey],
  /// 'w2m' or 'm2w'.
  ///
  /// A word studied both ways has **two rows here**, not one row with a
  /// flag: recognising a meaning and producing a word are separate memories
  /// that are learned and forgotten at their own rates, so each needs its
  /// own repetitions/ease/interval/due date. Defaults to 'w2m', which is
  /// what every card was before the column existed.
  TextColumn get direction => text().withDefault(const Constant('w2m'))();

  IntColumn get repetitions => integer().withDefault(const Constant(0))();
  RealColumn get easeFactor => real().withDefault(const Constant(2.5))();
  IntColumn get intervalDays => integer().withDefault(const Constant(0))();
  DateTimeColumn get dueAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  // Paused cards keep their SRS progress but are skipped by the due queue,
  // dashboard "due" count, notification content, and forecast — a way to
  // snooze a word without losing history or fully removing it.
  BoolColumn get paused => boolean().withDefault(const Constant(false))();

  // Was a plain `unique()` on entryId, which is exactly what has to go for a
  // word to have one card per direction. Uniqueness is still what makes
  // "add this word to study" idempotent — it just applies per (word,
  // direction) pair now.
  @override
  List<Set<Column>> get uniqueKeys => [
        {entryId, direction},
      ];
}

/// Which of a word's dictionary senses its study card should carry.
///
/// A word like "muse" has eight meanings across two parts of speech; the
/// one you met in a book is usually not the first one listed, and a card
/// that shows the first one is a card for a different word than the one you
/// wanted to remember. Rows here pick the senses that matter, keyed by the
/// same canonical entry id [StudyCards] uses and the global `dict.senses.id`
/// — which may belong to a sibling POS row of the same headword, so it is
/// stored directly rather than as an order within the canonical entry.
///
/// No pinned rows for a word means no pin: the card draws one or two of the
/// word's senses at random each session instead — skipping any row marked
/// [excluded], which is the opposite gesture: "never ask me this one".
/// A sense is one or the other, never both.
@DataClassName('StudySenseRow')
class StudySenses extends Table {
  IntColumn get entryId => integer()();
  IntColumn get senseId => integer()();
  BoolColumn get excluded => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {entryId, senseId};
}

@DataClassName('ReviewLogRow')
class ReviewLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get cardId => integer().references(StudyCards, #id)();
  DateTimeColumn get reviewedAt => dateTime().withDefault(currentDateAndTime)();
  // 0=again 3=hard 4=good 5=easy — mirrors Grade.q
  IntColumn get grade => integer()();
  IntColumn get priorInterval => integer()();

  /// How long the card was on screen before it was graded, capped by the
  /// session screen so a phone left face-up on a desk doesn't log an hour of
  /// "study". 0 on rows written before the column existed and on reviews
  /// credited from outside a session (a crossword solve).
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
}

@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// One free-text, user-authored Markdown note per word (keyed by the same
/// canonical entry id used by [StudyCards] and [ListItems]). Shown on the
/// Entry Detail screen and, when non-empty, on the back of that word's SRS
/// study card too.
@DataClassName('EntryNoteRow')
class EntryNotes extends Table {
  IntColumn get entryId => integer()();
  TextColumn get markdown => text()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {entryId};
}

/// One *generated* puzzle for the Games tab's daily crossword.
///
/// Deliberately **not** unique on (day, difficulty). "Start new" used to
/// delete the day's row and insert a replacement, which made a regenerated
/// puzzle unobservable: the day still had exactly one history entry, and the
/// puzzle you had just compared against was gone. Each generation is now its
/// own row, today's puzzle is simply the newest row for today, and the
/// earlier attempts stay in history with their own progress and their own
/// editorial runs — which is what makes "regenerate and compare" work.
@DataClassName('CrosswordPuzzleRow')
class CrosswordPuzzles extends Table {
  IntColumn get id => integer().autoIncrement()();
  // 'YYYY-MM-DD', local date the puzzle belongs to.
  TextColumn get puzzleDate => text()();
  TextColumn get difficulty => text()();
  // Serialized CrosswordPuzzle (grid geometry + words + clues).
  TextColumn get gridJson => text()();
  // Serialized Map<String,String> of "row,col" -> filled letter.
  TextColumn get progressJson => text().withDefault(const Constant('{}'))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// What the user actually worked out for themselves, per puzzle.
///
/// The crossword's answer cooldown keys on this rather than on which answers
/// merely *appeared* recently — PORTING_SPEC.md §6.2a. The distinction is the
/// product: a puzzle opened and abandoned taught the user nothing, so
/// suppressing its answers for ten puzzles wastes ten puzzles' worth of
/// vocabulary; and an answer they only got by revealing cells was not
/// discovered either, so it must come back, because they still need to learn
/// it.
///
/// One row per played puzzle, updated as they play. Keyed on the puzzle row
/// rather than the day, so regenerating starts a fresh event and the earlier
/// attempt keeps its own record of what was worked out.
@DataClassName('CrosswordSolveEventRow')
class CrosswordSolveEvents extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The `crossword_puzzles` row this belongs to. 0 on rows migrated from
  /// when events were keyed by (day, difficulty) and no puzzle row matched.
  IntColumn get puzzleId => integer().withDefault(const Constant(0))();
  TextColumn get puzzleDate => text()();
  TextColumn get difficulty => text()();
  // JSON arrays of grid-form answers (A-Z only).
  TextColumn get solvedJson => text().withDefault(const Constant('[]'))();
  // Any answer with at least one revealed cell. An answer in both sets counts
  // as revealed: partial help still means it was not worked out.
  TextColumn get revealedJson => text().withDefault(const Constant('[]'))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// What one run of the crossword's editorial pass did, and what it cost.
///
/// **A debug/development table.** The editorial pass is the only part of the
/// app that spends money, and the only part whose output is not reproducible
/// from a seed, so while it is being tuned there has to be somewhere to see
/// what it actually did to each puzzle and what each run billed. Costs are
/// estimated locally from the token counts the API returns — see
/// `CrosswordReviewService.estimateCostUsd`.
///
/// One row per *run*, not per puzzle: regenerating a puzzle reviews it again,
/// and comparing those runs against each other is the point.
@DataClassName('CrosswordReviewLogRow')
class CrosswordReviewLog extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The `crossword_puzzles` row this run judged. 0 on rows written before
  /// puzzles were addressable individually.
  IntColumn get puzzleId => integer().withDefault(const Constant(0))();
  TextColumn get puzzleDate => text()();
  TextColumn get difficulty => text()();

  /// The seed of the puzzle that was reviewed — the same puzzle identity the
  /// generator uses, and what tells two runs of one day apart at a glance.
  IntColumn get puzzleSeed => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  TextColumn get model => text().withDefault(const Constant(''))();

  /// 'applied' | 'no_edits' | 'all_rejected' | 'failed' | 'not_applied'.
  TextColumn get outcome => text()();

  /// Empty unless [outcome] is 'failed' — the HTTP status, timeout or parse
  /// failure that ended the run.
  TextColumn get error => text().withDefault(const Constant(''))();

  IntColumn get latencyMs => integer().withDefault(const Constant(0))();

  IntColumn get promptTokens => integer().withDefault(const Constant(0))();

  /// Includes [reasoningTokens] — that is how the API bills it, so adding the
  /// two would double-count.
  IntColumn get completionTokens => integer().withDefault(const Constant(0))();
  IntColumn get reasoningTokens => integer().withDefault(const Constant(0))();

  /// Estimated, in US dollars, from a hardcoded price table. Stored rather
  /// than computed on read so a later price change doesn't silently rewrite
  /// what past runs appear to have cost.
  RealColumn get costUsd => real().withDefault(const Constant(0))();

  /// The reviewer's own 0-10 score for the puzzle, and its one-line reasoning.
  RealColumn get entertainment => real().withDefault(const Constant(0))();
  TextColumn get notes => text().withDefault(const Constant(''))();

  IntColumn get cluesProposed => integer().withDefault(const Constant(0))();
  IntColumn get cluesApplied => integer().withDefault(const Constant(0))();
  IntColumn get wordsProposed => integer().withDefault(const Constant(0))();
  IntColumn get wordsApplied => integer().withDefault(const Constant(0))();

  /// Every proposed edit as JSON: what it was, what it would have become,
  /// and whether it survived verification (§9.4) or which rule it broke.
  TextColumn get editsJson => text().withDefault(const Constant('[]'))();
}

/// Answers the editorial pass has rejected as unfair, kept out of every
/// future puzzle.
///
/// **A debug/development table**, and the cheapest thing in the project: the
/// reviewer is a fair judge of "would a learner know this word" and a poor
/// author of replacements, so it names bad fill and this remembers the
/// verdict. What accumulates here is a list worth folding back into
/// Crosswordler's own `CROSSWORDESE` set — the same job reader complaints did
/// by hand, done continuously.
///
/// It is the model's judgement, not a certification, which is why it is
/// inspectable and clearable from the history screen rather than silently
/// shrinking the word pool forever.
@DataClassName('CrosswordBannedAnswerRow')
class CrosswordBannedAnswers extends Table {
  /// Grid form, A-Z only.
  TextColumn get answer => text()();

  /// The reviewer's own words on why it is unfair.
  TextColumn get reason => text().withDefault(const Constant(''))();
  TextColumn get difficulty => text().withDefault(const Constant(''))();
  DateTimeColumn get bannedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {answer};
}

/// One generated Word Hunt board — the 4x4 letter grid with its certified
/// answer sets and the player's progress on it.
///
/// Same shape as [CrosswordPuzzles]: one row per *generation*, today's board
/// is the newest row for today, and "Start new" adds a row rather than
/// replacing one. The answer sets are frozen into [puzzleJson] at generation
/// time and never re-derived, so a dictionary update can't change what a
/// half-played board accepts (research contract §5).
@DataClassName('HuntPuzzleRow')
class HuntPuzzles extends Table {
  IntColumn get id => integer().autoIncrement()();
  // 'YYYY-MM-DD', local date the board belongs to.
  TextColumn get puzzleDate => text()();
  // Serialized HuntPuzzle: board, anchors, main/bonus answer maps, theme.
  TextColumn get puzzleJson => text()();
  // Serialized {"found": [...], "revealed": [...]} — words the player has
  // traced, and required words they gave up on and were shown.
  TextColumn get progressJson => text().withDefault(const Constant('{}'))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// One piece of text brought into the Reader tab — the history the tab
/// keeps, so something copied last week can be reopened with its words
/// still tappable and still marked against today's lists.
@DataClassName('ReaderDocumentRow')
class ReaderDocuments extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  // 'clipboard' | 'typed' — ReaderSource.name.
  TextColumn get source => text().withDefault(const Constant('clipboard'))();
  // Serialized List<ReaderBlock>: the text with its headings, quotes, list
  // items and bold/italic runs, so a copied page still looks like one.
  TextColumn get blocksJson => text()();
  // The opening ~160 characters, so the history list never has to decode
  // blocks_json just to show a snippet.
  TextColumn get preview => text().withDefault(const Constant(''))();
  // Fingerprint of the flattened text — what stops the same clipboard
  // contents becoming two history rows.
  TextColumn get contentHash => text()();
  IntColumn get wordCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  // Bumped on every open, for display.
  DateTimeColumn get openedAt => dateTime().withDefault(currentDateAndTime)();
  // What "most recently opened" actually orders by. Drift stores DateTimes
  // to the second, so a document reopened from history in the same second
  // another was pasted would tie on opened_at; this is one higher than the
  // previous maximum on every open, so the last thing opened always wins.
  IntColumn get openSeq => integer().withDefault(const Constant(0))();
}

/// One play of one game in the Games tab — what the progress screen counts
/// and times.
///
/// Deliberately generic: the crossword is the first writer, but any game
/// added later records itself the same way and the progress screen needs no
/// per-game code. Timing is **active** time — the screen in front and the
/// app in the foreground — accumulated by the game screen and flushed here
/// as it goes, because a puzzle saved on Monday and finished on Wednesday
/// did not take two days.
///
/// A row is created when the play starts and [completedAt] stays null until
/// it is finished, so an abandoned puzzle is visible as one. [aided] is set
/// if any cell was revealed: an aided time is not comparable to a clean one,
/// so personal bests only rank clean solves.
@DataClassName('GameResultRow')
class GameResults extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 'crossword' or 'hunt'.
  TextColumn get game => text()();
  TextColumn get difficulty => text().withDefault(const Constant(''))();

  /// The game's own row this play belongs to — a `crossword_puzzles` id.
  IntColumn get refId => integer()();
  DateTimeColumn get startedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get completedAt => dateTime().nullable()();
  IntColumn get activeMs => integer().withDefault(const Constant(0))();
  BoolColumn get aided => boolean().withDefault(const Constant(false))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {game, refId},
      ];
}

/// Queries typed into the Search tab — the tab's recent-searches list.
///
/// Kept apart from [LookupLog] on purpose: a search is not a lookup. Typing
/// "ser" and scrolling past the results taught nothing and counts for
/// nothing; it is remembered only so it can be re-run. One row per distinct
/// query (case-insensitive), its timestamp bumped on repeat.
@DataClassName('SearchLogRow')
class SearchLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get query => text()();
  DateTimeColumn get searchedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {query},
      ];
}

/// Words the user looked up: searched for on the Search tab and then opened.
///
/// Only that path writes here. Opening a word from a list, the reader or a
/// crossword clue is browsing, not looking up — it was already in front of
/// them. Append-only, so a word looked up three times shows up three times:
/// repeat lookups are the signal that a word belongs in study.
@DataClassName('LookupLogRow')
class LookupLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get entryId => integer()();
  TextColumn get headword => text()();

  /// 'search' — kept as a column so a later source can be told apart.
  TextColumn get source => text().withDefault(const Constant('search'))();
  DateTimeColumn get lookedUpAt => dateTime().withDefault(currentDateAndTime)();
}

@DriftDatabase(tables: [
  Lists,
  ListItems,
  StudyCards,
  StudySenses,
  ReviewLog,
  Settings,
  EntryNotes,
  CrosswordPuzzles,
  CrosswordSolveEvents,
  CrosswordReviewLog,
  CrosswordBannedAnswers,
  ReaderDocuments,
  HuntPuzzles,
  GameResults,
  SearchLog,
  LookupLog,
])
class UserDatabase extends _$UserDatabase {
  UserDatabase(super.e);

  @override
  int get schemaVersion => 15;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(entryNotes);
          }
          if (from < 3) {
            await m.addColumn(studyCards, studyCards.paused);
          }
          if (from < 4) {
            await m.createTable(crosswordPuzzles);
          }
          if (from < 5) {
            await m.createTable(crosswordSolveEvents);
          }
          if (from < 6) {
            await m.createTable(crosswordReviewLog);
          }
          if (from < 7) {
            // ignore: deprecated_member_use, experimental_member_use
            // TableMigration is drift's supported way to change a table's
            // constraints on SQLite, which has no DROP CONSTRAINT; it is
            // marked experimental but is the documented path.
            // Puzzles become individually addressable: the (day, difficulty)
            // unique constraint goes, so regenerating adds a row instead of
            // replacing one, and the things that point at a puzzle point at
            // its id.
            // ignore: experimental_member_use
            await m.alterTable(TableMigration(crosswordPuzzles));
            // ignore: experimental_member_use
            await m.alterTable(TableMigration(
              crosswordSolveEvents,
              newColumns: [crosswordSolveEvents.puzzleId],
            ));
            await m.addColumn(crosswordReviewLog, crosswordReviewLog.puzzleId);
            // Existing rows knew only which day they belonged to; point them
            // at that day's puzzle so their history survives the change.
            await m.database.customStatement(
              'UPDATE crossword_solve_events SET puzzle_id = COALESCE(('
              '  SELECT p.id FROM crossword_puzzles p'
              '  WHERE p.puzzle_date = crossword_solve_events.puzzle_date'
              '    AND p.difficulty = crossword_solve_events.difficulty), 0)',
            );
            await m.database.customStatement(
              'UPDATE crossword_review_log SET puzzle_id = COALESCE(('
              '  SELECT p.id FROM crossword_puzzles p'
              '  WHERE p.puzzle_date = crossword_review_log.puzzle_date'
              '    AND p.difficulty = crossword_review_log.difficulty), 0)',
            );
          }
          if (from < 8) {
            await m.createTable(crosswordBannedAnswers);
          }
          if (from < 9) {
            // Study cards gain a direction, and with it the ability for one
            // word to hold two independently-scheduled cards. That means
            // dropping the UNIQUE constraint on entry_id in favour of a
            // composite one over (entry_id, direction) — and SQLite has no
            // DROP CONSTRAINT, so the table is rebuilt from its current Dart
            // definition the same way crossword_puzzles was in v7. Existing
            // rows take the column default, 'w2m', which is the direction
            // they have always been asked in.
            // ignore: experimental_member_use
            await m.alterTable(TableMigration(
              studyCards,
              newColumns: [studyCards.direction],
            ));
          }
          if (from < 10) {
            // Folders: a plain nullable self-reference, so existing rows
            // (NULL = top-level) need no backfill.
            await m.addColumn(lists, lists.parentId);
          }
          if (from < 11) {
            await m.createTable(readerDocuments);
          }
          if (from < 12) {
            await m.createTable(studySenses);
          }
          if (from < 13) {
            // Progress tracking: reviews gain a duration, and the three
            // ledgers the progress screen aggregates. Existing reviews take
            // the 0 default — their time was never measured.
            await m.addColumn(reviewLog, reviewLog.durationMs);
            await m.createTable(gameResults);
            await m.createTable(searchLog);
            await m.createTable(lookupLog);
            // Puzzles finished before plays were recorded still count as
            // finished. Their time was never measured, so active_ms stays
            // 0 and they are left out of the bests; whether they were
            // aided is known from the solve events.
            await m.database.customStatement(
              'INSERT INTO game_results '
              '(game, difficulty, ref_id, started_at, completed_at, active_ms, aided) '
              "SELECT 'crossword', p.difficulty, p.id, p.created_at, p.created_at, 0, "
              '  EXISTS(SELECT 1 FROM crossword_solve_events e '
              "         WHERE e.puzzle_id = p.id AND e.revealed_json != '[]') "
              'FROM crossword_puzzles p WHERE p.completed = 1',
            );
          }
          if (from < 14) {
            // Existing rows are all pins — the only thing the table held.
            await m.addColumn(studySenses, studySenses.excluded);
          }
          if (from < 15) {
            await m.createTable(huntPuzzles);
          }
        },
      );

  static Future<UserDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'user.db'));
    return UserDatabase(NativeDatabase.createInBackground(file));
  }
}

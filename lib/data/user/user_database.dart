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
  // 'custom' | 'curated'
  TextColumn get kind => text().withDefault(const Constant('custom'))();
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
  IntColumn get entryId => integer().unique()();
  IntColumn get repetitions => integer().withDefault(const Constant(0))();
  RealColumn get easeFactor => real().withDefault(const Constant(2.5))();
  IntColumn get intervalDays => integer().withDefault(const Constant(0))();
  DateTimeColumn get dueAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  // Paused cards keep their SRS progress but are skipped by the due queue,
  // dashboard "due" count, notification content, and forecast — a way to
  // snooze a word without losing history or fully removing it.
  BoolColumn get paused => boolean().withDefault(const Constant(false))();
}

@DataClassName('ReviewLogRow')
class ReviewLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get cardId => integer().references(StudyCards, #id)();
  DateTimeColumn get reviewedAt => dateTime().withDefault(currentDateAndTime)();
  // 0=again 3=hard 4=good 5=easy — mirrors Grade.q
  IntColumn get grade => integer()();
  IntColumn get priorInterval => integer()();
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

@DriftDatabase(tables: [
  Lists,
  ListItems,
  StudyCards,
  ReviewLog,
  Settings,
  EntryNotes,
  CrosswordPuzzles,
  CrosswordSolveEvents,
  CrosswordReviewLog,
  CrosswordBannedAnswers,
])
class UserDatabase extends _$UserDatabase {
  UserDatabase(super.e);

  @override
  int get schemaVersion => 8;

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
        },
      );

  static Future<UserDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'user.db'));
    return UserDatabase(NativeDatabase.createInBackground(file));
  }
}

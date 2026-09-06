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

/// One generated puzzle per (day, difficulty) for the Games tab's daily
/// crossword — generated once, then reloaded with whatever progress the
/// user's saved so leaving and returning resumes where they left off.
@DataClassName('CrosswordPuzzleRow')
class CrosswordPuzzles extends Table {
  IntColumn get id => integer().autoIncrement()();
  // 'YYYY-MM-DD', local date — paired with [difficulty] as the puzzle's key.
  TextColumn get puzzleDate => text()();
  TextColumn get difficulty => text()();
  // Serialized CrosswordPuzzle (grid geometry + words + clues).
  TextColumn get gridJson => text()();
  // Serialized Map<String,String> of "row,col" -> filled letter.
  TextColumn get progressJson => text().withDefault(const Constant('{}'))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {puzzleDate, difficulty},
      ];
}

@DriftDatabase(tables: [Lists, ListItems, StudyCards, ReviewLog, Settings, EntryNotes, CrosswordPuzzles])
class UserDatabase extends _$UserDatabase {
  UserDatabase(super.e);

  @override
  int get schemaVersion => 4;

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
        },
      );

  static Future<UserDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'user.db'));
    return UserDatabase(NativeDatabase.createInBackground(file));
  }
}

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/repositories/backup_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';

/// A user database with the dictionary tables the backup reads attached,
/// holding [words] as (id, headword, [(senseId, gloss)]).
Future<UserDatabase> _device(List<(int, String, List<(int, String)>)> words) async {
  final db = UserDatabase(NativeDatabase.memory());
  await db.customStatement("ATTACH DATABASE ':memory:' AS dict");
  await db.customStatement(
    'CREATE TABLE dict.entries (id INTEGER PRIMARY KEY, headword TEXT NOT NULL, pos TEXT NOT NULL, '
    'frequency_rank INTEGER, etymology TEXT)',
  );
  await db.customStatement(
    'CREATE TABLE dict.senses (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, gloss TEXT NOT NULL, '
    'sense_order INTEGER NOT NULL)',
  );
  for (final (id, headword, senses) in words) {
    await db.customStatement(
      'INSERT INTO dict.entries (id, headword, pos, frequency_rank) VALUES (?, ?, ?, ?)',
      [id, headword, 'noun', 1000 + id],
    );
    for (final (i, (senseId, gloss)) in senses.indexed) {
      await db.customStatement(
        'INSERT INTO dict.senses (id, entry_id, gloss, sense_order) VALUES (?, ?, ?, ?)',
        [senseId, id, gloss, i],
      );
    }
  }
  return db;
}

const _dictionary = [
  (1, 'melody', [(11, 'a tune'), (12, 'the main part in music')]),
  (2, 'cadence', [(21, 'a rhythmic flow')]),
  (3, 'glint', [(31, 'a brief flash of light')]),
];

/// The same words after a dictionary rebuild: every id moved.
const _renumbered = [
  (101, 'melody', [(111, 'a tune'), (112, 'the main part in music')]),
  (102, 'cadence', [(121, 'a rhythmic flow')]),
  (103, 'glint', [(131, 'a brief flash of light')]),
];

Future<void> _fill(UserDatabase db) async {
  final folder = await db.into(db.lists).insert(ListsCompanion.insert(name: 'Exam prep', kind: const Value('folder')));
  final gre = await db
      .into(db.lists)
      .insert(ListsCompanion.insert(name: 'GRE', parentId: Value(folder)));
  await db.into(db.listItems).insert(ListItemsCompanion.insert(listId: gre, entryId: 1, note: const Value('from a novel')));
  await db.into(db.listItems).insert(ListItemsCompanion.insert(listId: gre, entryId: 2));
  final card = await db
      .into(db.studyCards)
      .insert(
        StudyCardsCompanion.insert(
          entryId: 1,
          repetitions: const Value(3),
          easeFactor: const Value(2.6),
          intervalDays: const Value(15),
          dueAt: Value(DateTime.utc(2026, 10, 10)),
        ),
      );
  await db.into(db.studyCards).insert(StudyCardsCompanion.insert(entryId: 1, direction: const Value('m2w')));
  for (final (day, grade) in [(1, 4), (7, 4), (20, 5)]) {
    await db
        .into(db.reviewLog)
        .insert(
          ReviewLogCompanion.insert(
            cardId: card,
            reviewedAt: Value(DateTime.utc(2026, 9, day)),
            grade: grade,
            priorInterval: day,
          ),
        );
  }
  await db.into(db.studySenses).insert(StudySensesCompanion.insert(entryId: 1, senseId: 12));
  await db.into(db.entryNotes).insert(EntryNotesCompanion.insert(entryId: const Value(2), markdown: 'think *cadenza*'));
}

void main() {
  test('a backup survives a JSON round trip onto a fresh device', () async {
    final a = await _device(_dictionary);
    await _fill(a);
    final file = jsonDecode(jsonEncode(await BackupRepository(a).export(appVersion: '1.0.0')));

    final summary = BackupRepository.summarize(file);
    expect((summary.lists, summary.listWords, summary.studyWords, summary.cards, summary.reviews, summary.notes),
        (2, 2, 1, 2, 3, 1));

    final b = await _device(_dictionary);
    final result = await BackupRepository(b).restore(file, replace: true);
    expect((result.lists, result.listWords, result.cards, result.reviews, result.notes, result.skippedWords),
        (2, 2, 2, 3, 1, 0));

    final gre = await (b.select(b.lists)..where((t) => t.name.equals('GRE'))).getSingle();
    final folder = await (b.select(b.lists)..where((t) => t.name.equals('Exam prep'))).getSingle();
    expect(gre.parentId, folder.id, reason: 'folders keep their children');
    expect(folder.kind, 'folder');
    final note = await (b.select(b.listItems)..where((t) => t.entryId.equals(1))).getSingle();
    expect(note.note, 'from a novel');

    final card = await (b.select(b.studyCards)..where((t) => t.direction.equals('w2m'))).getSingle();
    expect((card.entryId, card.repetitions, card.easeFactor, card.intervalDays), (1, 3, 2.6, 15));
    expect(card.dueAt.toUtc(), DateTime.utc(2026, 10, 10));
    expect((await b.select(b.reviewLog).get()).every((r) => r.cardId == card.id), isTrue);
    expect((await b.select(b.studySenses).getSingle()).senseId, 12);
    expect((await b.select(b.entryNotes).getSingle()).markdown, 'think *cadenza*');
    await a.close();
    await b.close();
  });

  test('a rebuilt dictionary with new ids: words and pinned meanings are found by headword and gloss', () async {
    final a = await _device(_dictionary);
    await _fill(a);
    final file = await BackupRepository(a).export(appVersion: '1.0.0');

    final b = await _device(_renumbered);
    final result = await BackupRepository(b).restore(file, replace: true);
    expect(result.skippedWords, 0);
    expect({for (final c in await b.select(b.studyCards).get()) c.entryId}, {101});
    expect({for (final i in await b.select(b.listItems).get()) i.entryId}, {101, 102});
    expect((await b.select(b.studySenses).getSingle()).senseId, 112);
    expect((await b.select(b.entryNotes).getSingle()).entryId, 102);
    await a.close();
    await b.close();
  });

  test('words the dictionary lacks are skipped and counted', () async {
    final a = await _device(_dictionary);
    await _fill(a);
    final file = await BackupRepository(a).export(appVersion: '1.0.0');
    final b = await _device([_dictionary[1]]); // only "cadence"
    final result = await BackupRepository(b).restore(file, replace: true);
    expect(result.skippedWords, 1, reason: '"melody" is gone');
    expect(result.cards, 0);
    expect(result.listWords, 1);
    await a.close();
    await b.close();
  });

  test('merging keeps this device\'s things, and the more recently reviewed card', () async {
    final a = await _device(_dictionary);
    await _fill(a);
    final file = await BackupRepository(a).export(appVersion: '1.0.0');

    final b = await _device(_dictionary);
    // Already here: the same GRE list with another word, and melody's
    // card reviewed later than the backup's last review.
    final gre = await b.into(b.lists).insert(ListsCompanion.insert(name: 'Other'));
    await b.into(b.listItems).insert(ListItemsCompanion.insert(listId: gre, entryId: 3));
    final mine = await b
        .into(b.studyCards)
        .insert(StudyCardsCompanion.insert(entryId: 1, repetitions: const Value(9)));
    await b
        .into(b.reviewLog)
        .insert(ReviewLogCompanion.insert(cardId: mine, reviewedAt: Value(DateTime.utc(2026, 9, 25)), grade: 4, priorInterval: 30));
    await b.into(b.entryNotes).insert(EntryNotesCompanion.insert(entryId: const Value(2), markdown: 'my own note'));

    await BackupRepository(b).restore(file, replace: false);
    expect((await b.select(b.lists).get()).map((l) => l.name).toSet(), {'Other', 'Exam prep', 'GRE'});
    expect((await b.select(b.listItems).get()), hasLength(3));
    final w2m = await (b.select(b.studyCards)..where((t) => t.direction.equals('w2m'))).getSingle();
    expect(w2m.repetitions, 9, reason: 'this device reviewed it more recently');
    expect(await (b.select(b.studyCards)..where((t) => t.direction.equals('m2w'))).getSingleOrNull(), isNotNull);
    expect((await b.select(b.entryNotes).getSingle()).markdown, 'my own note');

    // Merging the same file again adds nothing.
    await BackupRepository(b).restore(file, replace: false);
    expect(await b.select(b.lists).get(), hasLength(3));
    expect(await b.select(b.studyCards).get(), hasLength(2));
    await a.close();
    await b.close();
  });

  test('replacing clears what was on the device first', () async {
    final a = await _device(_dictionary);
    await _fill(a);
    final file = await BackupRepository(a).export(appVersion: '1.0.0');
    final b = await _device(_dictionary);
    final other = await b.into(b.lists).insert(ListsCompanion.insert(name: 'Other'));
    await b.into(b.listItems).insert(ListItemsCompanion.insert(listId: other, entryId: 3));
    await BackupRepository(b).restore(file, replace: true);
    expect((await b.select(b.lists).get()).map((l) => l.name).toSet(), {'Exam prep', 'GRE'});
    await a.close();
    await b.close();
  });

  test('other files, and backups from a newer app, are refused', () {
    expect(() => BackupRepository.summarize({'hello': 1}), throwsA(isA<BackupFormatException>()));
    expect(() => BackupRepository.summarize([1, 2]), throwsA(isA<BackupFormatException>()));
    expect(
      () => BackupRepository.summarize({'format': BackupRepository.format, 'version': 99}),
      throwsA(isA<BackupFormatException>().having((e) => e.message, 'message', contains('newer'))),
    );
  });
}

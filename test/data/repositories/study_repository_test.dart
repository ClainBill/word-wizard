import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/repositories/list_repository.dart';
import 'package:word_wizard/data/repositories/study_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';
import 'package:word_wizard/domain/models/study_card.dart';
import 'package:word_wizard/domain/models/study_direction.dart';
import 'package:word_wizard/domain/models/word_list.dart';

const _w2m = {StudyDirection.wordToMeaning};

/// Every list-scoped SRS action (enroll/pause/reset/remove/dueQueue) accepts
/// whatever id `listId` names — a plain list, or, since folders are just
/// `lists` rows with children, a folder — and resolves it to the same
/// recursive subtree as list_repository_test.dart exercises on the read
/// side. These tests check that resolution actually reaches nested lists'
/// words, and that a word reachable through two nested lists in one folder
/// isn't double-counted.
void main() {
  late UserDatabase db;
  late ListRepository listRepo;
  late StudyRepository studyRepo;

  setUp(() async {
    db = UserDatabase(NativeDatabase.memory());
    listRepo = ListRepository(db);
    studyRepo = StudyRepository(db);
    // enrollList/setListPaused/resetListCards/removeListCards never touch
    // `dict.*`, but dueQueue's SELECT list does (headword/pos/gloss/example)
    // — attach a minimal in-memory stand-in so it can run in this same
    // hermetic setup rather than needing a real bundled dictionary.db.
    await db.customStatement("ATTACH DATABASE ':memory:' AS dict");
    await db.customStatement('CREATE TABLE dict.entries (id INTEGER PRIMARY KEY, headword TEXT, pos TEXT)');
    await db.customStatement('CREATE TABLE dict.pronunciations (entry_id INTEGER, ipa TEXT)');
    await db.customStatement(
      'CREATE TABLE dict.senses (id INTEGER PRIMARY KEY, entry_id INTEGER, sense_order INTEGER, gloss TEXT)',
    );
    await db.customStatement(
      'CREATE TABLE dict.examples (id INTEGER PRIMARY KEY, sense_id INTEGER, text TEXT, source TEXT)',
    );
  });

  tearDown(() => db.close());

  Future<void> seedEntry(int id, String headword) =>
      db.customStatement("INSERT INTO dict.entries (id, headword, pos) VALUES ($id, '$headword', 'noun')");

  test('enrollList on a folder enrolls words from every nested list', () async {
    final folder = await listRepo.createList('Folder', kind: ListKind.folder);
    final child = await listRepo.createList('Child', parentId: folder);
    await listRepo.addToList(folder, 1);
    await listRepo.addToList(child, 2);

    await studyRepo.enrollList(folder, _w2m);

    final cards = await (db.select(db.studyCards)).get();
    expect(cards.map((c) => c.entryId).toSet(), {1, 2});
  });

  test('a word reachable through two nested lists in the same folder is enrolled once', () async {
    final folder = await listRepo.createList('Folder', kind: ListKind.folder);
    final childA = await listRepo.createList('A', parentId: folder);
    final childB = await listRepo.createList('B', parentId: folder);
    await listRepo.addToList(childA, 1);
    await listRepo.addToList(childB, 1);

    await studyRepo.enrollList(folder, _w2m);

    final cards = await (db.select(db.studyCards)).get();
    expect(cards.length, 1);
  });

  test('setListPaused/resetListCards/removeListCards on a folder reach nested lists\' cards', () async {
    final folder = await listRepo.createList('Folder', kind: ListKind.folder);
    final child = await listRepo.createList('Child', parentId: folder);
    await listRepo.addToList(folder, 1);
    await listRepo.addToList(child, 2);
    await studyRepo.enrollList(folder, _w2m);

    await studyRepo.setListPaused(folder, true);
    var cards = await (db.select(db.studyCards)).get();
    expect(cards.every((c) => c.paused), isTrue);

    await studyRepo.setListPaused(folder, false);
    await studyRepo.resetListCards(folder);
    cards = await (db.select(db.studyCards)).get();
    expect(cards.every((c) => c.repetitions == 0), isTrue);

    await studyRepo.removeListCards(folder);
    cards = await (db.select(db.studyCards)).get();
    expect(cards, isEmpty);
  });

  test('SRS actions on a folder leave sibling lists outside it untouched', () async {
    final folder = await listRepo.createList('Folder', kind: ListKind.folder);
    final child = await listRepo.createList('Child', parentId: folder);
    final outside = await listRepo.createList('Outside');
    await listRepo.addToList(child, 1);
    await listRepo.addToList(outside, 2);
    await studyRepo.enrollList(folder, _w2m);
    await studyRepo.enrollList(outside, _w2m);

    await studyRepo.removeListCards(folder);

    final remaining = await (db.select(db.studyCards)).get();
    expect(remaining.map((c) => c.entryId).toList(), [2]);
  });

  test('dueQueue(listId: folder) returns cards from nested lists, without duplicates', () async {
    await seedEntry(1, 'alpha');
    await seedEntry(2, 'beta');
    final folder = await listRepo.createList('Folder', kind: ListKind.folder);
    final childA = await listRepo.createList('A', parentId: folder);
    final childB = await listRepo.createList('B', parentId: folder);
    await listRepo.addToList(childA, 1);
    await listRepo.addToList(childB, 1); // same word, two nested lists
    await listRepo.addToList(childA, 2);
    await studyRepo.enrollList(folder, _w2m);

    final due = await studyRepo.dueQueue(directions: _w2m, listId: folder);

    expect(due.map((c) => c.entryId).toSet(), {1, 2});
    expect(due.length, 2); // not 3 — word 1 isn't duplicated
  });

  test('dueQueue(listId: folder) excludes words in sibling lists outside the folder', () async {
    await seedEntry(1, 'alpha');
    await seedEntry(2, 'beta');
    final folder = await listRepo.createList('Folder', kind: ListKind.folder);
    final child = await listRepo.createList('Child', parentId: folder);
    final outside = await listRepo.createList('Outside');
    await listRepo.addToList(child, 1);
    await listRepo.addToList(outside, 2);
    await studyRepo.enrollList(folder, _w2m);
    await studyRepo.enrollList(outside, _w2m);

    final due = await studyRepo.dueQueue(directions: _w2m, listId: folder);

    expect(due.map((c) => c.entryId).toList(), [1]);
  });

  group('chosen senses', () {
    Future<void> seedSense(
      int id,
      int entryId,
      int order,
      String gloss, {
      String? example,
      List<String> examples = const [],
    }) async {
      await db.customStatement(
        "INSERT INTO dict.senses (id, entry_id, sense_order, gloss) VALUES ($id, $entryId, $order, '$gloss')",
      );
      final all = [?example, ...examples];
      for (var i = 0; i < all.length; i++) {
        await db.customStatement(
          "INSERT INTO dict.examples (id, sense_id, text) VALUES (${id * 10 + i}, $id, '${all[i]}')",
        );
      }
    }

    // "muse": entry 1 is the canonical noun row, entry 5 a sibling verb row
    // of the same headword — the shape loadWord merges into one WordEntry.
    Future<void> seedMuse() async {
      await seedEntry(1, 'muse');
      await db.customStatement(
        "INSERT INTO dict.entries (id, headword, pos) VALUES (5, 'muse', 'verb')",
      );
      await seedSense(11, 1, 0, 'a source of inspiration', example: 'his muse');
      await seedSense(12, 1, 1, 'a poet; a bard');
      await seedSense(13, 1, 2, 'a gap in a hedge');
      await seedSense(51, 5, 0, 'to ponder', example: 'she mused on it');
    }

    test('with nothing pinned the card is dealt one or two of the headword\'s senses', () async {
      await seedMuse();
      await studyRepo.ensureCard(1, _w2m);
      const all = {11, 12, 13, 51};

      final seenCounts = <int>{};
      final seenIds = <int>{};
      // Fresh repository per draw so each dueQueue is an independent deal.
      for (var seed = 0; seed < 12; seed++) {
        final repo = StudyRepository(db, random: Random(seed));
        final card = (await repo.dueQueue(directions: _w2m)).single;
        expect(card.senses, isNotEmpty);
        expect(card.senses.length, lessThanOrEqualTo(2));
        expect(all.containsAll(card.senses.map((s) => s.senseId)), isTrue);
        expect(card.gloss, card.senses.first.gloss);
        seenCounts.add(card.senses.length);
        seenIds.addAll(card.senses.map((s) => s.senseId));
      }
      // Over a dozen deals both sizes turn up, and so does the sibling
      // verb row's sense — the draw spans the whole headword.
      expect(seenCounts, {1, 2});
      expect(seenIds, contains(51));
    });

    test('a dealt pair keeps dictionary order, canonical entry first', () {
      final senses = [
        for (final id in [11, 12, 13, 51])
          StudySense(senseId: id, gloss: 'g$id', pos: id == 51 ? 'verb' : 'noun'),
      ];
      for (var seed = 0; seed < 20; seed++) {
        final dealt = StudyRepository.drawSenses(senses, Random(seed));
        final ids = dealt.map((s) => s.senseId).toList();
        expect(ids, List.of(ids)..sort(), reason: 'seed $seed');
      }
    });

    test('a word with one sense is always dealt that sense', () {
      final only = [const StudySense(senseId: 1, gloss: 'g', pos: 'noun')];
      expect(StudyRepository.drawSenses(only, Random(0)), only);
    });

    test('a pinned sense replaces the draw', () async {
      await seedMuse();
      await studyRepo.ensureCard(1, _w2m);
      await studyRepo.setChosenSenses(1, {51});

      final card = (await studyRepo.dueQueue(directions: _w2m)).single;

      expect(card.gloss, 'to ponder');
      expect(card.example, 'she mused on it');
      expect(card.senses.single.pos, 'verb');
    });

    test('the card quizzes on a real sentence, not whichever example comes first', () async {
      await seedEntry(1, 'thunder');
      await seedSense(
        11,
        1,
        0,
        'a loud rumbling noise',
        examples: [
          // A fragment, then one that gives the word away through an
          // inflection, then a sentence the cloze game can actually use.
          'a clap of thunder',
          'The train thundered along the tracks; the thunder shook the house.',
          'The thunder rolled across the valley all night long.',
        ],
      );
      await studyRepo.ensureCard(1, _w2m);

      final card = (await studyRepo.dueQueue(directions: _w2m)).single;

      expect(card.example, 'The thunder rolled across the valley all night long.');
      // The card's back still lists the sense's own first example.
      expect(card.senses.single.example, 'a clap of thunder');
      expect(card.senses.single.examples, hasLength(3));
    });

    test('with no quizzable example the card falls back to the first one', () async {
      await seedMuse();
      await studyRepo.ensureCard(1, _w2m);
      await studyRepo.setChosenSenses(1, {11});

      final card = (await studyRepo.dueQueue(directions: _w2m)).single;

      expect(card.example, 'his muse');
    });

    test('several chosen senses come back in dictionary order, canonical entry first', () async {
      await seedMuse();
      await studyRepo.ensureCard(1, _w2m);
      // Inserted out of order on purpose.
      await studyRepo.setChosenSenses(1, {51, 13, 12});

      final card = (await studyRepo.dueQueue(directions: _w2m)).single;

      expect(card.senses.map((s) => s.senseId).toList(), [12, 13, 51]);
      expect(card.gloss, 'a poet; a bard');
      // The first chosen sense has no example; the card borrows the first
      // one that does rather than showing none.
      expect(card.example, 'she mused on it');
    });

    test('clearing the pins puts the card back on the draw', () async {
      await seedMuse();
      await studyRepo.ensureCard(1, _w2m);
      await studyRepo.setChosenSenses(1, {13});
      await studyRepo.setChosenSenses(1, {});

      expect(await studyRepo.watchChosenSenses(1).first, isEmpty);
      // Pinned to sense 13 alone, every deal would be [13]; unpinned, a
      // fixed seed deals something else.
      final card = (await StudyRepository(db, random: Random(1)).dueQueue(directions: _w2m)).single;
      expect(card.senses.map((s) => s.senseId).toList(), isNot([13]));
    });

    test('a choice is dropped when the word leaves the pool, and kept while any card remains',
        () async {
      await seedMuse();
      await studyRepo.ensureCard(1, {StudyDirection.wordToMeaning, StudyDirection.meaningToWord});
      await studyRepo.setChosenSenses(1, {12});

      final cards = await (db.select(db.studyCards)).get();
      await studyRepo.removeCard(cards.first.id);
      expect(await studyRepo.watchChosenSenses(1).first, {12});

      await studyRepo.removeEntry(1);
      expect(await studyRepo.watchChosenSenses(1).first, isEmpty);
    });

    test('an excluded sense is never dealt', () async {
      await seedMuse();
      await studyRepo.ensureCard(1, _w2m);
      await studyRepo.setSenseChoices(1, pinned: {}, excluded: {11, 51});

      for (var seed = 0; seed < 12; seed++) {
        final card = (await StudyRepository(db, random: Random(seed)).dueQueue(directions: _w2m)).single;
        final ids = card.senses.map((s) => s.senseId).toSet();
        expect(ids, isNotEmpty);
        expect(ids.intersection({11, 51}), isEmpty, reason: 'seed $seed');
      }
    });

    test('excluding every sense falls back to the full draw rather than an empty card', () async {
      await seedMuse();
      await studyRepo.ensureCard(1, _w2m);
      await studyRepo.setSenseChoices(1, pinned: {}, excluded: {11, 12, 13, 51});

      final card = (await studyRepo.dueQueue(directions: _w2m)).single;
      expect(card.senses, isNotEmpty);
    });

    test('pins and exclusions are kept apart, and a pin wins a clash', () async {
      await seedMuse();
      await studyRepo.ensureCard(1, _w2m);
      await studyRepo.setSenseChoices(1, pinned: {12}, excluded: {12, 13});

      final choices = await studyRepo.watchSenseChoices(1).first;
      expect(choices.pinned, {12});
      expect(choices.excluded, {13});
      // The pin-only setter leaves exclusions alone.
      await studyRepo.setChosenSenses(1, {11});
      final after = await studyRepo.watchSenseChoices(1).first;
      expect(after.pinned, {11});
      expect(after.excluded, {13});
      // A pinned card ignores exclusions entirely — the pin says what it shows.
      final card = (await studyRepo.dueQueue(directions: _w2m)).single;
      expect(card.senses.map((s) => s.senseId).toList(), [11]);
    });
  });
}

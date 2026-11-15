import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/dictionary/dictionary_database.dart';
import 'package:word_wizard/data/repositories/backup_repository.dart';
import 'package:word_wizard/data/repositories/list_repository.dart';
import 'package:word_wizard/data/repositories/reader_repository.dart';
import 'package:word_wizard/data/repositories/search_repository.dart';
import 'package:word_wizard/data/repositories/slang_repository.dart';
import 'package:word_wizard/data/repositories/study_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';
import 'package:word_wizard/domain/models/reader_document.dart';
import 'package:word_wizard/domain/models/slang.dart';
import 'package:word_wizard/domain/models/study_direction.dart';

const _w2m = {StudyDirection.wordToMeaning};

/// The dictionary every test here runs against: "cap" (which the person
/// will add a slang meaning to) and "melody" (which they won't). Written to
/// a file so the user database can attach it as `dict`, the way the app
/// does, and a [DictionaryDatabase] can open the same data for lookups.
const _ddl = [
  'CREATE TABLE entries (id INTEGER PRIMARY KEY, headword TEXT NOT NULL, pos TEXT NOT NULL, '
      'frequency_rank INTEGER, etymology TEXT)',
  'CREATE INDEX idx_entries_headword ON entries(headword)',
  'CREATE TABLE senses (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, gloss TEXT NOT NULL, '
      'sense_order INTEGER NOT NULL)',
  'CREATE TABLE examples (id INTEGER PRIMARY KEY, sense_id INTEGER NOT NULL, text TEXT NOT NULL, source TEXT)',
  'CREATE TABLE pronunciations (entry_id INTEGER PRIMARY KEY, ipa TEXT, audio_hint TEXT)',
  'CREATE TABLE forms (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, form_text TEXT NOT NULL, '
      'form_type TEXT NOT NULL)',
  'CREATE TABLE spelling_variants (variant TEXT NOT NULL, headword TEXT NOT NULL, label TEXT NOT NULL, '
      'PRIMARY KEY (variant, headword))',
  'CREATE VIRTUAL TABLE entries_fts USING fts5(headword)',
  "INSERT INTO entries VALUES (1, 'cap', 'noun', 900, NULL)",
  "INSERT INTO senses VALUES (11, 1, 'A soft, flat hat.', 0)",
  "INSERT INTO entries VALUES (2, 'melody', 'noun', 1200, NULL)",
  "INSERT INTO senses VALUES (21, 2, 'A tune.', 0)",
  "INSERT INTO entries_fts (rowid, headword) VALUES (1, 'cap'), (2, 'melody')",
];

const _skrrt = SlangWord(
  headword: 'skrrt',
  sayItLike: 'skuh-urt',
  spellings: ['skrt'],
  forms: ['skrrted'],
  region: 'US',
  scene: 'rap',
  freshness: SlangFreshness.current,
  heardAt: 'a Migos verse',
  senses: [
    SlangSense(
      pos: 'intj',
      gloss: 'The sound of tyres screeching as a car pulls away.',
      plainEnglish: 'screech',
      tone: SlangTone.playful,
      examples: ['We pulled out of the lot, skrrt, and never looked back.'],
    ),
  ],
);

const _capSlang = SlangWord(
  headword: 'cap',
  senses: [SlangSense(pos: 'noun', gloss: 'A lie.', plainEnglish: 'lie', examples: ['That story is cap.'])],
);

void main() {
  // Two devices in the backup test are two UserDatabases, on purpose.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  late UserDatabase user;
  late DictionaryDatabase dict;
  late SlangRepository slang;
  late StudyRepository study;

  Future<UserDatabase> device() async {
    final db = UserDatabase(NativeDatabase.memory());
    await db.customStatement("ATTACH DATABASE '${dir.path}/dict.db' AS dict");
    return db;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slang_test');
    dict = DictionaryDatabase(NativeDatabase(File('${dir.path}/dict.db')));
    for (final statement in _ddl) {
      await dict.customStatement(statement);
    }
    user = await device();
    slang = SlangRepository(user);
    study = StudyRepository(user, random: Random(1));
  });

  tearDown(() async {
    await user.close();
    await dict.close();
    await dir.delete(recursive: true);
  });

  group('SlangRepository', () {
    test('saves a word with every detail, under ids far from the dictionary\'s', () async {
      final saved = await slang.save(_skrrt);

      expect(saved.id, greaterThanOrEqualTo(slangIdBase));
      expect(isSlangId(saved.id!), isTrue);
      expect(saved.senses.single.id, greaterThanOrEqualTo(slangIdBase));
      expect(saved.sayItLike, 'skuh-urt');
      expect(saved.spellings, ['skrt']);
      expect(saved.forms, ['skrrted']);
      expect(saved.freshness, SlangFreshness.current);
      expect(saved.senses.single.tone, SlangTone.playful);
      expect(saved.senses.single.plainEnglish, 'screech');
      expect(saved.senses.single.examples, hasLength(1));
      expect((await slang.byForm('skrt'))?.id, saved.id);
      expect((await slang.byForm('skrrted'))?.id, saved.id);
    });

    test('an edit keeps a meaning\'s id, and dropping a meaning drops its pin', () async {
      final saved = await slang.save(const SlangWord(
        headword: 'skrrt',
        senses: [SlangSense(gloss: 'first'), SlangSense(gloss: 'second')],
      ));
      final [first, second] = saved.senses;
      await study.ensureCard(saved.id!, _w2m);
      await study.setSenseChoices(saved.id!, pinned: {second.id!}, excluded: {});

      final edited = await slang.save(SlangWord(
        id: saved.id,
        headword: 'skrrt',
        createdAt: saved.createdAt,
        senses: [SlangSense(id: first.id, gloss: 'first, reworded'), const SlangSense(gloss: 'third')],
      ));

      expect(edited.senses.first.id, first.id);
      expect(edited.senses.first.gloss, 'first, reworded');
      expect(edited.senses.map((s) => s.id), isNot(contains(second.id)));
      expect((await study.watchSenseChoices(saved.id!).first).pinned, isEmpty);
    });

    test('never hands out an id twice, even after the word holding it is deleted', () async {
      final first = await slang.save(_skrrt);
      await slang.delete(first.id!);
      final second = await slang.save(_skrrt);
      expect(second.id, greaterThan(first.id!));
      expect(second.senses.single.id, greaterThan(first.senses.single.id!));
    });

    test('refuses a second word with the same headword', () async {
      await slang.save(_skrrt);
      expect(() => slang.save(const SlangWord(headword: 'skrrt')), throwsA(isA<SlangHeadwordTakenException>()));
    });

    test('deleting a word only the Slang Stack knew takes its cards, list places and notes with it', () async {
      final saved = await slang.save(_skrrt);
      final list = await ListRepository(user).createList('Mine');
      await ListRepository(user).addToList(list, saved.id!);
      await study.ensureCard(saved.id!, _w2m);
      await user.into(user.entryNotes).insert(EntryNotesCompanion.insert(entryId: Value(saved.id!), markdown: 'hi'));

      await slang.delete(saved.id!);

      expect(await user.select(user.slangWords).get(), isEmpty);
      expect(await user.select(user.slangSenses).get(), isEmpty);
      expect(await user.select(user.studyCards).get(), isEmpty);
      expect(await user.select(user.listItems).get(), isEmpty);
      expect(await user.select(user.entryNotes).get(), isEmpty);
    });

    test('deleting slang on a dictionary word leaves the word\'s own card alone', () async {
      final saved = await slang.save(_capSlang);
      await study.ensureCard(1, _w2m);

      await slang.delete(saved.id!);

      expect(await user.select(user.studyCards).get(), hasLength(1));
    });
  });

  group('everywhere a word is read', () {
    test('a slang-only word studies like any other, with its own meaning and example', () async {
      final saved = await slang.save(_skrrt);
      await study.ensureCard(saved.id!, _w2m);

      final card = (await study.dueQueue(directions: _w2m)).single;

      expect(card.entryId, saved.id);
      expect(card.headword, 'skrrt');
      expect(card.pos, 'intj');
      expect(card.gloss, startsWith('The sound of tyres'));
      expect(card.example, contains('skrrt'));
      expect(card.senses.single.senseId, saved.senses.single.id);
      expect((await study.allStudyingCards()).single.headword, 'skrrt');
      expect((await study.watchAllCards().first).single.headword, 'skrrt');
      expect((await study.watchFamiliarity().first).keys, ['skrrt']);
      expect((await study.pickReminderWord())?.headword, 'skrrt');
    });

    test('a slang meaning on a dictionary word joins its draw, first, and can be pinned', () async {
      final saved = await slang.save(_capSlang);
      final slangSense = saved.senses.single.id!;
      await study.ensureCard(1, _w2m);

      // Unpinned, the draw is over both meanings; pinned, only the slang one.
      final glosses = <String>{};
      for (var i = 0; i < 20; i++) {
        glosses.addAll((await study.dueQueue(directions: _w2m)).single.senses.map((s) => s.gloss));
      }
      expect(glosses, {'A lie.', 'A soft, flat hat.'});

      await study.setSenseChoices(1, pinned: {slangSense}, excluded: {});
      final card = (await study.dueQueue(directions: _w2m)).single;
      expect(card.senses.map((s) => s.gloss), ['A lie.']);
      expect(card.example, 'That story is cap.');
    });

    test('lists show slang words, and the person\'s own meaning for a dictionary word', () async {
      final skrrt = await slang.save(_skrrt);
      await slang.save(_capSlang);
      final lists = ListRepository(user);
      final list = await lists.createList('Mine');
      await lists.addToList(list, skrrt.id!);
      await lists.addToList(list, 1);

      final items = await lists.watchListItems(list).first;

      expect({for (final i in items) i.headword: i.gloss}, {
        'skrrt': 'The sound of tyres screeching as a car pulls away.',
        'cap': 'A lie.',
      });
    });

    test('the reader finds slang words by headword, spelling and form', () async {
      final skrrt = await slang.save(_skrrt);
      final analysis = await ReaderRepository(user).analyze([
        const ReaderBlock(kind: BlockKind.paragraph, spans: [ReaderSpan('skrrt then skrt then skrrted')]),
      ]);
      final resolved = analysis.blocks.single.where((t) => t.word != null).map((t) => t.word!.entryId);
      expect(resolved, [skrrt.id, skrrt.id, skrrt.id]);
    });

    test('search and lookup reach slang words, and mark dictionary words that have some', () async {
      final skrrt = await slang.save(_skrrt);
      await slang.save(_capSlang);
      final search = SearchRepository(dict, slang: slang);

      final results = await search.searchOrResolve('sk');
      expect(results.single.headword, 'skrrt');
      expect(results.single.slang, isTrue);
      final cap = await search.searchOrResolve('cap');
      expect(cap.single.slang, isTrue);
      expect(cap.single.id, 1);

      final word = await search.loadWord('skrrt');
      expect(word!.canonicalEntryId, skrrt.id);
      expect(word.isSlangOnly, isTrue);
      expect(word.spokenAs, 'skuh-urt');
      expect((await search.loadWord('skrt'))?.lookedUpAs, 'skrt');
      expect((await search.loadWord('skrrted'))?.headword, 'skrrt');

      final capWord = await search.loadWord('cap');
      expect(capWord!.canonicalEntryId, 1);
      expect(capWord.posGroups.first.isSlang, isTrue);
      expect(capWord.posGroups.expand((g) => g.senses).map((s) => s.gloss), ['A lie.', 'A soft, flat hat.']);

      final clues = await search.crosswordClueOptions({skrrt.id!: 'SKRRT', 1: 'CAP'});
      expect(clues[skrrt.id], contains('Screech'));
      expect(clues[1], containsAll(['A soft, flat hat.', 'Lie']));
    });
  });

  group('backup', () {
    test('a slang word, its card and a pin on its meaning survive a round trip to a fresh device', () async {
      final skrrt = await slang.save(_skrrt);
      final cap = await slang.save(_capSlang);
      await study.ensureCard(skrrt.id!, _w2m);
      await study.ensureCard(1, _w2m);
      await study.setSenseChoices(1, pinned: {cap.senses.single.id!}, excluded: {});

      final json = await BackupRepository(user).export(appVersion: 'test');
      expect(BackupRepository.summarize(json).slangWords, 2);

      final other = await device();
      // The other device already used the first slang ids for something
      // else, so nothing can line up by id by accident.
      await SlangRepository(other).save(const SlangWord(headword: 'zzz', senses: [SlangSense(gloss: 'z')]));
      final result = await BackupRepository(other).restore(json, replace: false);
      expect(result.slangWords, 2);
      expect(result.skippedWords, 0);

      final otherStudy = StudyRepository(other, random: Random(1));
      final cards = await otherStudy.dueQueue(directions: _w2m);
      expect(cards.map((c) => c.headword).toSet(), {'skrrt', 'cap'});
      final capCard = cards.firstWhere((c) => c.headword == 'cap');
      expect(capCard.senses.map((s) => s.gloss), ['A lie.']);
      final restored = await SlangRepository(other).byHeadword('skrrt');
      expect(restored!.forms, ['skrrted']);
      expect(restored.heardAt, 'a Migos verse');
      expect(cards.firstWhere((c) => c.headword == 'skrrt').entryId, restored.id);
      await other.close();
    });
  });
}

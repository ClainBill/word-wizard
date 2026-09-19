import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/repositories/list_repository.dart';
import 'package:word_wizard/data/repositories/reader_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';
import 'package:word_wizard/data/repositories/study_repository.dart';
import 'package:word_wizard/domain/models/reader_document.dart';
import 'package:word_wizard/domain/models/study_direction.dart';
import 'package:word_wizard/domain/reader/text_import.dart';

/// The Reader resolves words by joining against the attached `dict`
/// schema, so these tests attach an in-memory stand-in with the same three
/// tables the real pipeline builds and a handful of rows.
void main() {
  late UserDatabase db;
  late ReaderRepository repo;

  setUp(() async {
    db = UserDatabase(NativeDatabase.memory());
    await db.customStatement("ATTACH DATABASE ':memory:' AS dict");
    await db.customStatement('''
      CREATE TABLE dict.entries (
        id INTEGER PRIMARY KEY, headword TEXT NOT NULL, pos TEXT NOT NULL,
        frequency_rank INTEGER, etymology TEXT)''');
    await db.customStatement('''
      CREATE TABLE dict.senses (
        id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, gloss TEXT NOT NULL,
        sense_order INTEGER NOT NULL)''');
    await db.customStatement('''
      CREATE TABLE dict.forms (
        id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, form_text TEXT NOT NULL,
        form_type TEXT NOT NULL)''');
    await db.customStatement('''
      CREATE TABLE dict.spelling_variants (
        variant TEXT NOT NULL, headword TEXT NOT NULL, label TEXT NOT NULL,
        PRIMARY KEY (variant, headword))''');
    await db.customStatement('CREATE INDEX dict.idx_entries_headword ON entries(headword)');
    await db.customStatement('CREATE INDEX dict.idx_forms_form_text ON forms(form_text)');

    Future<void> entry(int id, String headword, String pos, int? rank, String gloss) async {
      await db.customStatement(
        'INSERT INTO dict.entries (id, headword, pos, frequency_rank) VALUES (?, ?, ?, ?)',
        [id, headword, pos, rank],
      );
      await db.customStatement(
        'INSERT INTO dict.senses (entry_id, gloss, sense_order) VALUES (?, ?, 0)',
        [id, gloss],
      );
    }

    // "run" has a verb row and a better-ranked noun row: the noun is canonical.
    await entry(1, 'run', 'verb', 300, 'to move quickly');
    await entry(2, 'run', 'noun', 250, 'an act of running');
    // "running" is both its own adjective entry and a form of "run".
    await entry(3, 'running', 'adj', 6000, 'in motion');
    await db.customStatement(
      "INSERT INTO dict.forms (entry_id, form_text, form_type) VALUES (1, 'running', 'present participle')",
    );
    await db.customStatement("INSERT INTO dict.forms (entry_id, form_text, form_type) VALUES (1, 'ran', 'past')");
    await entry(4, 'the', 'article', 1, 'definite article');
    await entry(5, 'obfuscate', 'verb', 217910, 'to make obscure');
    await entry(6, 'Paris', 'proper noun', 9000, 'capital of France');
    await entry(7, 'luminescent', 'adj', 150000, 'emitting light');
    await entry(8, 'word', 'noun', 400, 'a unit of language');
    // "colour" is a stub whose only sense points at "color"; the pipeline
    // records that in spelling_variants and the page treats it as "color".
    await entry(9, 'color', 'noun', 500, 'the spectral composition of light');
    await entry(10, 'colour', 'noun', 20000, 'Commonwealth and Ireland standard spelling of color.');
    await db.customStatement(
      "INSERT INTO dict.spelling_variants (variant, headword, label) VALUES ('colour', 'color', 'Commonwealth and Ireland')",
    );

    repo = ReaderRepository(db);
  });

  tearDown(() => db.close());

  group('analysis', () {
    test('resolves headwords, forms, case and possessives; leaves unknowns null', () async {
      final blocks = blocksFromPlainText("The word's obfuscate. Ran to Paris; bio-luminescent zzzq.");
      final analysis = await repo.analyze(blocks);
      final tokens = analysis.blocks.single;
      final text = blocks.single.text;
      final byText = {for (final t in tokens) t.token.textIn(text): t.word};

      expect(byText['The']!.headword, 'the');
      expect(byText["word's"]!.headword, 'word');
      expect(byText['obfuscate']!.entryId, 5);
      expect(byText['obfuscate']!.isUncommon, isTrue);
      expect(byText['obfuscate']!.gloss, 'to make obscure');
      // An inflection resolves to its lemma's *canonical* row, not merely
      // the row the form pointed at.
      expect(byText['Ran']!.headword, 'run');
      expect(byText['Ran']!.entryId, 2);
      expect(byText['Paris']!.headword, 'Paris');
      // The hyphenated compound isn't a headword, so its halves are
      // looked up separately and become two tokens.
      expect(byText.containsKey('bio-luminescent'), isFalse);
      expect(byText['bio'], isNull);
      expect(byText['luminescent']!.entryId, 7);
      expect(byText['zzzq'], isNull);
      expect(analysis.wordCount, 9);
    });

    test('a word that is both a headword and a form carries its lemma', () async {
      final analysis = await repo.analyze(blocksFromPlainText('running'));
      final word = analysis.blocks.single.single.word!;
      expect(word.headword, 'running');
      expect(word.entryId, 3);
      expect(word.lemma?.headword, 'run');
      expect(word.lemma?.entryId, 2);
    });

    test('a variant spelling resolves to the word it is a spelling of', () async {
      final blocks = blocksFromPlainText('A colour, or a color.');
      final analysis = await repo.analyze(blocks);
      final text = blocks.single.text;
      final byText = {for (final t in analysis.blocks.single) t.token.textIn(text): t.word};
      expect(byText['colour']!.headword, 'color');
      expect(byText['colour']!.entryId, 9);
      expect(byText['colour']!.gloss, 'the spectral composition of light');
      expect(byText['color']!.entryId, 9);
    });

    test('empty text analyzes to empty blocks', () async {
      final analysis = await repo.analyze(const []);
      expect(analysis.blocks, isEmpty);
      expect(analysis.wordCount, 0);
    });
  });

  group('marks', () {
    test('reflect list membership and study, and prefer a marked lemma', () async {
      final lists = ListRepository(db);
      final study = StudyRepository(db);
      final listId = await lists.createList('Verbs');
      await lists.addToList(listId, 2); // "run"
      await study.ensureCard(5, {StudyDirection.wordToMeaning}); // "obfuscate"

      final marks = await repo.watchMarks().first;
      expect(marks.listsFor(2), [listId]);
      expect(marks.isStudying(5), isTrue);
      expect(marks.isStudying(2), isFalse);

      final analysis = await repo.analyze(blocksFromPlainText('running'));
      final word = analysis.blocks.single.single.word!;
      // "running" itself is in no list, but its lemma "run" is.
      expect(marks.effective(word).headword, 'run');

      await lists.addToList(listId, 3);
      final updated = await repo.watchMarks().first;
      expect(updated.effective(word).headword, 'running');
    });

    test('the list index names every list', () async {
      final lists = ListRepository(db);
      final id = await lists.createList('GRE');
      final index = await repo.watchListIndex().first;
      expect(index[id]?.name, 'GRE');
    });
  });

  group('documents', () {
    test('create derives title, preview, word count; the newest opened is current', () async {
      final a = await repo.createDocument(
        blocksFromPlainText('# Alpha\n\nSome body text here.'),
        source: ReaderSource.clipboard,
      );
      final b = await repo.createDocument(blocksFromPlainText('Beta text.'), source: ReaderSource.typed);

      final history = await repo.watchHistory().first;
      expect(history.map((d) => d.id), [b, a]);
      expect(history.last.title, 'Alpha');
      expect(history.last.preview, 'Alpha Some body text here.');
      expect(history.last.wordCount, 5);
      expect(history.last.source, ReaderSource.clipboard);

      expect((await repo.watchCurrent().first)?.id, b);
      await repo.open(a);
      expect((await repo.watchCurrent().first)?.id, a);
    });

    test('identical text is found by content, so a re-copy reopens rather than duplicates', () async {
      final blocks = blocksFromPlainText('Same words again.');
      final id = await repo.createDocument(blocks, source: ReaderSource.clipboard);
      expect(await repo.findByContent(blocks), id);
      expect(await repo.findByContent(blocksFromPlainText('Different words.')), isNull);
    });

    test('editing replaces text and content hash but keeps an explicit title', () async {
      final id = await repo.createDocument(
        blocksFromPlainText('Old text.'),
        source: ReaderSource.typed,
        title: 'Mine',
      );
      final before = (await repo.getDocument(id))!;
      await repo.updateDocumentText(id, blocksFromPlainText('New text, longer now.'));
      final after = (await repo.getDocument(id))!;
      expect(after.title, 'Mine');
      expect(after.plainText, 'New text, longer now.');
      expect(after.contentHash, isNot(before.contentHash));
      expect(after.wordCount, 4);
    });

    test('rename, delete and deleteAll', () async {
      final id = await repo.createDocument(blocksFromPlainText('x y z'), source: ReaderSource.typed);
      await repo.rename(id, '  Renamed ');
      expect((await repo.getDocument(id))!.title, 'Renamed');
      await repo.delete(id);
      expect(await repo.getDocument(id), isNull);
      await repo.createDocument(blocksFromPlainText('a'), source: ReaderSource.typed);
      await repo.createDocument(blocksFromPlainText('b'), source: ReaderSource.typed);
      await repo.deleteAll();
      expect(await repo.watchHistory().first, isEmpty);
      expect(await repo.watchCurrent().first, isNull);
    });

    test('blocks with formatting round-trip through storage', () async {
      final blocks = blocksFromHtml('<h1>Head</h1><p>a <b>b</b></p>');
      final id = await repo.createDocument(blocks, source: ReaderSource.clipboard);
      final doc = (await repo.getDocument(id))!;
      expect(doc.blocks[0].kind, BlockKind.heading);
      expect(doc.blocks[1].spans[1].bold, isTrue);
      expect(doc.title, 'Head');
    });
  });

  test('analysis copes with more distinct words than one query chunk', () async {
    // 900 distinct nonsense words plus one real one, to push past the
    // 400-parameter chunking in both lookups.
    String letters(int n) {
      final buf = StringBuffer();
      var v = n;
      do {
        buf.writeCharCode(0x61 + v % 26);
        v ~/= 26;
      } while (v > 0);
      return buf.toString();
    }

    final words = [for (var i = 0; i < 900; i++) 'zz${letters(i)}q', 'obfuscate'];
    final analysis = await repo.analyze(blocksFromPlainText(words.join(' ')));
    expect(analysis.wordCount, 901);
    expect(analysis.blocks.single.last.word?.entryId, 5);
    expect(analysis.blocks.single.first.word, isNull);
  });
}

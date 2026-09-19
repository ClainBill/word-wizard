import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/dictionary/dictionary_database.dart';

/// "colour" and "color" are one word. The pipeline records the stub
/// entries Wiktionary keeps for other spellings in `spelling_variants`;
/// search and lookup fold them into the word they point at.
void main() {
  late DictionaryDatabase db;

  setUp(() async {
    db = DictionaryDatabase(NativeDatabase.memory());
    for (final ddl in [
      'CREATE TABLE entries (id INTEGER PRIMARY KEY, headword TEXT NOT NULL, pos TEXT NOT NULL, '
          'frequency_rank INTEGER, etymology TEXT)',
      'CREATE TABLE senses (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, gloss TEXT NOT NULL, '
          'sense_order INTEGER NOT NULL)',
      'CREATE TABLE examples (id INTEGER PRIMARY KEY, sense_id INTEGER NOT NULL, text TEXT NOT NULL, '
          'source TEXT)',
      'CREATE TABLE pronunciations (entry_id INTEGER PRIMARY KEY, ipa TEXT, audio_hint TEXT)',
      'CREATE TABLE forms (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, form_text TEXT NOT NULL, '
          'form_type TEXT NOT NULL)',
      'CREATE TABLE spelling_variants (variant TEXT NOT NULL, headword TEXT NOT NULL, '
          'label TEXT NOT NULL, PRIMARY KEY (variant, headword))',
      "CREATE VIRTUAL TABLE entries_fts USING fts5(headword, content='entries', content_rowid='id')",
    ]) {
      await db.customStatement(ddl);
    }
    Future<void> entry(int id, String headword, String pos, int rank, String gloss) async {
      await db.customStatement(
        'INSERT INTO entries (id, headword, pos, frequency_rank) VALUES (?, ?, ?, ?)',
        [id, headword, pos, rank],
      );
      await db.customStatement(
        'INSERT INTO senses (id, entry_id, gloss, sense_order) VALUES (?, ?, ?, 0)',
        [id, id, gloss],
      );
    }

    await entry(1, 'color', 'noun', 100, 'The spectral composition of visible light.');
    await entry(2, 'color', 'verb', 101, 'To give something color.');
    await entry(3, 'colour', 'noun', 900, 'Commonwealth and Ireland standard spelling of color.');
    await entry(4, 'colour', 'verb', 901, 'Commonwealth and Ireland standard spelling of color.');
    await entry(5, 'colourful', 'adj', 950, 'Commonwealth spelling of colorful.');
    await entry(6, 'colorful', 'adj', 400, 'Possessing prominent and varied colors.');
    await entry(7, 'colr', 'noun', 99000, 'Misspelling of color.');
    await entry(8, 'colon', 'noun', 300, 'A punctuation mark.');
    await db.customStatement("INSERT INTO forms (entry_id, form_text, form_type) VALUES (3, 'colours', 'plural')");
    await db.customStatement("INSERT INTO forms (entry_id, form_text, form_type) VALUES (1, 'colors', 'plural')");
    for (final (v, h, l) in [
      ('colour', 'color', 'Commonwealth and Ireland'),
      ('colr', 'color', 'misspelling'),
      ('colourful', 'colorful', 'Commonwealth'),
    ]) {
      await db.customStatement(
        'INSERT INTO spelling_variants (variant, headword, label) VALUES (?, ?, ?)',
        [v, h, l],
      );
    }
    await db.customStatement('INSERT INTO entries_fts(rowid, headword) SELECT id, headword FROM entries');
  });

  tearDown(() => db.close());

  test('search shows one row for both spellings, tagged with the one typed', () async {
    final results = await db.search('colour');
    expect(results.map((r) => r.headword), ['color', 'colorful']);
    expect(results.first.id, 1, reason: 'the target\'s own best-ranked row');
    expect(results.first.gloss, 'The spectral composition of visible light.');
    expect(results.first.matchedForm, 'colour');
    expect(results[1].matchedForm, 'colourful');
  });

  test('a search that already has the word keeps its row and drops the stub', () async {
    final results = await db.search('col');
    final heads = results.map((r) => r.headword).toList();
    expect(heads, isNot(contains('colour')));
    expect(heads, isNot(contains('colr')));
    expect(heads.where((h) => h == 'color'), hasLength(1));
    // "color" itself was in the results, so it is not tagged as reached
    // through a variant.
    expect(results.firstWhere((r) => r.headword == 'color').matchedForm, isNull);
  });

  test('a form of a stub resolves to the word', () async {
    final results = await db.resolveForm('colours');
    expect(results.single.headword, 'color');
    expect(results.single.matchedForm, 'colour');
  });

  test('loading a variant loads the word, and says which spelling was asked for', () async {
    final entry = (await db.loadWord('colour'))!;
    expect(entry.headword, 'color');
    expect(entry.canonicalEntryId, 1);
    expect(entry.lookedUpAs, 'colour');
    expect(entry.posGroups.map((g) => g.pos), ['noun', 'verb']);
  });

  test('a card lists its other spellings, misspellings last', () async {
    final entry = (await db.loadWord('color'))!;
    expect(entry.lookedUpAs, isNull);
    expect(entry.variants.map((v) => v.text), ['colour', 'colr']);
    expect(entry.variants.first.label, 'Commonwealth and Ireland');
    expect(entry.variants.last.isMisspelling, isTrue);
  });

  test('a word with no variants is unchanged', () async {
    final entry = (await db.loadWord('colon'))!;
    expect(entry.variants, isEmpty);
    expect(entry.lookedUpAs, isNull);
    expect((await db.search('colon')).single.matchedForm, isNull);
  });
}

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/dictionary/dictionary_database.dart';

/// The "which sentence wants this word?" distractors come from
/// `examples_fts`, ranked by shared content words — so a sentence about
/// sailing gets other sentences about sailing, not one about tax law.
void main() {
  late DictionaryDatabase db;

  Future<void> seed({required bool withFts}) async {
    await db.customStatement(
      'CREATE TABLE entries (id INTEGER PRIMARY KEY, headword TEXT NOT NULL, pos TEXT NOT NULL, '
      'frequency_rank INTEGER, etymology TEXT)',
    );
    await db.customStatement(
      'CREATE TABLE senses (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, gloss TEXT NOT NULL, '
      'sense_order INTEGER NOT NULL)',
    );
    await db.customStatement(
      'CREATE TABLE examples (id INTEGER PRIMARY KEY, sense_id INTEGER NOT NULL, text TEXT NOT NULL, '
      'source TEXT)',
    );
    var nextId = 1;
    Future<void> word(String headword, String example) async {
      final id = nextId++;
      await db.customStatement(
        "INSERT INTO entries (id, headword, pos) VALUES ($id, '$headword', 'noun')",
      );
      await db.customStatement(
        "INSERT INTO senses (id, entry_id, gloss, sense_order) VALUES ($id, $id, 'g', 0)",
      );
      await db.customStatement(
        "INSERT INTO examples (id, sense_id, text, source) VALUES ($id, $id, '$example', '2001, someone')",
      );
    }

    await word('keel', 'The keel scraped the harbour bottom as the boat came in to moor.');
    await word('mast', 'The mast snapped in the gale and the boat drifted toward the harbour.');
    await word('rudder', 'She leaned on the rudder and the boat swung across the harbour mouth.');
    await word('ledger', 'The accountant checked the ledger twice before filing the tax return.');
    await word('invoice', 'Send the invoice to the client before the end of the tax year.');
    // Contains the target word itself: its blank could take "keel", so it
    // must never be offered as a wrong answer.
    await word('hull', 'The hull and keel were scraped clean before the boat went back in the harbour.');
    if (withFts) {
      await db.customStatement(
        "CREATE VIRTUAL TABLE examples_fts USING fts5(text, content='examples', content_rowid='id', "
        "tokenize='porter unicode61')",
      );
      await db.customStatement('INSERT INTO examples_fts(rowid, text) SELECT id, text FROM examples');
    }
  }

  setUp(() {
    db = DictionaryDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('neighbours share the sentence\'s subject, and never contain the target word', () async {
    await seed(withFts: true);
    final target = 'The keel scraped the harbour bottom as the boat came in to moor.';

    final result = await db.similarBlankedExamples(
      target,
      excludeEntryId: 1,
      excludeHeadword: 'keel',
      count: 2,
    );

    expect(result, hasLength(2));
    for (final sentence in result) {
      expect(sentence, contains('_____'));
      expect(sentence, contains('boat'));
      expect(sentence.toLowerCase(), isNot(contains('keel')));
      expect(sentence, isNot(contains('tax')));
    }
  });

  test('returns nothing, not an error, on a dictionary without the index', () async {
    await seed(withFts: false);
    final result = await db.similarBlankedExamples(
      'The keel scraped the harbour bottom.',
      excludeEntryId: 1,
      excludeHeadword: 'keel',
    );
    expect(result, isEmpty);
  });
}

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/dictionary/dictionary_database.dart';

/// The word of the day is row `(days since the epoch) mod pool size` of
/// the pipeline's `daily_words` pool: the same on every device, a
/// different one each day, wrapping round at the end.
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
    ]) {
      await db.customStatement(ddl);
    }
  });

  tearDown(() => db.close());

  Future<void> seedPool() async {
    await db.customStatement(
      'CREATE TABLE daily_words (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, headword TEXT NOT NULL)',
    );
    var senseId = 1;
    for (final (id, word) in [(1, 'acumen'), (2, 'fortuitous'), (3, 'veracity')]) {
      await db.customStatement(
        "INSERT INTO entries (id, headword, pos, frequency_rank) VALUES ($id, '$word', 'noun', $id)",
      );
      // The first sense has no example; the second does, and is the one shown.
      await db.customStatement(
        "INSERT INTO senses (id, entry_id, gloss, sense_order) VALUES (${senseId++}, $id, 'bare sense of $word', 0)",
      );
      await db.customStatement(
        "INSERT INTO senses (id, entry_id, gloss, sense_order) VALUES ($senseId, $id, 'meaning of $word', 1)",
      );
      await db.customStatement(
        "INSERT INTO examples (id, sense_id, text) VALUES ($id, $senseId, 'An example with $word.')",
      );
      senseId++;
      await db.customStatement("INSERT INTO daily_words (id, entry_id, headword) VALUES ($id, $id, '$word')");
    }
  }

  test('a database without the pool has no word of the day', () async {
    expect(await db.wordOfTheDay(DateTime(2026, 9, 17)), isNull);
  });

  test('walks the pool one word a day from the epoch, wrapping round', () async {
    await seedPool();
    final epoch = DateTime(2026, 1, 1);
    expect((await db.wordOfTheDay(epoch))!.headword, 'acumen');
    expect((await db.wordOfTheDay(epoch.add(const Duration(days: 1))))!.headword, 'fortuitous');
    expect((await db.wordOfTheDay(epoch.add(const Duration(days: 2))))!.headword, 'veracity');
    expect((await db.wordOfTheDay(epoch.add(const Duration(days: 3))))!.headword, 'acumen');
    // Before the epoch still lands in the pool rather than off the end.
    expect((await db.wordOfTheDay(epoch.subtract(const Duration(days: 1))))!.headword, 'veracity');
  });

  test('the time of day makes no difference, and the sense with an example is used', () async {
    await seedPool();
    final morning = await db.wordOfTheDay(DateTime(2026, 1, 2, 7, 30));
    final night = await db.wordOfTheDay(DateTime(2026, 1, 2, 23, 59));
    expect(morning!.headword, night!.headword);
    expect(morning.day, DateTime(2026, 1, 2));
    expect(morning.entryId, 2);
    expect(morning.pos, 'noun');
    expect(morning.gloss, 'meaning of fortuitous');
    expect(morning.example, 'An example with fortuitous.');
    expect(morning.notificationBody, 'meaning of fortuitous. "An example with fortuitous."');
  });
}

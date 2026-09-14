import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/repositories/list_repository.dart';
import 'package:word_wizard/data/repositories/progress_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';
import 'package:word_wizard/domain/models/study_direction.dart';

const _w2m = {StudyDirection.wordToMeaning};
const _both = {StudyDirection.wordToMeaning, StudyDirection.meaningToWord};

void main() {
  late UserDatabase db;
  late ProgressRepository repo;
  late ListRepository lists;

  setUp(() {
    db = UserDatabase(NativeDatabase.memory());
    repo = ProgressRepository(db);
    lists = ListRepository(db);
  });

  tearDown(() => db.close());

  Future<int> card(
    int entryId, {
    String direction = 'w2m',
    int interval = 0,
    double ease = 2.5,
    int reps = 0,
  }) =>
      db.into(db.studyCards).insert(StudyCardsCompanion.insert(
            entryId: entryId,
            direction: Value(direction),
            intervalDays: Value(interval),
            easeFactor: Value(ease),
            repetitions: Value(reps),
          ));

  Future<void> review(int cardId, {required int grade, int priorInterval = 0, int ms = 0}) =>
      db.into(db.reviewLog).insert(ReviewLogCompanion.insert(
            cardId: cardId,
            grade: grade,
            priorInterval: priorInterval,
            durationMs: Value(ms),
          ));

  group('overview', () {
    test('counts words by state and lists words not yet studied', () async {
      await card(1, interval: 120, ease: 2.6, reps: 8); // mastered
      await card(2, interval: 10, reps: 3); // reviewing
      await card(3, reps: 1); // learning
      final list = await lists.createList('L');
      await lists.addToList(list, 3); // studied and listed: counted once, as studied
      await lists.addToList(list, 4); // only listed
      await lists.addToList(list, 5);

      final o = await repo.watchOverview(_w2m).first;
      expect(o.mastered, 1);
      expect(o.reviewing, 1);
      expect(o.learning, 1);
      expect(o.unstudied, 2);
      expect(o.total, 5);
    });

    test('a word studied both ways is mastered only when both cards are', () async {
      await card(1, direction: 'w2m', interval: 120, ease: 2.6, reps: 8);
      await card(1, direction: 'm2w', interval: 5, reps: 3);

      final both = await repo.watchOverview(_both).first;
      expect(both.mastered, 0);
      expect(both.reviewing, 1);

      // With the reverse direction switched off, the word is judged on its
      // remaining card alone.
      final oneWay = await repo.watchOverview(_w2m).first;
      expect(oneWay.mastered, 1);
    });

    test('is empty, not an error, with nothing recorded', () async {
      final o = await repo.watchOverview(_w2m).first;
      expect(o.total, 0);
    });
  });

  group('summary', () {
    test('retention counts only mature reviews and never weights by grade', () async {
      final c = await card(1);
      await review(c, grade: 0, priorInterval: 0, ms: 4000); // young lapse: ignored
      await review(c, grade: 5, priorInterval: 30, ms: 3000); // mature, remembered
      await review(c, grade: 3, priorInterval: 45, ms: 5000); // mature, remembered (hard)
      await review(c, grade: 0, priorInterval: 60, ms: 90000); // mature, forgotten

      final s = await repo.watchSummary(_w2m).first;
      expect(s.reviews, 4);
      expect(s.retention, closeTo(2 / 3, 1e-9));
      expect(s.studyTime, const Duration(milliseconds: 102000));
    });

    test('retention is null before any mature review', () async {
      final c = await card(1);
      await review(c, grade: 4, priorInterval: 3);
      final s = await repo.watchSummary(_w2m).first;
      expect(s.retention, isNull);
    });

    test('game stats rank only clean, timed finishes', () async {
      Future<void> play(int ref, {int? ms, bool aided = false, bool done = true}) =>
          db.into(db.gameResults).insert(GameResultsCompanion.insert(
                game: 'crossword',
                difficulty: const Value('mini'),
                refId: ref,
                activeMs: Value(ms ?? 0),
                aided: Value(aided),
                completedAt: Value(done ? DateTime.now() : null),
              ));
      await play(1, ms: 90000);
      await play(2, ms: 60000);
      await play(3, ms: 120000);
      await play(4, ms: 10000, aided: true); // fastest, but with reveals
      await play(5, ms: 0); // backfilled from before timing existed
      await play(6, ms: 30000, done: false); // abandoned

      final s = await repo.watchSummary(_w2m).first;
      expect(s.games, hasLength(1));
      final g = s.games.single;
      expect(g.completed, 5);
      expect(g.clean, 4);
      expect(g.unfinished, 1);
      expect(g.best, const Duration(seconds: 60));
      expect(g.median, const Duration(seconds: 90));
    });

    test('repeat lookups surface words looked up more than once', () async {
      await repo.logLookup(7, 'serendipity');
      await repo.logLookup(7, 'serendipity');
      await repo.logLookup(8, 'ephemeral');
      await repo.logLookup(9, 'lambent');
      await repo.logLookup(9, 'lambent');
      await card(9);

      final s = await repo.watchSummary(_w2m).first;
      expect(s.lookups, 5);
      expect(s.distinctLookups, 3);
      expect(s.repeatLookups.map((r) => r.headword), ['serendipity', 'lambent']);
      expect(s.repeatLookups.first.studying, isFalse);
      expect(s.repeatLookups.last.studying, isTrue);
    });
  });

  group('search history', () {
    test('dedupes queries and orders most recent first', () async {
      await repo.logSearch('muse');
      await repo.logSearch('serene');
      await repo.logSearch('muse');

      final recent = await repo.watchRecentSearches().first;
      expect(recent, ['muse', 'serene']);
      expect(await (db.select(db.searchLog)).get(), hasLength(2));
    });

    test('ignores blank queries', () async {
      await repo.logSearch('   ');
      expect(await repo.watchRecentSearches().first, isEmpty);
    });
  });

  test('activity covers every day in the window, oldest first', () async {
    final c = await card(1);
    await review(c, grade: 4);
    await repo.logLookup(1, 'x');

    final days = await repo.watchActivity(days: 14).first;
    expect(days, hasLength(14));
    expect(days.last.day.isAfter(days.first.day), isTrue);
    expect(days.last.reviews, 1);
    expect(days.last.lookups, 1);
    expect(days.take(13).every((d) => d.total == 0), isTrue);
  });
}

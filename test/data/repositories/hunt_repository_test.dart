import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/repositories/hunt_repository.dart';
import 'package:word_wizard/data/repositories/study_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';
import 'package:word_wizard/domain/hunt/hunt_models.dart';
import 'package:word_wizard/domain/models/study_direction.dart';

/// End to end through the repository: study cards in, a certified board
/// out, progress and history round-tripped. Uses the real lexicon assets
/// (loaded from disk by the test binding) and an in-memory user database
/// with the dictionary tables the study repository joins against.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UserDatabase db;
  late StudyRepository study;
  late HuntRepository repo;

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
      CREATE TABLE dict.examples (
        id INTEGER PRIMARY KEY, sense_id INTEGER NOT NULL, text TEXT NOT NULL, source TEXT)''');
    await db.customStatement('''
      CREATE TABLE dict.pronunciations (
        entry_id INTEGER PRIMARY KEY, ipa TEXT, audio_hint TEXT)''');
    await db.customStatement('''
      CREATE TABLE dict.forms (
        id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, form_text TEXT NOT NULL,
        form_type TEXT NOT NULL)''');

    Future<void> entry(int id, String headword, String gloss) async {
      await db.customStatement(
        'INSERT INTO dict.entries (id, headword, pos, frequency_rank) VALUES (?, ?, ?, ?)',
        [id, headword, 'noun', 1000],
      );
      await db.customStatement(
        'INSERT INTO dict.senses (entry_id, gloss, sense_order) VALUES (?, ?, 0)',
        [id, gloss],
      );
    }

    await entry(1, 'melody', 'a sequence of notes forming a tune');
    await entry(2, 'cadence', 'a rhythmic flow of sounds');
    // Not an accepted spelling (multi-word) — must be skipped, never forced.
    await entry(3, 'an apple a day', 'a proverb');
    // The gloss gives the word away — the clue must be withheld.
    await entry(4, 'serene', 'calm and serene');

    study = StudyRepository(db);
    for (final id in [1, 2, 3, 4]) {
      await study.ensureCard(id, {StudyDirection.wordToMeaning});
    }
    repo = HuntRepository(db, study);
  });

  tearDown(() => db.close());

  test('builds a board around study words and the day\'s theme, and persists it', () async {
    final session = await repo.loadOrGenerate();
    expect(session, isNotNull);
    final puzzle = session!.puzzle;

    final studyAnchors = puzzle.studyAnchors;
    expect(studyAnchors.length, inInclusiveRange(1, 2));
    for (final a in studyAnchors) {
      expect(['MELODY', 'CADENCE', 'SERENE'], contains(a.text));
      expect(a.entryId, isNotNull);
      expect(puzzle.anchorWords.containsKey(a.text), isTrue);
      if (a.text == 'SERENE') expect(a.clue, isNull);
      if (a.text == 'MELODY') expect(a.clue, 'a sequence of notes forming a tune');
    }
    expect(puzzle.anchors.any((a) => a.text == 'ANAPPLEADAY'), isFalse);
    expect(puzzle.main.length, inInclusiveRange(20, 60));
    expect(puzzle.dictionaryHash, startsWith('enable-bonus-v1:'));
    if (puzzle.themeAnchor != null) {
      expect(puzzle.themeLabel, isNotNull);
      expect(puzzle.themeWords, contains(puzzle.themeAnchor!.text));
    }

    // The same day loads the same stored board, not a new generation.
    final again = await repo.loadOrGenerate();
    expect(again!.id, session.id);
    expect(again.puzzle.board, puzzle.board);

    // Progress round-trips.
    final first = puzzle.main.keys.first;
    await repo.startPlay(session.id);
    await repo.saveProgress(session.id, found: {first}, revealed: const {}, hinted: false, completed: false);
    await repo.recordPlayTime(session.id, 4200, aided: false);
    final loaded = await repo.loadPuzzle(session.id);
    expect(loaded!.found, {first});
    expect(loaded.activeMs, 4200);
    expect(loaded.completed, isFalse);

    // History reflects it, and a regeneration keeps the first board.
    final second = await repo.regenerate();
    expect(second, isNotNull);
    expect(second!.id, isNot(session.id));
    final history = await repo.history();
    expect(history.length, 2);
    expect(history.first.id, second.id);
    expect(history.first.isRegeneration, isTrue);
    expect(history.last.id, session.id);
    expect(history.last.play.foundRequired, 1);
    expect(history.last.play.score, first.length);
    expect(history.last.play.activeMs, 4200);
    expect(history.last.studyWords, studyAnchors.length);

    // Today's board is now the regeneration.
    expect((await repo.loadOrGenerate())!.id, second.id);
  });

  test('a completed board is recorded as a finished game', () async {
    final session = (await repo.loadOrGenerate())!;
    await repo.startPlay(session.id);
    final all = {...session.puzzle.anchorWords.keys, ...session.puzzle.main.keys};
    await repo.saveProgress(session.id, found: all, revealed: const {}, hinted: false, completed: true);
    await repo.completePlay(session.id, 90000, aided: false);
    final entry = (await repo.history()).single;
    expect(entry.play.completed, isTrue);
    expect(entry.play.foundRequired, entry.play.requiredTotal);
    expect(entry.play.aided, isFalse);
    expect(entry.play.score, huntScore(session.puzzle, all));
    expect(entry.play.score, session.puzzle.maxScore);
    final game = await (db.select(db.gameResults)).getSingle();
    expect(game.game, 'hunt');
    expect(game.completedAt, isNotNull);
  });

  test('anchors survive the JSON round trip with their kind and clue', () async {
    final session = (await repo.loadOrGenerate())!;
    final copy = HuntPuzzle.fromJson(session.puzzle.toJson());
    for (var i = 0; i < copy.anchors.length; i++) {
      expect(copy.anchors[i].kind, session.puzzle.anchors[i].kind);
      expect(copy.anchors[i].clue, session.puzzle.anchors[i].clue);
      expect(copy.anchors[i].entryId, session.puzzle.anchors[i].entryId);
    }
  });
}

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/dictionary/dictionary_database.dart';
import 'package:word_wizard/data/repositories/crossword_repository.dart';
import 'package:word_wizard/data/repositories/search_repository.dart';
import 'package:word_wizard/data/repositories/settings_repository.dart';
import 'package:word_wizard/data/repositories/study_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';
import 'package:word_wizard/domain/crossword/crossword_models.dart';

/// A group puzzle is built from the pool, not from this device's study
/// words — through the same generator and the real word list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UserDatabase user;
  late DictionaryDatabase dict;
  late CrosswordRepository repo;

  setUp(() async {
    user = UserDatabase(NativeDatabase.memory());
    dict = DictionaryDatabase(NativeDatabase.memory());
    // An empty dictionary: the words are unknown to it, so clues fall back
    // to the shared glosses — the harder path.
    for (final ddl in const [
      'CREATE TABLE entries (id INTEGER PRIMARY KEY, headword TEXT NOT NULL, pos TEXT NOT NULL, '
          'frequency_rank INTEGER, etymology TEXT)',
      'CREATE TABLE senses (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, gloss TEXT NOT NULL, '
          'sense_order INTEGER NOT NULL)',
      'CREATE TABLE examples (id INTEGER PRIMARY KEY, sense_id INTEGER NOT NULL, text TEXT NOT NULL, '
          'source TEXT)',
      'CREATE TABLE pronunciations (entry_id INTEGER PRIMARY KEY, ipa TEXT, audio_hint TEXT)',
      'CREATE TABLE forms (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, form_text TEXT NOT NULL, '
          'form_type TEXT NOT NULL)',
      'CREATE TABLE spelling_variants (variant TEXT NOT NULL, headword TEXT NOT NULL, label TEXT NOT NULL, '
          'PRIMARY KEY (variant, headword))',
    ]) {
      await dict.customStatement(ddl);
    }
    repo = CrosswordRepository(
      user,
      StudyRepository(user),
      SearchRepository(dict),
      SettingsRepository(user),
    );
  });

  tearDown(() async {
    await user.close();
    await dict.close();
  });

  test('generates a Midi anchored on pool words, imports it, and reads its play state', () async {
    final pool = [
      (headword: 'candor', gloss: 'frankness'),
      (headword: 'glint', gloss: 'a brief flash of light'),
      (headword: 'muse', gloss: 'a source of inspiration'),
      (headword: 'ephemeral', gloss: 'lasting a very short time'),
      (headword: 'an apple a day', gloss: 'not anchorable'),
    ];
    final puzzle = await repo.generateFromPool(
      CrosswordDifficulty.midi,
      pool,
      date: '2026-09-20',
      seed: 12345,
    );
    expect(puzzle, isNotNull, reason: 'the generator should fill a Midi from four anchors');
    expect(puzzle!.anchors, isNotEmpty);
    expect(puzzle.anchors.every((a) => ['CANDOR', 'GLINT', 'MUSE', 'EPHEMERAL'].contains(a)), isTrue);
    expect(puzzle.seed, 12345);

    final id = await repo.importPuzzle(CrosswordDifficulty.midi, '2026-09-20', puzzle);
    final state = await repo.playState(id);
    expect(state, isNotNull);
    expect(state!.totalWords, puzzle.words.length);
    expect(state.solvedWords, 0);
    expect(await repo.playState(id + 99), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

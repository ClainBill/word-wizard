import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/app/providers.dart';
import 'package:word_wizard/data/repositories/hunt_repository.dart';
import 'package:word_wizard/data/repositories/study_repository.dart';
import 'package:word_wizard/data/user/user_database.dart';
import 'package:word_wizard/domain/hunt/hunt_models.dart';
import 'package:word_wizard/features/games/hunt_screen.dart';

/// Drives the board the way a finger does — taps and a pan across tiles —
/// against a real generated puzzle, and checks what the screen tells the
/// player and what it writes back.
void main() {
  late UserDatabase db;
  late HuntRepository repo;

  setUp(() async {
    db = UserDatabase(NativeDatabase.memory());
    await db.customStatement("ATTACH DATABASE ':memory:' AS dict");
    for (final ddl in [
      'CREATE TABLE dict.entries (id INTEGER PRIMARY KEY, headword TEXT NOT NULL, pos TEXT NOT NULL, frequency_rank INTEGER, etymology TEXT)',
      'CREATE TABLE dict.senses (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, gloss TEXT NOT NULL, sense_order INTEGER NOT NULL)',
      'CREATE TABLE dict.examples (id INTEGER PRIMARY KEY, sense_id INTEGER NOT NULL, text TEXT NOT NULL, source TEXT)',
      'CREATE TABLE dict.pronunciations (entry_id INTEGER PRIMARY KEY, ipa TEXT, audio_hint TEXT)',
      'CREATE TABLE dict.forms (id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL, form_text TEXT NOT NULL, form_type TEXT NOT NULL)',
    ]) {
      await db.customStatement(ddl);
    }
    repo = HuntRepository(db, StudyRepository(db));
  });

  tearDown(() => db.close());

  Future<HuntPuzzle> pumpBoard(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [huntRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: HuntScreen()),
      ),
    );
    // Generation runs on a real isolate and the lexicon comes off disk, so
    // wait on wall-clock time rather than the fake clock.
    for (var i = 0; i < 400 && find.byType(GridView).evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
    expect(find.byType(GridView), findsOneWidget);
    return (await repo.loadOrGenerate())!.puzzle;
  }

  Offset centreOf(WidgetTester tester, int cell) {
    final grid = tester.getRect(find.byType(GridView));
    final size = grid.width / huntSize;
    return grid.topLeft + Offset((cell % huntSize + 0.5) * size, (cell ~/ huntSize + 0.5) * size);
  }

  testWidgets('tapping a path submits the word; a pan traces one', (tester) async {
    await tester.runAsync(() async {
      final puzzle = await pumpBoard(tester);
      expect(find.text('0 / ${puzzle.requiredCount} words'), findsOneWidget);

      // Tap along a main word, then the last tile again to submit.
      final word = puzzle.main.keys.first;
      final path = puzzle.main[word]!.path;
      for (final cell in path) {
        await tester.tapAt(centreOf(tester, cell));
        await tester.pump();
      }
      expect(find.text(word), findsOneWidget, reason: 'the trace shows the letters so far');
      await tester.tapAt(centreOf(tester, path.last));
      await tester.pump();
      expect(find.text('+${word.length}'), findsOneWidget);
      expect(find.text('1 / ${puzzle.requiredCount} words'), findsOneWidget);
      expect(find.text(word.toLowerCase()), findsOneWidget);

      // Tracing it again is a duplicate, not a second score.
      final gesture = await tester.startGesture(centreOf(tester, path.first));
      for (final cell in path.skip(1)) {
        await gesture.moveTo(centreOf(tester, cell));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      expect(find.text('Already found'), findsOneWidget);
      expect(find.text('1 / ${puzzle.requiredCount} words'), findsOneWidget);

      // A second word by pan.
      final other = puzzle.main.keys.skip(1).first;
      final otherPath = puzzle.main[other]!.path;
      final pan = await tester.startGesture(centreOf(tester, otherPath.first));
      for (final cell in otherPath.skip(1)) {
        await pan.moveTo(centreOf(tester, cell));
        await tester.pump();
      }
      await pan.up();
      await tester.pump();
      expect(find.text('2 / ${puzzle.requiredCount} words'), findsOneWidget);

      // Progress was written.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final saved = (await repo.loadPuzzle((await repo.loadOrGenerate())!.id))!;
      expect(saved.found, {word, other});

      // Feedback clears itself.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await tester.pump();
      expect(find.text('Already found'), findsNothing);
    });
  });

  testWidgets('revealing everything completes the board with help', (tester) async {
    await tester.runAsync(() async {
      final puzzle = await pumpBoard(tester);
      await tester.tap(find.byTooltip('More'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Reveal everything'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // First assist on a board asks whether to give up the clean solve.
      expect(find.textContaining('marks this board as assisted'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Reveal everything'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Board complete'), findsOneWidget);
      expect(find.textContaining('(${puzzle.requiredCount} revealed)'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pump();
      expect(find.textContaining('with help'), findsOneWidget);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      final entry = (await repo.history()).single;
      expect(entry.play.completed, isTrue);
      expect(entry.play.aided, isTrue);
    });
  });
}

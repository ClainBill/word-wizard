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
      'CREATE TABLE dict.spelling_variants (variant TEXT NOT NULL, headword TEXT NOT NULL, label TEXT NOT NULL, PRIMARY KEY (variant, headword))',
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

  /// Pans a finger along [path], the way a word is found.
  Future<void> trace(WidgetTester tester, List<int> path) async {
    final pan = await tester.startGesture(centreOf(tester, path.first));
    for (final cell in path.skip(1)) {
      await pan.moveTo(centreOf(tester, cell));
      await tester.pump();
    }
    await pan.up();
    await tester.pump();
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

  testWidgets('a hint marks a word\'s start tile and is paid for from the budget', (tester) async {
    await tester.runAsync(() async {
      final puzzle = await pumpBoard(tester);
      expect(find.byTooltip('Hint ($huntStartingHints left)'), findsOneWidget);

      await tester.tap(find.byTooltip('Hint ($huntStartingHints left)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('marks this board as assisted'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Use a hint'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byTooltip('Hint (${huntStartingHints - 1} left)'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget);
      expect(find.textContaining('word starts at the arrow'), findsOneWidget);

      // The hint survives a reload, and the word it points at is the one
      // whose start tile carries the arrow.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final saved = (await repo.loadPuzzle((await repo.loadOrGenerate())!.id))!;
      expect(saved.hintsUsed, 1);
      expect(saved.hints, hasLength(1));
      expect(saved.hinted, isTrue);
      final word = saved.hints.single;
      final start = puzzle.wordInfo(word)!.path.first;
      final arrow = tester.getCenter(find.byIcon(Icons.arrow_forward_rounded));
      final grid = tester.getRect(find.byType(GridView));
      final size = grid.width / huntSize;
      expect(((arrow.dx - grid.left) / size).floor(), start % huntSize);
      expect(((arrow.dy - grid.top) / size).floor(), start ~/ huntSize);

      // Finding the hinted word clears its arrow. The hint is spent: the
      // rest of the budget only grows with bonus words.
      final path = puzzle.wordInfo(word)!.path;
      final pan = await tester.startGesture(centreOf(tester, path.first));
      for (final cell in path.skip(1)) {
        await pan.moveTo(centreOf(tester, cell));
        await tester.pump();
      }
      await pan.up();
      await tester.pump();
      expect(find.byIcon(Icons.arrow_forward_rounded), findsNothing);
      expect(find.byTooltip('Hint (${huntStartingHints - 1} left)'), findsOneWidget);

      // Spending the rest leaves none, and the button says so.
      for (var i = huntStartingHints - 1; i > 0; i--) {
        await tester.tap(find.byTooltip('Hint ($i left)'));
        await tester.pump();
      }
      expect(find.byTooltip('Hint (0 left)'), findsOneWidget);
      await tester.tap(find.byTooltip('Hint (0 left)'));
      await tester.pump();
      expect(find.textContaining('No hints left'), findsOneWidget);
    });
  });

  testWidgets('finding half the words unlocks the counter with a popup', (tester) async {
    await tester.runAsync(() async {
      final puzzle = await pumpBoard(tester);
      final required = [...puzzle.anchorWords.keys, ...puzzle.main.keys];
      final half = (required.length + 1) ~/ 2;
      // Well short of half there are no counts and no announcement.
      expect(find.text('Halfway there!'), findsNothing);
      expect(find.textContaining('Left: '), findsNothing);

      // Reach half by tracing required words one at a time.
      for (var i = 0; i < half; i++) {
        await trace(tester, puzzle.wordInfo(required[i])!.path);
        await tester.pump(const Duration(milliseconds: 400));
        if (i < half - 1) {
          expect(find.text('Halfway there!'), findsNothing, reason: 'not yet at half after ${i + 1}');
        }
      }
      expect(find.text('Halfway there!'), findsOneWidget);
      expect(find.textContaining('unlocks the word counter'), findsOneWidget);
      await tester.tap(find.text('Keep going'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Halfway there!'), findsNothing);
      expect(find.textContaining('Left: '), findsOneWidget);

      // Announced once: persisted, so a reload doesn't repeat it.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final saved = (await repo.loadPuzzle((await repo.loadOrGenerate())!.id))!;
      expect(saved.halfwayAnnounced, isTrue);
    });
  });

  testWidgets('there is no way to reveal a word', (tester) async {
    await tester.runAsync(() async {
      await pumpBoard(tester);
      expect(find.byTooltip('Reveal'), findsNothing);
      await tester.tap(find.byTooltip('More'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Reveal'), findsNothing);
      expect(find.text('New board'), findsOneWidget);
    });
  });

  testWidgets('finding every required word completes the board cleanly', (tester) async {
    await tester.runAsync(() async {
      final puzzle = await pumpBoard(tester);
      for (final word in [...puzzle.anchorWords.keys, ...puzzle.main.keys]) {
        await trace(tester, puzzle.wordInfo(word)!.path);
        await tester.pump(const Duration(milliseconds: 400));
        // The halfway popup, and any anchor card, are dismissed as they come.
        if (find.text('Keep going').evaluate().isNotEmpty) {
          await tester.tap(find.text('Keep going'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        }
      }
      expect(find.text('Board complete'), findsOneWidget);
      expect(find.textContaining('revealed'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pump();
      expect(find.textContaining('with help'), findsNothing);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      final entry = (await repo.history()).single;
      expect(entry.play.completed, isTrue);
      expect(entry.play.aided, isFalse);
    });
  });

  testWidgets('tapping a hinted tile repeats the word\'s length', (tester) async {
    await tester.runAsync(() async {
      final puzzle = await pumpBoard(tester);
      await tester.tap(find.byTooltip('Hint ($huntStartingHints left)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(FilledButton, 'Use a hint'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final word = (await repo.loadPuzzle((await repo.loadOrGenerate())!.id))!.hints.single;
      final start = puzzle.wordInfo(word)!.path.first;

      // The hint's message fades on its own…
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await tester.pump();
      expect(find.textContaining('word starts at the arrow'), findsNothing);

      // …and comes back when the arrowed tile is tapped, as the trace starts.
      await tester.tapAt(centreOf(tester, start));
      await tester.pump();
      expect(find.text('${word.length}-letter word starts at the arrow'), findsOneWidget);

      // A tile without a hint says nothing.
      final other = List.generate(huntCells, (i) => i).firstWhere((c) => c != start);
      await tester.tapAt(centreOf(tester, other));
      await tester.pump();
      expect(find.textContaining('word starts at the arrow'), findsNothing);
    });
  });

  testWidgets('a hint arrow turns with the board', (tester) async {
    await tester.runAsync(() async {
      final puzzle = await pumpBoard(tester);
      await tester.tap(find.byTooltip('Hint ($huntStartingHints left)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(FilledButton, 'Use a hint'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final word = (await repo.loadPuzzle((await repo.loadOrGenerate())!.id))!.hints.single;
      final start = puzzle.wordInfo(word)!.path.first;

      await tester.tap(find.byTooltip('Rotate right'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      // One quarter turn clockwise: board (row, col) is shown at
      // (col, size-1-row). The arrow is still on the hinted word's tile, and
      // still exactly one — no tile picked up a stray tint or arrow.
      final grid = tester.getRect(find.byType(GridView));
      final size = grid.width / huntSize;
      expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget);
      final arrow = tester.getCenter(find.byIcon(Icons.arrow_forward_rounded));
      expect(((arrow.dx - grid.left) / size).floor(), huntSize - 1 - start ~/ huntSize);
      expect(((arrow.dy - grid.top) / size).floor(), start % huntSize);
      // Lets the hint's save land before the database is closed.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });
}

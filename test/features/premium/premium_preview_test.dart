import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/features/premium/premium_preview.dart';

void main() {
  test('the demo mini is a genuine grid: symmetric blacks, across and down all as listed', () {
    String at(int r, int c) => demoGrid[r][c];
    // Rotational symmetry of the black squares, as in a real crossword.
    for (var r = 0; r < 5; r++) {
      for (var c = 0; c < 5; c++) {
        expect(at(r, c) == '#', at(4 - r, 4 - c) == '#', reason: 'black at $r,$c');
      }
    }
    expect(demoGrid.join().contains('#'), isTrue);
    for (final (_, r, c, answer, _) in demoAcross) {
      expect([for (var i = 0; i < answer.length; i++) at(r, c + i)].join(), answer);
    }
    for (final (_, r, c, answer) in demoDown) {
      expect([for (var i = 0; i < answer.length; i++) at(r + i, c)].join(), answer);
    }
    final across = {for (final w in demoAcross) w.$4};
    final down = {for (final w in demoDown) w.$4};
    expect(across.intersection(down), isEmpty, reason: 'across and down must differ');
    // Every white cell belongs to an across word (the fill covers the grid).
    final covered = {
      for (final (_, r, c, answer, _) in demoAcross)
        for (var i = 0; i < answer.length; i++) (r, c + i),
    };
    for (var r = 0; r < 5; r++) {
      for (var c = 0; c < 5; c++) {
        if (at(r, c) != '#') expect(covered.contains((r, c)), isTrue);
      }
    }
  });

  test('every demo hunt word is spelt by its path, and each step is adjacent', () {
    for (final (word, path) in demoHuntWords) {
      expect([for (final i in path) demoBoard[i ~/ 4][i % 4]].join(), word);
      for (var k = 1; k < path.length; k++) {
        final (r1, c1) = (path[k - 1] ~/ 4, path[k - 1] % 4);
        final (r2, c2) = (path[k] ~/ 4, path[k] % 4);
        expect((r1 - r2).abs() <= 1 && (c1 - c2).abs() <= 1, isTrue, reason: '$word step $k');
      }
    }
  });

  testWidgets('animates: letters appear over time, and the clue follows the row', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox(width: 300, child: PremiumPreview()))),
    );
    await tester.pump();
    expect(find.text('1A · Existed, once'), findsOneWidget);
    expect(find.text('H'), findsNothing); // nothing typed yet (no H on the hunt board)
    await tester.pump(const Duration(milliseconds: 150 * 10));
    expect(find.text('H'), findsOneWidget);
    expect(find.text('6A · Worn out'), findsOneWidget);
    // The hunt has traced its first word by now and is holding it lit.
    expect(find.text('WORD ✓'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Solved · 0:41'), findsOneWidget);
  });

  testWidgets('reduced motion: the finished state, no ticking', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Scaffold(body: SizedBox(width: 300, child: PremiumPreview())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Solved · 0:41'), findsOneWidget);
    expect(find.text('EARN ✓'), findsOneWidget);
  });
}

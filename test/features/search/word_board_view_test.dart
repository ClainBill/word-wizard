import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/board/word_board.dart';
import 'package:word_wizard/features/search/word_board_view.dart';

Future<void> pump(
  WidgetTester tester, {
  required List<String> opened,
  bool animate = false,
  Map<String, Familiarity> familiarity = const {},
  List<String> words = const ['candor', 'lucid', 'glint', 'ennui', 'zephyr', 'ice cream'],
}) {
  return tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: !animate),
      child: MaterialApp(
        home: Scaffold(
          body: WordBoardView(
            seed: 'serendipity',
            seedCaption: 'Word of the day',
            words: words,
            familiarity: familiarity,
            onOpen: opened.add,
            onShuffle: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('with animations off the whole board is there at once, and a tap opens the seed', (
    tester,
  ) async {
    final opened = <String>[];
    await pump(tester, opened: opened);
    await tester.pump();
    // The canvas is centred on the seed, so the middle of the screen is
    // a tile of it.
    await tester.tap(find.byType(CustomPaint).first, warnIfMissed: false);
    await tester.pumpAndSettle();
    // That tile may be a crossing, in which case a sheet asks which word.
    if (find.byType(ListTile).evaluate().isNotEmpty) {
      expect(find.byType(ListTile), findsNWidgets(2));
      await tester.tap(find.widgetWithText(ListTile, 'serendipity'));
      await tester.pumpAndSettle();
    }
    expect(opened, ['serendipity']);
    expect(find.text('in your Lexery'), findsOneWidget);
    expect(find.byTooltip('New words'), findsOneWidget);
  });

  testWidgets('the board grows a word at a time and stops on its own', (tester) async {
    final opened = <String>[];
    await pump(tester, opened: opened, animate: true);
    // Long enough for a pool this size to be placed and animated in; the
    // ticker must have stopped by then or pumpAndSettle would time out.
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 20),
    );
    expect(tester.hasRunningAnimations, isFalse);
  });
}

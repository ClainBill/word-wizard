import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/board/word_board.dart';

void main() {
  test('the seed sits across the middle', () {
    final board = WordBoard(size: 11);
    expect(board.placeSeed('lucid'), isTrue);
    expect(board.placeSeed('again'), isFalse, reason: 'one seed only');
    final w = board.words.single;
    expect(w.row, 5);
    expect(w.col, 3);
    expect(board.letterAt(5, 3), 'l');
    expect(board.letterAt(5, 7), 'd');
    expect(board.wordsAt(5, 5), [w]);
  });

  test('a word crosses the seed on a shared letter and runs the other way', () {
    final board = WordBoard(size: 15)..placeSeed('lucid');
    final placed = board.tryPlace('candor', random: Random(1));
    expect(placed, isNotNull);
    expect(placed!.across, isFalse);
    // Crosses on the c or the d.
    final shared = board.wordsAt(placed.rowAt(0), placed.colAt(0)).length == 2
        ? placed.word[0]
        : null;
    var crossings = 0;
    for (var i = 0; i < placed.length; i++) {
      if (board.wordsAt(placed.rowAt(i), placed.colAt(i)).length == 2) {
        crossings++;
        expect('lucid'.contains(placed.word[i]), isTrue);
      }
    }
    expect(crossings, 1);
    expect(shared, anyOf(isNull, 'c'));
  });

  test('crossword rules: nothing side by side, nothing touching an end', () {
    final board = WordBoard(size: 15)..placeSeed('lucid');
    // lucid at row 7, cols 5..9. "did" down from the d at (7,9) is fine…
    expect(board.canPlace('did', row: 7, col: 9, across: false), isTrue);
    // …but hanging off the end of the word, or one column past it, isn't.
    expect(board.canPlace('add', row: 6, col: 10, across: false), isFalse);
    expect(board.canPlace('dad', row: 7, col: 9, across: true), isFalse);
    // A word crossing through 'u' whose other letters would sit beside
    // the seed's neighbours is blocked once something is next to it.
    board.tryPlace('did', random: Random(1), anchors: board.words);
    // Another across word directly under the seed would read letter by letter.
    expect(board.canPlace('cat', row: 8, col: 5, across: true), isFalse);
    // Overlapping the seed in the same direction isn't a crossing.
    expect(board.canPlace('lucid', row: 7, col: 5, across: true), isFalse);
    // Mismatched letter at the crossing.
    expect(board.canPlace('xyz', row: 6, col: 6, across: false), isFalse);
  });

  test('the grower spreads outward and stops when nothing fits', () {
    final board = WordBoard(size: 25)..placeSeed('serendipity');
    final grower = WordBoardGrower(
      board,
      pool: ['candor', 'lucid', 'glint', 'ennui', 'zephyr', 'quixotic', 'nadir', 'ember', 'kkk'],
      random: Random(7),
    );
    var placed = 0;
    while (!grower.exhausted) {
      if (grower.next() != null) placed++;
    }
    expect(placed, greaterThanOrEqualTo(6));
    expect(board.words.length, placed + 1);
    expect(board.words.map((w) => w.word), isNot(contains('kkk')));
    // Every word after the seed crosses at least one other.
    for (final w in board.words.skip(1)) {
      expect(board.crossings(w), greaterThanOrEqualTo(1), reason: w.word);
    }
    final b = board.bounds!;
    expect(b.bottom - b.top, greaterThan(2), reason: 'grew vertically too');
  });

  test('isBoardable keeps to plain lowercase words of a playable length', () {
    expect(isBoardable('lucid'), isTrue);
    expect(isBoardable('ad'), isFalse);
    expect(isBoardable('ice cream'), isFalse);
    expect(isBoardable('Paris'), isFalse);
    expect(isBoardable('antidisestablishment'), isFalse);
  });
}

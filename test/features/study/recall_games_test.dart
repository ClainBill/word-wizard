import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/models/study_card.dart';
import 'package:word_wizard/domain/models/study_direction.dart';
import 'package:word_wizard/domain/srs/sm2.dart';
import 'package:word_wizard/features/study/recall_games.dart';

StudyCard _card({
  required String headword,
  String? gloss,
  String? example,
}) =>
    StudyCard(
      cardId: 1,
      entryId: 1,
      headword: headword,
      pos: 'adjective',
      gloss: gloss,
      example: example,
      direction: StudyDirection.wordToMeaning,
      srs: StudyCardState.initial,
      dueAt: DateTime(2026, 1, 1),
    );

void main() {
  group('game/target split', () {
    test('word games never appear when the meaning is what is missing', () {
      // The bug this whole change is about: a word → meaning card asks for
      // the meaning, so a spelling or letter-reveal game — with the word
      // already on screen — is not a memory jog.
      final games = availableGames(
        _card(headword: 'abstruse', gloss: 'difficult to understand or grasp', example: 'An abstruse argument.'),
        RecallTarget.meaning,
      );
      expect(games, isNotEmpty);
      for (final game in games) {
        expect(game.target, RecallTarget.meaning);
      }
    });

    test('meaning games never appear when the word is what is missing', () {
      final games = availableGames(
        _card(headword: 'abstruse', gloss: 'difficult to understand or grasp', example: 'An abstruse argument.'),
        RecallTarget.word,
      );
      expect(games, isNotEmpty);
      for (final game in games) {
        expect(game.target, RecallTarget.word);
      }
    });

    test('every card with a gloss can always be asked for its meaning', () {
      // meaningCards only needs a gloss, so the meaning side never runs out
      // of games however sparse the entry is.
      final games = availableGames(_card(headword: 'x', gloss: 'a thing'), RecallTarget.meaning);
      expect(games, contains(RecallGameKind.meaningCards));
    });
  });

  group('availability', () {
    test('cloze needs the word to actually appear in its own example', () {
      final absent = _card(
        headword: 'run',
        gloss: 'to move quickly on foot',
        example: 'She sprinted for the bus.',
      );
      expect(availableGames(absent, RecallTarget.word), isNot(contains(RecallGameKind.cloze)));

      final present = _card(
        headword: 'run',
        gloss: 'to move quickly on foot',
        example: 'She had to run for the bus.',
      );
      expect(availableGames(present, RecallTarget.word), contains(RecallGameKind.cloze));
    });

    test('a paragraph-long citation is not offered as a few-seconds game', () {
      final wall = _card(
        headword: 'serendipity',
        gloss: 'a fortunate accident',
        example: 'serendipity ${'and so on ' * 60}',
      );
      final games = availableGames(wall, RecallTarget.word);
      expect(games, isNot(contains(RecallGameKind.cloze)));
      expect(availableGames(wall, RecallTarget.meaning), isNot(contains(RecallGameKind.sentenceFit)));
    });

    test('a long headword is kept out of the anagram tray', () {
      final long = _card(headword: 'incomprehensibility', gloss: 'the state of being unclear');
      expect(availableGames(long, RecallTarget.word), isNot(contains(RecallGameKind.anagram)));
      // ...but the letter-tile game still works, so the word side is covered.
      expect(availableGames(long, RecallTarget.word), contains(RecallGameKind.letterTiles));
    });
  });

  group('glossChunks', () {
    test('rejects a definition too short to reorder', () {
      expect(glossChunks('a fortunate accident'), isNull);
      expect(glossChunks(''), isNull);
    });

    test('rejects a definition too long to be quick', () {
      expect(glossChunks('word ' * 40), isNull);
    });

    test('chunks rejoin to the original definition', () {
      const gloss = 'difficult to understand or grasp without careful study';
      final chunks = glossChunks(gloss)!;
      expect(chunks.length, greaterThanOrEqualTo(2));
      expect(chunks.join(' '), gloss);
    });

    test('never emits an empty chunk', () {
      const gloss = 'of or relating to the study of the origin of words';
      for (final chunk in glossChunks(gloss)!) {
        expect(chunk.trim(), isNotEmpty);
      }
    });
  });
}

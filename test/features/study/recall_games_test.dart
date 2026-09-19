import 'dart:math';

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

    test('an example that gives the word away in another form is not quizzed on', () {
      final leaky = _card(
        headword: 'thunder',
        gloss: 'a loud rumbling noise',
        example: 'The train thundered along the tracks as the thunder shook the house.',
      );
      expect(availableGames(leaky, RecallTarget.word), isNot(contains(RecallGameKind.cloze)));
      expect(availableGames(leaky, RecallTarget.meaning), isNot(contains(RecallGameKind.sentenceFit)));
    });

    test('a fragment that means nothing with a gap in it is not quizzed on', () {
      final fragment = _card(headword: 'tan', gloss: 'a yellowish-brown colour', example: 'a tan suit');
      expect(availableGames(fragment, RecallTarget.word), isNot(contains(RecallGameKind.cloze)));
      expect(availableGames(fragment, RecallTarget.meaning), isNot(contains(RecallGameKind.sentenceFit)));
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

  group('spellingKeys', () {
    test('holds every letter of the word once, plus decoys, in alphabetical order', () {
      final keys = spellingKeys('letter', Random(1));
      expect(keys.toSet(), containsAll(['l', 'e', 't', 'r']));
      expect(keys.toSet().length, keys.length, reason: 'no key twice, whatever the word repeats');
      expect(keys, [...keys]..sort());
      // 4 own letters + (4 ~/ 2 + 4) decoys.
      expect(keys.length, 10);
    });

    test('decoys are common letters and vary between deals', () {
      final deals = {for (var i = 0; i < 20; i++) spellingKeys('muse', Random(i)).join()};
      expect(deals.length, greaterThan(1));
      for (final deal in deals) {
        for (final c in deal.split('')) {
          expect('etaoinshrdlcumwfgypbvkjxqz'.indexOf(c), lessThan(20), reason: '$c is a poor decoy');
        }
      }
    });

    test('a word with many distinct letters gets the whole alphabet', () {
      final keys = spellingKeys('unpredictably', Random(3));
      expect(keys.length, 26);
      expect(keys.first, 'a');
      expect(keys.last, 'z');
    });

    test('non-letters in the headword are ignored', () {
      final keys = spellingKeys("ne'er-do-well", Random(0));
      expect(keys, isNot(contains("'")));
      expect(keys, isNot(contains('-')));
      expect(keys.toSet(), containsAll(['n', 'e', 'r', 'd', 'o', 'w', 'l']));
    });
  });
}

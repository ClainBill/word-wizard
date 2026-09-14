import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/data/repositories/study_repository.dart';
import 'package:word_wizard/domain/models/study_card.dart';
import 'package:word_wizard/domain/models/study_direction.dart';
import 'package:word_wizard/domain/srs/sm2.dart';

StudyCard _card(int cardId, int entryId, StudyDirection direction) => StudyCard(
      cardId: cardId,
      entryId: entryId,
      headword: 'word$entryId',
      pos: 'noun',
      direction: direction,
      srs: StudyCardState.initial,
      dueAt: DateTime(2026, 1, 1),
    );

/// The two directions of one word, as they come out of the query: adjacent,
/// because they share a due date and the query orders by it.
List<StudyCard> _bothWays(int entryId) => [
      _card(entryId * 10, entryId, StudyDirection.wordToMeaning),
      _card(entryId * 10 + 1, entryId, StudyDirection.meaningToWord),
    ];

void main() {
  group('StudyDirection storage round-trip', () {
    test('every direction survives a write/read cycle', () {
      for (final direction in StudyDirection.values) {
        expect(StudyDirection.fromStorageKey(direction.storageKey), direction);
      }
    });

    test('an unknown stored value falls back to word → meaning', () {
      // What a row written by a future version, or a hand-edited database,
      // would look like. Reading it must not throw mid-session.
      expect(StudyDirection.fromStorageKey('nonsense'), StudyDirection.wordToMeaning);
    });
  });

  group('StudyDirectionMode', () {
    test('defaults to word → meaning when unset', () {
      expect(StudyDirectionMode.fromStorageKey(null), StudyDirectionMode.wordToMeaning);
      expect(StudyDirectionMode.fromStorageKey('who knows'), StudyDirectionMode.wordToMeaning);
    });

    test('both covers each direction exactly once', () {
      expect(StudyDirectionMode.both.directions, StudyDirection.values.toSet());
      expect(StudyDirectionMode.wordToMeaning.directions, {StudyDirection.wordToMeaning});
      expect(StudyDirectionMode.meaningToWord.directions, {StudyDirection.meaningToWord});
    });
  });

  group('spaceSiblings', () {
    test('separates the two directions of one word', () {
      final queue = StudyRepository.spaceSiblings([
        ..._bothWays(1),
        ..._bothWays(2),
      ]);

      expect(queue.length, 4);
      for (var i = 1; i < queue.length; i++) {
        expect(
          queue[i].entryId,
          isNot(queue[i - 1].entryId),
          reason: 'a word must not be asked twice in a row',
        );
      }
    });

    test('keeps every card exactly once', () {
      final input = [..._bothWays(1), ..._bothWays(2), ..._bothWays(3)];
      final queue = StudyRepository.spaceSiblings(input);
      expect(
        queue.map((c) => c.cardId).toSet(),
        input.map((c) => c.cardId).toSet(),
      );
      expect(queue.length, input.length);
    });

    test('leaves an already-spaced queue in its original order', () {
      final input = [
        _card(1, 1, StudyDirection.wordToMeaning),
        _card(2, 2, StudyDirection.wordToMeaning),
        _card(3, 3, StudyDirection.wordToMeaning),
      ];
      expect(
        StudyRepository.spaceSiblings(input).map((c) => c.cardId),
        [1, 2, 3],
      );
    });

    test('does not drop cards when only one word is left', () {
      // Nothing to interleave with — the last word's two directions have to
      // sit next to each other, and the important thing is that both survive.
      final input = _bothWays(7);
      final queue = StudyRepository.spaceSiblings(input);
      expect(queue.map((c) => c.cardId), [70, 71]);
    });

    test('handles an empty queue', () {
      expect(StudyRepository.spaceSiblings([]), isEmpty);
    });
  });
}

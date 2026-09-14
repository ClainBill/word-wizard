import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/models/entry.dart';
import 'package:word_wizard/domain/study/quiz_example.dart';

void main() {
  group('giveawayPattern', () {
    test('catches inflections and derivatives, not just the headword', () {
      expect(leaksHeadword('creep', 'A creeping sycophant.'), isTrue);
      expect(leaksHeadword('thunder', 'The train thundered along the tracks.'), isTrue);
      expect(leaksHeadword('sap', 'Sapping every last bit of energy.'), isTrue);
      expect(leaksHeadword('carry', 'She carried it home.'), isTrue);
      expect(leaksHeadword('sneeze', 'He sneezed twice.'), isTrue);
      expect(leaksHeadword('slobber', 'Spit-slobbered sprouts.'), isTrue);
      expect(leaksHeadword('kiss off', 'She kissed off the whole idea.'), isTrue);
    });

    test('the exact headword is the gap, not a leak', () {
      expect(leaksHeadword('thunder', 'The thunder rolled across the valley.'), isFalse);
      expect(leaksHeadword('Thunder', 'the THUNDER rolled'), isFalse);
    });

    test('does not flag unrelated words that merely start the same way', () {
      expect(leaksHeadword('cat', 'The category was wrong.'), isFalse);
      expect(leaksHeadword('pen', 'The pendulum swung slowly.'), isFalse);
      expect(leaksHeadword('an', 'And then it ended.'), isFalse);
    });
  });

  group('isStandaloneSentence', () {
    test('accepts an ordinary sentence', () {
      expect(isStandaloneSentence('He forgot that the frying pan was hot and burned his hand.'), isTrue);
      expect(isStandaloneSentence('"Send him off, ref!" yelled Dean from the stands.'), isTrue);
      expect(isStandaloneSentence('[T]he pots would be stacked in a heap and fired[.]'), isTrue);
    });

    test('rejects fragments and label lines', () {
      expect(isStandaloneSentence('a tan suit'), isFalse);
      expect(isStandaloneSentence('to season oneself to a climate'), isFalse);
      expect(isStandaloneSentence('her implied disapproval of the plan'), isFalse);
      expect(isStandaloneSentence('Near-synonyms: taciturn, untalkative, terse, quiet'), isFalse);
      expect(isStandaloneSentence('Holonyms: millimetre < centimetre < decimetre < metre'), isFalse);
      expect(isStandaloneSentence('Oysters are unimuscular.'), isFalse);
    });

    test('rejects joined lists, verse, truncated quotes and debris', () {
      expect(isStandaloneSentence('a gang of sailors; a railroad gang; a labor gang or pool.'), isFalse);
      expect(isStandaloneSentence('So absolute she seems, / And in herself complete.'), isFalse);
      expect(isStandaloneSentence('[…] the tinge of firelight glisking in her hair, and more besides.'), isFalse);
      expect(isStandaloneSentence('Whoſe waves orethrew Buſiris and his Memphian Chivalrie.'), isFalse);
      expect(isStandaloneSentence('Hallo, this is my favorite URL. You can surf and become cash.^([sic])'), isFalse);
      expect(isStandaloneSentence('Let P(D)#61;D²#43;5D#43;6 be the differential operator here.'), isFalse);
    });

    test('rejects a paragraph-long citation', () {
      expect(isStandaloneSentence('The word appears ${'and so on ' * 60}here.'), isFalse);
    });
  });

  group('isModernCitation', () {
    test('uncited examples and post-1970 citations pass; older or unparseable fail', () {
      expect(isModernCitation(null), isTrue);
      expect(isModernCitation('2021 November 30, Aliya Uteuova, The Guardian'), isTrue);
      expect(isModernCitation('1667, John Milton, Paradise Lost'), isFalse);
      expect(isModernCitation('c. 1599–1602, William Shakespeare, Hamlet'), isFalse);
      expect(isModernCitation('King James Bible, Genesis'), isFalse);
    });
  });

  group('isQuizExample', () {
    test('needs the headword present, no leak, and a sentence around it', () {
      expect(isQuizExample('thunder', 'The thunder rolled across the valley all night long.'), isTrue);
      expect(isQuizExample('thunder', 'The storm rolled across the valley all night long.'), isFalse);
      expect(isQuizExample('thunder', 'Thunder thundered as the thunder rolled on.'), isFalse);
      expect(isQuizExample('thunder', 'a clap of thunder'), isFalse);
      expect(
        isQuizExample('thunder', 'The thunder rolled across the valley.', source: '1667, John Milton'),
        isFalse,
      );
    });
  });

  group('pickQuizExample', () {
    test('takes the first usable example in dictionary order', () {
      const examples = [
        Example(id: 1, text: 'a clap of thunder'),
        Example(id: 2, text: 'The train thundered along the tracks; the thunder shook the house.'),
        Example(id: 3, text: 'The thunder rolled across the valley all night long.'),
        Example(id: 4, text: 'We heard the thunder long before the rain arrived.'),
      ];
      expect(pickQuizExample('thunder', examples)?.id, 3);
      expect(pickQuizExample('thunder', examples.take(2)), isNull);
    });
  });

  test('blankHeadword cuts every exact occurrence, case-insensitively', () {
    expect(blankHeadword('thunder', ' Thunder, thunder everywhere. '), '_____, _____ everywhere.');
  });
}

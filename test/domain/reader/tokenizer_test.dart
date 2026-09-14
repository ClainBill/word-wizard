import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/domain/reader/tokenizer.dart';

void main() {
  List<String> words(String text) => [for (final t in tokenize(text)) t.textIn(text)];

  test('strips punctuation and keeps apostrophes and hyphens inside words', () {
    expect(
      words('"Don\'t," she said — it\'s a well-known O\'Brien (really).'),
      ['Don\'t', 'she', 'said', 'it\'s', 'a', 'well-known', 'O\'Brien', 'really'],
    );
  });

  test('curly apostrophes join words the way straight ones do', () {
    expect(words('the word’s meaning'), ['the', 'word’s', 'meaning']);
  });

  test('a dangling hyphen or apostrophe is not part of the word', () {
    expect(words("re- 'quoted' -x"), ['re', 'quoted', 'x']);
  });

  test('digits are not words', () {
    expect(words('in 1066 the 2nd'), ['in', 'the', 'nd']);
  });

  test('splitHyphens returns the parts at their original offsets', () {
    const text = 'a bio-luminescent glow';
    final token = tokenize(text)[1];
    expect(token.textIn(text), 'bio-luminescent');
    final parts = splitHyphens(token, text);
    expect(parts.map((p) => p.textIn(text)), ['bio', 'luminescent']);
    expect(parts.first.start, 2);
    expect(parts.last.end, 17);
    expect(splitHyphens(tokenize(text)[0], text), isEmpty);
  });

  test('countWords agrees with tokenize', () {
    const text = 'One, two; three-four five\'s.';
    expect(countWords(text), tokenize(text).length);
    expect(countWords(text), 4);
  });

  test('fingerprint is stable and content-sensitive', () {
    expect(fingerprint('hello world'), fingerprint('hello world'));
    expect(fingerprint('hello world'), isNot(fingerprint('hello world!')));
    expect(fingerprint(''), isNotEmpty);
  });
}

/// One word's position inside a block's flattened text.
class WordToken {
  final int start;
  final int end;

  const WordToken(this.start, this.end);

  String textIn(String source) => source.substring(start, end);

  @override
  bool operator ==(Object other) => other is WordToken && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'WordToken($start, $end)';
}

// A word is a run of letters, optionally joined by apostrophes or hyphens to
// more letters — so "don't", "O'Brien" and "well-known" stay whole (all of
// which the dictionary files as single headwords) while "word." and
// "(word)" shed their punctuation. Curly apostrophes count too: that's what
// most copied prose actually contains.
final _wordPattern = RegExp("[A-Za-z]+(?:[-'’][A-Za-z]+)*");

/// Every word in [text], in order, as offset ranges into it.
List<WordToken> tokenize(String text) =>
    [for (final m in _wordPattern.allMatches(text)) WordToken(m.start, m.end)];

/// The pieces of a hyphenated token, for a second lookup attempt when the
/// compound itself isn't a headword ("bio-luminescent" → "bio",
/// "luminescent"). A token with no hyphen splits into nothing.
List<WordToken> splitHyphens(WordToken token, String text) {
  final word = token.textIn(text);
  if (!word.contains('-')) return const [];
  final parts = <WordToken>[];
  var start = token.start;
  for (final piece in word.split('-')) {
    if (piece.isNotEmpty) parts.add(WordToken(start, start + piece.length));
    start += piece.length + 1;
  }
  return parts;
}

/// The count [ReaderDocument.wordCount] stores — words as the tokenizer sees
/// them, so the number on the page matches what's tappable.
int countWords(String text) => _wordPattern.allMatches(text).length;

/// A stable fingerprint of some text, for spotting the same clipboard
/// contents twice. Dart's `String.hashCode` isn't guaranteed stable between
/// runs, and this has to survive a restart; 64-bit FNV-1a over the code
/// units is plenty for "is this the thing I already imported". Relies on
/// the VM's wrapping 64-bit multiply, which is what the native build has.
String fingerprint(String text) {
  var hash = 0xcbf29ce484222325;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash *= 0x100000001b3;
  }
  return hash.toRadixString(16);
}

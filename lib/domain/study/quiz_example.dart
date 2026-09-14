/// Whether an example sentence can carry a "what's the missing word?"
/// question — the cloze and sentence-fit recall games, the crossword's
/// fill-in-the-blank clue, and the study card's own example slot.
///
/// Two things disqualify a Wiktionary example, and both are common enough
/// in the bundled data that the first version of the games hit them daily:
///
/// * **It gives the word away.** Cutting the headword out is no use when an
///   inflected or derived form is still sitting in the sentence: "creep"
///   quizzed with "A creeping sycophant.", "thunder" with "The train
///   thundered along the tracks." A whole-word match on the exact headword
///   sails straight past those.
/// * **It means nothing on its own.** A large share of uncited examples are
///   fragments ("a tan suit", "to season oneself to a climate"), label lines
///   Wiktionary files as examples ("Near-synonyms: taciturn, terse"),
///   several examples joined with semicolons, poetry with line breaks, or
///   quotes old enough to read as a foreign language (long-s Milton). With a
///   gap in it, "a ___ suit" is a guess, not a recall.
library;

import '../models/entry.dart';

/// Wiktionary's `source` citation for a quoted example starts with the
/// work's year ("1886 October – 1887 January, H. Rider Haggard, She: […]",
/// "1650, Thomas Browne, […]"), optionally prefixed "c." or "a." for an
/// approximate/uncertain date. Citations that don't match this leading-year
/// shape are overwhelmingly pre-1900 (Shakespeare, King James Bible,
/// medieval poetry), so an unparseable citation is treated as an old one.
/// A `null` source (an invented, uncited example — about 80% of the bundled
/// dictionary's examples) is assumed modern.
final _sourceYear = RegExp(r'^(?:c\.\s*|a\.\s*)?(\d{4})');
const _minModernExampleYear = 1970;

bool isModernCitation(String? source) {
  if (source == null) return true;
  final match = _sourceYear.firstMatch(source);
  if (match == null) return false;
  return int.parse(match.group(1)!) >= _minModernExampleYear;
}

/// Bounds for a sentence that reads at a glance. Wiktionary examples range
/// from a two-word fragment to a full quoted paragraph (seen live on
/// "serendipity": Horace Walpole's ~1300-character coinage letter).
const minQuizExampleLength = 20;
const maxQuizExampleLength = 200;
const _minWords = 5;
const _minOtherWords = 4;

// "Near-synonyms: …", "Holonyms: …", "Coordinate term: …", "Age
// Suitability: …" — a leading label followed by a colon.
final _labelLine = RegExp(r'^[A-Za-z][A-Za-z -]{0,24}:\s');
// Opens like a sentence: an optional quote/bracket, then a capital.
final _opener = RegExp('^["\'“‘(\\[]*[A-Z]');
// Closes like one: terminal punctuation, optionally inside a closing
// quote/bracket ("…the clamp would be fired[.]" is Wiktionary's own edit
// mark and reads fine).
final _closer = RegExp('[.!?]["\'”’)\\]]*\$');
final _url = RegExp(r'https?://|www\.');
// Elision marks and HTML-entity debris (the "#92;" the pipeline leaves
// behind on TeX-heavy maths examples).
final _debris = RegExp(r'…|\.\.\.|#\d+;|\^\(');
final _word = RegExp("[A-Za-z][A-Za-z'’-]*");

/// Whether [text] is a self-contained sentence of reasonable length —
/// independent of any headword. Tuned against the bundled dictionary: on a
/// random sample it keeps ~2 in 5 examples, and what it drops is
/// overwhelmingly fragments, label lines, joined lists and truncated quotes.
bool isStandaloneSentence(String text) {
  final t = text.trim();
  if (t.length < minQuizExampleLength || t.length > maxQuizExampleLength) return false;
  if (t.contains('\n') || t.contains(' / ')) return false; // verse
  if (t.contains('ſ')) return false; // long s: pre-1800 typography
  if (_labelLine.hasMatch(t)) return false;
  if (';'.allMatches(t).length >= 2) return false; // "a gang of sailors; a railroad gang; …"
  if (_url.hasMatch(t) || _debris.hasMatch(t)) return false;
  if (!_opener.hasMatch(t) || !_closer.hasMatch(t)) return false;
  final words = _word.allMatches(t).map((m) => m.group(0)!).toList();
  if (words.length < _minWords) return false;
  // Mostly letters, so a formula or a heraldic blazon can't sneak in.
  final letters = words.fold<int>(0, (n, w) => n + w.length);
  return letters / t.length >= 0.6;
}

/// The whole-word, case-insensitive match for [headword] exactly as written
/// — the form a cloze gap replaces.
RegExp headwordPattern(String headword) =>
    RegExp(r'\b' + RegExp.escape(headword.trim()) + r'\b', caseSensitive: false);

// Suffixes an English word grows when inflected or derived. Applied to the
// headword's stem *variants* below, so "carry" catches "carried" and "sap"
// catches "sapping" as well as the plain "carrys"/"saping" spellings a
// naïve headword+suffix would look for.
const _suffixes = 's|es|ed|ing|er|ers|est|ly|y|ies|ied|ier|iest|ness|ment|ments|'
    'able|ible|ion|ions|tion|ation|ive|al|ful|less|ish|ist|ism|ity|ous|ise|ize|ised|ized';

String _wordVariants(String word) {
  final w = RegExp.escape(word);
  // Too short to have a stem worth the name: "an" + "d" is not a form of
  // "an". Only the word itself counts.
  if (word.length < 3) return w;
  final variants = <String>{w};
  final stem = RegExp.escape(word.substring(0, word.length - 1));
  final last = word[word.length - 1];
  // sneeze → sneez-ing, carry → carri-ed, sap → sapp-ing.
  if (last == 'e') variants.add(stem);
  if (last == 'y') variants.add('${stem}i');
  if (RegExp('[b-df-hj-np-tv-z]').hasMatch(last)) variants.add('$w$last');
  return '(?:${variants.join('|')})(?:$_suffixes)?';
}

/// Every form of [headword] that would give it away in a sentence: the
/// word itself plus its inflections and common derivatives, as whole words.
/// A multi-word headword ("kiss off") allows each of its words to inflect
/// ("kissed off"). Case-insensitive.
RegExp giveawayPattern(String headword) {
  final words = headword.trim().toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return RegExp(r'\b' + words.map(_wordVariants).join(r'\s+') + r'\b', caseSensitive: false);
}

/// Whether [text] still hints at [headword] once every exact occurrence is
/// cut out — an inflection, a derivative, or a compound half.
bool leaksHeadword(String headword, String text) =>
    giveawayPattern(headword).hasMatch(text.replaceAll(headwordPattern(headword), ' '));

/// Whether [text] can be quizzed on for [headword]: it reads as a sentence,
/// contains the headword as written (so there is something to blank),
/// doesn't leak it through some other form, and — with the citation's
/// [source] — is modern enough to read as English rather than as a period
/// piece. A sentence that is *only* the headword and filler ("Oysters are
/// unimuscular.") is also out: with the gap in it there is nothing left to
/// reason from.
bool isQuizExample(String headword, String text, {String? source}) {
  final hw = headword.trim();
  if (hw.isEmpty || !isModernCitation(source) || !isStandaloneSentence(text)) return false;
  final exact = headwordPattern(hw);
  if (!exact.hasMatch(text)) return false;
  final remainder = text.replaceAll(exact, ' ');
  if (giveawayPattern(hw).hasMatch(remainder)) return false;
  return _word.allMatches(remainder).length >= _minOtherWords;
}

/// The first of [examples] that passes [isQuizExample], or null. Dictionary
/// order is kept so the pick is stable across sessions for the same card.
Example? pickQuizExample(String headword, Iterable<Example> examples) {
  for (final example in examples) {
    if (isQuizExample(headword, example.text, source: example.source)) return example;
  }
  return null;
}

/// [text] with every exact occurrence of [headword] replaced by [gap].
String blankHeadword(String headword, String text, {String gap = '_____'}) =>
    text.trim().replaceAll(headwordPattern(headword), gap);

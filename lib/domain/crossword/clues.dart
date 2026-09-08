/// Clue vetting — PORTING_SPEC.md §8.
///
/// The spec's own clue *generation* (WordNet's first gloss, capitalized,
/// with a part-of-speech marker) is the part it tells you to throw away:
/// "the weakest part of the system and you should expect to replace it",
/// and §A.4 ranks replacing it as the single highest-impact fix available.
/// This app already has a better source — the bundled Wiktionary dictionary,
/// which yields definition, synonym, "___, for short" and fill-in-the-blank
/// phrasings drawn from each word's earliest senses — so clue text is
/// resolved there (`DictionaryDatabase.crosswordClueOptions`) for the ~40-90
/// words that actually land in a grid.
///
/// What is ported verbatim is the part §8 says is worth porting exactly: the
/// giveaway filter, which needs no NLP and catches a clue that leaks its own
/// answer.
library;

final _wordToken = RegExp(r"[A-Za-z']+");

const _affixes = ['s', 'es', 'ing', 'ed', 'er', 'ers', 'ly', 'tion', 'y'];

/// The answer plus naive suffix strips and additions, all lowercase.
Set<String> _answerVariants(String answer) {
  final lower = answer.toLowerCase();
  final variants = <String>{lower};
  for (final affix in _affixes) {
    variants.add('$lower$affix');
    if (lower.length > affix.length && lower.endsWith(affix)) {
      variants.add(lower.substring(0, lower.length - affix.length));
    }
  }
  return variants;
}

/// True if [clueText] leaks [answerText] — an exact or inflected restatement,
/// or a substring relationship long enough not to be a coincidence.
///
/// Both length guards matter. Without the `>= 5` on the clue token, a clue
/// word like "cat" inside an unrelated answer trips it; without the `>= 5` on
/// the answer, the short answer CAT is flagged by the innocent clue word
/// "domesticated".
bool isGiveaway(String clueText, String answerText) {
  final answer = answerText.toLowerCase();
  final variants = _answerVariants(answerText);

  for (final match in _wordToken.allMatches(clueText)) {
    final token = match.group(0)!.replaceAll("'", '').toLowerCase();
    if (token.length < 3) continue;
    if (variants.contains(token)) return true;
    if (token.length >= 5 && answer.contains(token)) return true;
    if (answer.length >= 5 && token.contains(answer)) return true;
  }
  return false;
}

/// 1 (easy) to 5 (hard), from the rarity of the clue's own vocabulary —
/// rarer clue wording reads as harder (§8).
///
/// [zipfOf] resolves a lowercase word to its Zipf frequency, or null if the
/// word list doesn't carry it.
double clueDifficulty(String clueText, double? Function(String) zipfOf) {
  var total = 0.0;
  var count = 0;
  for (final match in _wordToken.allMatches(clueText)) {
    final token = match.group(0)!.replaceAll("'", '').toLowerCase();
    if (token.length <= 2) continue;
    final zipf = zipfOf(token);
    if (zipf == null) continue;
    total += zipf;
    count++;
  }
  if (count == 0) return 3;
  final mean = total / count;
  return (6.0 - mean).clamp(1, 5);
}

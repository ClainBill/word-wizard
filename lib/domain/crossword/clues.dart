import 'dart:math';

import 'crossword_models.dart';

/// Clue selection and vetting — PORTING_SPEC.md §8.
///
/// Clue *text* is baked into the asset at build time (§2.5), so runtime has
/// no NLP to do: it picks among the one or two options an entry carries. What
/// it still has to do is choose well, and refuse a clue that gives its answer
/// away — the gate below is also what every edit the editorial pass proposes
/// has to pass (§9.4), which is the only reason a runtime port needs it at
/// all.

final _wordToken = RegExp(r"[A-Za-z']+");
final _wordSplit = RegExp(r'[^A-Za-z_]+');

const _affixes = ['s', 'es', 'ing', 'ed', 'er', 'ers', 'ly', 'tion', 'y'];

/// Words that are protected in the answer itself but not worth protecting as
/// *constituents* of a multi-word answer — a clue for A FEW GOOD MEN may
/// obviously say "men are".
const _leakStopwords = {
  'the', 'and', 'for', 'but', 'not', 'all', 'out', 'off', 'one', 'own', 'any',
  'are', 'was', 'has', 'had', 'its', 'his', 'her', 'him', 'she', 'they', 'them',
  'their', 'there', 'this', 'that', 'these', 'those', 'with', 'from', 'into',
  'onto', 'over', 'under', 'about', 'after', 'before', 'more', 'most', 'some',
  'such', 'than', 'then', 'when', 'where', 'who', 'whom', 'whose', 'you',
  'your', 'our', 'ours', 'were', 'been', 'being', 'does', 'did', 'done', 'can',
  'could', 'will', 'would', 'shall', 'should', 'may', 'might', 'must',
};

/// A cheap morphological family for the giveaway check — not a real stemmer,
/// just common English suffix stripping, which is enough to catch "the
/// answer's derivative appears in the clue" without a stemmer dependency.
Set<String> _stemVariants(String word) {
  final lower = word.toLowerCase();
  final variants = <String>{lower};
  for (final affix in _affixes) {
    variants.add('$lower$affix');
    if (lower.endsWith(affix) && lower.length - affix.length >= 3) {
      variants.add(lower.substring(0, lower.length - affix.length));
    }
  }
  return variants;
}

/// Every form a clue must not contain: the answer, plus — for a multi-word
/// answer — each of its constituent words.
///
/// Checking only the run-together grid form is a real blind spot, not a
/// theoretical one: WordNet's gloss for `ice cream` is "frozen dessert
/// containing cream and sugar and flavoring", a clean leak that a check
/// against ICECREAM cannot see, because "cream" is neither a stem variant of
/// nor a substring match for the joined form.
List<String> leakForms(String text, String display) {
  // The answer's own form is always protected, even when it is a function
  // word — THE must not be clued with "the". Only the *constituents* of a
  // multi-word answer are filtered against the stopword list.
  final forms = <String>{text.toLowerCase()};
  for (final token in display.toLowerCase().split(_wordSplit)) {
    if (token.length >= 3 && !_leakStopwords.contains(token)) forms.add(token);
  }
  return forms.toList();
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
  final variants = _stemVariants(answerText);

  for (final match in _wordToken.allMatches(clueText)) {
    // Strip edge apostrophes before comparing: WordNet quotes words as
    // `word', so the token arrives as "old'" and silently failed to match the
    // answer OLD — letting a whole class of leaks through.
    final token = match.group(0)!.replaceAll("'", '').toLowerCase();
    if (token.length < 3) continue;
    if (variants.contains(token)) return true;
    if (token.length >= 5 && answer.contains(token)) return true;
    if (answer.length >= 5 && token.contains(answer)) return true;
  }
  return false;
}

/// Deliberately does **not** include a bare "letter(s)": that appears in
/// plenty of innocent clues ("Letters after Q" for ARS), and real acronym
/// expansions are caught by [expandsAcronym] instead.
final _abbrevSignal = RegExp(
  r'\b(for short|short for|short(ened)? form|abbr\w*|acronym|initialism'
  r'|initials|stands for)\b',
  caseSensitive: false,
);

/// "Three-letter female name with double N" hands over the grid shape, which
/// is the same giveaway as "for short" in a different costume — the solver
/// stops solving and starts counting. Models reach for it constantly when
/// clueing short names, and get it wrong as often as not.
final _lengthHint = RegExp(
  r'\b(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)'
  r'[-\s]letters?\b|\bletters?\s+long\b|\b(?:double|triple)\s+[a-z]\b',
  caseSensitive: false,
);

/// True if the clue announces that its answer is an abbreviation.
///
/// Real crosswords use "for short" as a legitimate signal, but it is ruled
/// out here: combined with a definition it effectively hands over an
/// initialism.
bool signalsAbbreviation(String clueText) => _abbrevSignal.hasMatch(clueText);

/// True if the clue describes the answer's spelling rather than its sense.
bool hintsAtLength(String clueText) => _lengthHint.hasMatch(clueText);

/// Words an acronym expansion conventionally skips.
const _acronymSkip = {
  'a', 'an', 'the', 'of', 'for', 'and', 'or', 'in', 'on', 'at', 'to', 'by',
  'with', 'from',
};

/// True if the clue spells the answer out as an acronym.
///
/// A naive first-letter scan misses the real cases because expansions skip
/// small words: "light amplification by stimulated emission of radiation"
/// only yields LASER once `by` and `of` are ignored.
bool expandsAcronym(String clueText, String answerText) {
  final answer = answerText.toUpperCase();
  if (answer.length < 3) return false;
  final words = [for (final m in _wordToken.allMatches(clueText)) m.group(0)!];
  final content = [
    for (final w in words)
      if (!_acronymSkip.contains(w.toLowerCase())) w,
  ];
  final initials = content.map((w) => w[0].toUpperCase()).join();
  if (initials.contains(answer)) return true;
  return words.map((w) => w[0].toUpperCase()).join().contains(answer);
}

const _profanity = {
  'shit', 'shits', 'shitty', 'shite', 'fuck', 'fucks', 'fucking', 'fucked',
  'fucker', 'cunt', 'cunts', 'twat', 'twats', 'wank', 'wanker', 'bollocks',
  'arsehole', 'asshole', 'assholes', 'motherfucker', 'nigger', 'faggot',
  'faggots', 'fag', 'whore', 'whores', 'slut', 'sluts', 'turd', 'turds',
  'piss', 'pissed', 'pissing', 'bugger', 'prick', 'pricks', 'bastard',
};

/// WordNet labels its own crude senses, which catches glosses that carry no
/// profanity themselves but are still not wanted: CRAP's "obscene terms for
/// feces", or a gloss opening "vulgar term for...".
final _vulgarLabel =
    RegExp(r'\b(obscene|vulgar|offensive|derogatory|disparaging)\b', caseSensitive: false);

bool hasProfanity(String text) {
  if (_vulgarLabel.hasMatch(text)) return true;
  for (final token in text.split(_wordSplit)) {
    if (token.isNotEmpty && _profanity.contains(token.toLowerCase())) return true;
  }
  return false;
}

/// Shortest and longest a clue may be, in words (§9.4). A one-word "clue" is
/// usually the model restating the answer's part of speech; a 15-word one is
/// a dictionary entry with a hat on.
const int minClueWords = 2;
const int maxClueWords = 14;

/// Why a proposed clue was rejected — recorded so a review's edits can be
/// reported as "9 of 10 applied, one contained the answer" rather than
/// silently dropped.
enum ClueRejection {
  none,
  empty,
  tooShort,
  tooLong,
  containsAnswer,
  acronymExpansion,
  abbreviationSignal,
  lengthHint,
  profanity,
  isAnswer,
}

typedef ClueCandidate = ({String text, bool ok, ClueRejection reason});

/// The gate every clue an outside party proposes must pass (§9.4).
///
/// Deliberately stricter than the deterministic pipeline's own checks: a
/// model will happily emit the answer, an acronym expansion, or a one-word
/// non-clue, and in a measured run three of 32 proposed edits broke rules the
/// model had been given explicitly.
///
/// [display] matters for multi-word answers — see [leakForms].
ClueCandidate validateClue(String raw, String answer, {String display = ''}) {
  var text = raw.trim();
  if (text.startsWith('"') && text.endsWith('"') && text.length > 1) {
    text = text.substring(1, text.length - 1);
  }
  text = text.trim();
  while (text.endsWith('.')) {
    text = text.substring(0, text.length - 1);
  }
  text = text.trim();

  if (text.isEmpty) return (text: text, ok: false, reason: ClueRejection.empty);

  final words = _wordToken.allMatches(text).length;
  if (words < minClueWords) return (text: text, ok: false, reason: ClueRejection.tooShort);
  if (words > maxClueWords) return (text: text, ok: false, reason: ClueRejection.tooLong);
  for (final form in leakForms(answer, display)) {
    if (isGiveaway(text, form)) {
      return (text: text, ok: false, reason: ClueRejection.containsAnswer);
    }
  }
  if (expandsAcronym(text, answer)) {
    return (text: text, ok: false, reason: ClueRejection.acronymExpansion);
  }
  if (signalsAbbreviation(text)) {
    return (text: text, ok: false, reason: ClueRejection.abbreviationSignal);
  }
  if (hintsAtLength(text)) {
    return (text: text, ok: false, reason: ClueRejection.lengthHint);
  }
  if (hasProfanity(text)) {
    return (text: text, ok: false, reason: ClueRejection.profanity);
  }
  final lower = text.toLowerCase();
  if (lower == answer.toLowerCase() || lower == display.trim().toLowerCase()) {
    return (text: text, ok: false, reason: ClueRejection.isAnswer);
  }
  return (text: text, ok: true, reason: ClueRejection.none);
}

/// How much to favour one baked clue option over another (§8, *measured*).
///
/// Uniform choice among options measurably lowered quality: TWO drew
/// WordNet's "the cardinal number that is the sum of one and one…" as often
/// as the hand-written "A pair". So weight by what actually reads like a
/// newspaper clue — a human's own wording first, then a synset co-lemma
/// (already terse and in crossword register), then a model's, and short over
/// encyclopedic, since glosses get verbose. Every option keeps a real chance,
/// so variety survives.
double clueOptionWeight(CrosswordClue clue) {
  final words = _wordToken.allMatches(clue.text).length;
  var weight = 1.0;
  switch (clue.type) {
    case CrosswordClueType.curated:
      weight *= 3.0;
    case CrosswordClueType.synonym:
      weight *= 2.5;
    case CrosswordClueType.llm:
      weight *= 2.0;
    case CrosswordClueType.definition:
    case CrosswordClueType.fillInBlank:
      break;
  }
  if (words > 8) weight *= max(0.12, 1.0 - 0.09 * (words - 8));
  return max(weight, 0.05);
}

/// Picks the clue for [entry] (§8).
///
/// Chosen with the puzzle's seeded [rng] so a recurring answer isn't clued
/// identically every time — the brief's "vary clue types" requirement —
/// while a given seed still reproduces a given puzzle exactly.
///
/// The stub paths should never fire for ordinary fill, because the fill pool
/// requires a clue (§6.3). They remain reachable only for anchors drawn from
/// outside the pool: a caller-supplied SRS word the asset has never heard of.
CrosswordClue pickClue(CrosswordEntry entry, Random rng) {
  var clue = _pick(entry, rng);

  // Last line of defence. A clue must never contain its answer, announce
  // that the answer is an abbreviation, spell it out as an acronym, or give
  // away its length. The baked clues were gated at build time, so this fires
  // only for a synthesized anchor whose clue came from the app's dictionary.
  final leaks = leakForms(entry.text, entry.display).any((f) => isGiveaway(clue.text, f));
  if (leaks ||
      signalsAbbreviation(clue.text) ||
      expandsAcronym(clue.text, entry.text) ||
      hintsAtLength(clue.text) ||
      hasProfanity(clue.text)) {
    clue = CrosswordClue('${entry.length}-letter answer', CrosswordClueType.definition);
  }
  return clue;
}

CrosswordClue _pick(CrosswordEntry entry, Random rng) {
  final options = entry.clues;
  if (options.isEmpty) {
    // §8 paths 2 and 3, and the reason the fill pool requires a clue: a stub
    // in the puzzle's most prominent slot is the worst place to have one.
    if (entry.isProper) {
      final tag = entry.tags.firstWhere(
        (t) => t != 'proper' && t != 'abbreviation',
        orElse: () => '',
      );
      return CrosswordClue(
        tag.isEmpty ? 'Proper name' : 'Name in ${tag.replaceAll('_', ' ')}',
        CrosswordClueType.definition,
      );
    }
    if (entry.isPhrase) {
      final tag = entry.tags.firstWhere((t) => t != 'phrase', orElse: () => '');
      return CrosswordClue(
        tag.isEmpty
            ? 'Everyday expression'
            : 'Everyday ${tag.replaceAll('_', ' ')} expression',
        CrosswordClueType.definition,
      );
    }
    return CrosswordClue('${entry.length}-letter word', CrosswordClueType.definition);
  }
  if (options.length == 1) return options.first;

  final weights = [for (final option in options) clueOptionWeight(option)];
  final total = weights.fold(0.0, (a, b) => a + b);
  var roll = rng.nextDouble() * total;
  for (var i = 0; i < options.length; i++) {
    roll -= weights[i];
    if (roll <= 0) return options[i];
  }
  return options.last;
}

/// 1 (easy) to 5 (hard), from the rarity of the clue's own vocabulary —
/// rarer clue wording reads as harder (§8).
///
/// [zipfOf] resolves a lowercase word to its Zipf frequency, or null if the
/// word list doesn't carry it. The reference implementation calls `wordfreq`
/// here; on device the word list is the only frequency table available, so
/// tokens it doesn't know are skipped rather than counted as rare.
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
  if (count == 0) return 2.5;
  return (6.0 - total / count).clamp(1, 5);
}

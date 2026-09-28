// Objective checks for one generated crossword — the part of the harness
// that costs nothing and gives the same answer every time. Each flag names
// one concrete, countable fault a solver would notice; the LLM judge (see
// judge.dart) covers what rules can't, like whether a clue is *wrong*.

import 'package:word_wizard/domain/crossword/clues.dart' show isGiveaway;
import 'package:word_wizard/domain/crossword/crossword_models.dart';

/// Faults in an answer.
enum FillFlag {
  /// Rated 1-2 on the familiarity scale, or unrated and rare. (Frequency
  /// alone isn't a fault: KNELT and IGLOO are rare in text and known to
  /// everyone.)
  unfamiliar('unfamiliar word'),
  proper('proper noun'),

  /// No vowels, or reads as initials (HDL, NYSE): almost always an
  /// abbreviation, whatever the list says.
  abbreviation('looks like an abbreviation'),
  crosswordese('crosswordese'),

  /// Shares a root with another answer in the same grid.
  duplicateRoot('shares a root with another answer');

  final String label;
  const FillFlag(this.label);
}

/// Faults in a clue.
enum ClueFlag {
  leak('contains the answer or its root'),

  /// More than 12 words — a sentence, not a clue.
  long('too long'),

  /// Two definitions glued with a semicolon.
  multiSense('two senses in one clue'),

  /// WordNet example residue: "- H.H.Arnold", "(adj.)", backquotes.
  residue('dictionary residue'),

  /// Opens like a dictionary entry ("Of or relating to", "Any of").
  dictionaryVoice('reads like a dictionary'),

  /// A scientific or taxonomic register a newspaper wouldn't use.
  technical('technical or scientific register'),

  /// Sexual or crude content — the prompt forbids it, the word list's
  /// definitions don't.
  unsuitable('sexual or crude content'),
  endsWithPeriod('ends with a period');

  final String label;
  const ClueFlag(this.label);
}

final _residue = RegExp(
  r';\s*-\s|\s-\s[A-Z][a-z]|[A-Z]\.[A-Z]\.|\((adj|adv|n|v|noun|verb|adjective|adverb)\.?\)|`|'
  "''",
  caseSensitive: false,
);
final _dictionaryOpeners = RegExp(
  r'^(of or (relating|pertaining) to|relating to|pertaining to|having the (quality|property)|'
  r'the (act|state|quality|condition|process) of|any (of|member of)|a (genus|family|member) of|'
  r'characterized by|(a|an) (person|thing|one) who|used (of|to describe))\b',
  caseSensitive: false,
);
final _technical = RegExp(
  r'\b(genus|family [A-Z][a-z]+idae|species|phylum|order [A-Z]|taxonomy|botany|zoology|'
  r'protein|lipoprotein|enzyme|compound|molecule|chemical element|atomic number|hormone|'
  r'bacteri|syndrome|anatomy|tissue|genitive|nominative|morpheme)\w*',
  caseSensitive: false,
);
final _vowels = RegExp('[AEIOUY]');
final _unsuitable = RegExp(
  r'\b(erotic\w*|sexual\w*|genital\w*|copulat\w*|intercourse|orgasm\w*|penis|vagina\w*|'
  r'breasts?|buttocks|arse|excrement|feces|faeces|urinat\w*|masturbat\w*|lovemaking)\b',
  caseSensitive: false,
);

int wordCount(String clue) => clue.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

List<ClueFlag> lintClue(String answer, String clue) => [
  if (isGiveaway(clue, answer)) ClueFlag.leak,
  if (wordCount(clue) > 12) ClueFlag.long,
  if (clue.contains(';')) ClueFlag.multiSense,
  if (_residue.hasMatch(clue)) ClueFlag.residue,
  if (_dictionaryOpeners.hasMatch(clue.trim())) ClueFlag.dictionaryVoice,
  if (_technical.hasMatch(clue)) ClueFlag.technical,
  if (_unsuitable.hasMatch(clue)) ClueFlag.unsuitable,
  if (clue.trim().endsWith('.') && !clue.trim().endsWith('...')) ClueFlag.endsWithPeriod,
];

/// Faults in [word], looking it up in [entries] (by answer text) for the
/// word list's own ratings. [others] are the grid's other answers, for the
/// shared-root check.
List<FillFlag> lintFill(
  CrosswordWordPlacement word,
  Map<String, CrosswordEntry> entries,
  Iterable<String> others,
) {
  final entry = entries[word.answer];
  final answer = word.answer;
  final rated = entry != null && entry.familiarity > 0;
  return [
    if (rated ? entry.familiarity <= 2 : word.freqZipf < 3.0) FillFlag.unfamiliar,
    if (entry?.isProper ?? false) FillFlag.proper,
    if (answer.length <= 4 && !_vowels.hasMatch(answer)) FillFlag.abbreviation,
    if (entry?.isCrosswordese ?? false) FillFlag.crosswordese,
    if (others.any((o) => o != answer && _sharesRoot(o, answer))) FillFlag.duplicateRoot,
  ];
}

bool _sharesRoot(String a, String b) {
  if (a.length < 4 || b.length < 4) return false;
  if (a.contains(b) || b.contains(a)) return true;
  final n = 5;
  return a.length >= n && b.length >= n && a.substring(0, n) == b.substring(0, n);
}

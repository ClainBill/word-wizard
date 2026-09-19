/// Part-of-speech tag as stored on an [Entry], e.g. "noun", "verb", "adj", "adv".
typedef Pos = String;

class Example {
  final int id;
  final String text;
  final String? source;

  const Example({required this.id, required this.text, this.source});
}

class Sense {
  final int id;
  final String gloss;
  final int order;
  final List<Example> examples;

  const Sense({
    required this.id,
    required this.gloss,
    required this.order,
    this.examples = const [],
  });
}

class Pronunciation {
  final String? ipa;
  final String? audioHint;

  const Pronunciation({this.ipa, this.audioHint});
}

/// One inflected surface form of an entry — "ran" for "run", "mice" for "mouse".
class WordForm {
  final String formText;
  final String formType;

  const WordForm({required this.formText, required this.formType});
}

/// Another way of writing a [WordEntry]'s headword — "colour" for "color",
/// "shew" for "show" — with where or when it's used. Wiktionary files these
/// as entries of their own whose only sense is "Commonwealth spelling of
/// color"; the pipeline folds them into the word they point at (see
/// `tool/pipeline/spelling_variants.py`), so a lookup of either spelling
/// gives the one card.
class SpellingVariant {
  final String text;

  /// "Commonwealth and Ireland", "archaic", "alternative", … — or
  /// [misspellingLabel], which a card doesn't list.
  final String label;

  const SpellingVariant({required this.text, required this.label});

  static const misspellingLabel = 'misspelling';

  bool get isMisspelling => label == misspellingLabel;
}

/// All the senses that share a POS, within one [WordEntry].
class PosSenses {
  final Pos pos;
  final List<Sense> senses;

  const PosSenses({required this.pos, required this.senses});
}

/// A dictionary headword merged across every part of speech it's filed
/// under — the unit the Entry Detail screen renders and the unit "Study" /
/// "Add to list" act on. Wiktionary (and JMdict-style dictionaries) file
/// "run" as three separate rows (verb, noun, adj); a lookup should feel like
/// one word with several meanings, not three near-duplicate search results.
class WordEntry {
  /// The id of the best-ranked underlying (headword, pos) row — the single
  /// identity this word uses in `study_cards`, `list_items`, and
  /// `entry_notes`, regardless of which POS variant the user looked up.
  final int canonicalEntryId;
  final String headword;
  final Pronunciation pronunciation;
  final String? etymology;
  final List<PosSenses> posGroups;
  final List<WordForm> forms;

  /// Other spellings of this word, commonest region first.
  final List<SpellingVariant> variants;

  /// The spelling this card was reached by when it wasn't [headword] —
  /// "colour" when the card is "color" — so the screen can say so.
  final String? lookedUpAs;

  const WordEntry({
    required this.canonicalEntryId,
    required this.headword,
    this.pronunciation = const Pronunciation(),
    this.etymology,
    this.posGroups = const [],
    this.forms = const [],
    this.variants = const [],
    this.lookedUpAs,
  });

  /// This card as reached by [spelling] rather than its own headword.
  WordEntry reachedAs(String spelling) => WordEntry(
        canonicalEntryId: canonicalEntryId,
        headword: headword,
        pronunciation: pronunciation,
        etymology: etymology,
        posGroups: posGroups,
        forms: forms,
        variants: variants,
        lookedUpAs: spelling,
      );

  /// Every example across every sense, flattened in display order — the
  /// source list for the capped-preview Examples section.
  List<Example> get allExamples => [
        for (final group in posGroups)
          for (final sense in group.senses) ...sense.examples,
      ];
}

/// A lightweight row for search results and list tables — no senses/examples loaded.
class EntrySummary {
  final int id;
  final String headword;
  final Pos pos;
  final String? gloss;

  /// When a search reached this entry through one of its inflections — the
  /// user typed "ran" and this is "run" — the form they typed, so the result
  /// row can say why a different word is showing up.
  final String? matchedForm;

  const EntrySummary({
    required this.id,
    required this.headword,
    required this.pos,
    this.gloss,
    this.matchedForm,
  });

  EntrySummary withMatchedForm(String form) =>
      EntrySummary(id: id, headword: headword, pos: pos, gloss: gloss, matchedForm: form);
}

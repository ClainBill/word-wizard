import 'slang.dart';

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

  /// Set when this is one of the person's own meanings from the Slang
  /// Stack, for what only those carry (a plain-English gloss, a tone).
  final SlangSense? slang;

  const Sense({
    required this.id,
    required this.gloss,
    required this.order,
    this.examples = const [],
    this.slang,
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

  /// True for a group of the person's own Slang Stack meanings. They come
  /// first on a card — they're why the person added the word — and are
  /// marked as theirs.
  final bool isSlang;

  const PosSenses({required this.pos, required this.senses, this.isSlang = false});
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

  /// The person's own Slang Stack entry for this headword, if they made
  /// one. Its meanings are already in [posGroups]; this carries the rest
  /// (where it's used, where they heard it, how to say it).
  final SlangWord? slang;

  const WordEntry({
    required this.canonicalEntryId,
    required this.headword,
    this.pronunciation = const Pronunciation(),
    this.etymology,
    this.posGroups = const [],
    this.forms = const [],
    this.variants = const [],
    this.lookedUpAs,
    this.slang,
  });

  /// A word only the Slang Stack knows — the dictionary has no card for it,
  /// so the slang word's own id is the one everything keys on.
  factory WordEntry.fromSlang(SlangWord slang) => WordEntry(
        canonicalEntryId: slang.id!,
        headword: slang.headword,
        forms: [for (final f in slang.forms) WordForm(formText: f, formType: 'slang')],
        variants: [
          for (final v in slang.spellings) SpellingVariant(text: v, label: 'slang'),
        ],
        posGroups: _slangGroups(slang),
        slang: slang,
      );

  /// This dictionary card with the person's own meanings for it added in
  /// front of the dictionary's, and their spellings and forms alongside.
  WordEntry withSlang(SlangWord slang) => WordEntry(
        canonicalEntryId: canonicalEntryId,
        headword: headword,
        pronunciation: pronunciation,
        etymology: etymology,
        posGroups: [..._slangGroups(slang), ...posGroups],
        forms: [
          ...forms,
          for (final f in slang.forms)
            if (!forms.any((existing) => existing.formText == f)) WordForm(formText: f, formType: 'slang'),
        ],
        variants: [
          ...variants,
          for (final v in slang.spellings)
            if (!variants.any((existing) => existing.text == v)) SpellingVariant(text: v, label: 'slang'),
        ],
        lookedUpAs: lookedUpAs,
        slang: slang,
      );

  static List<PosSenses> _slangGroups(SlangWord slang) {
    final order = <String>[];
    final byPos = <String, List<Sense>>{};
    for (final s in slang.senses) {
      final group = byPos.putIfAbsent(s.pos, () {
        order.add(s.pos);
        return [];
      });
      group.add(Sense(
        id: s.id!,
        gloss: s.gloss,
        order: group.length,
        // Nothing addresses an example by id; only the dictionary's have one.
        examples: [for (final text in s.examples) Example(id: 0, text: text)],
        slang: s,
      ));
    }
    return [for (final pos in order) PosSenses(pos: pos, senses: byPos[pos]!, isSlang: true)];
  }

  /// True when the dictionary has no card for this word and it exists only
  /// in the person's Slang Stack.
  bool get isSlangOnly => isSlangId(canonicalEntryId);

  /// What the pronounce button should read: the person's own respelling
  /// when they gave one — text-to-speech has never heard most new slang —
  /// otherwise the headword.
  String get spokenAs {
    final say = slang?.sayItLike?.trim();
    return say == null || say.isEmpty ? headword : say;
  }

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
        slang: slang,
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

  /// True when the person has this word in their Slang Stack — either it
  /// exists only there, or they added their own meaning to the
  /// dictionary's word.
  final bool slang;

  const EntrySummary({
    required this.id,
    required this.headword,
    required this.pos,
    this.gloss,
    this.matchedForm,
    this.slang = false,
  });

  EntrySummary withMatchedForm(String form) => EntrySummary(
        id: id,
        headword: headword,
        pos: pos,
        gloss: gloss,
        matchedForm: form,
        slang: slang,
      );

  /// The same row, marked as being in the Slang Stack.
  EntrySummary asSlang() => EntrySummary(
        id: id,
        headword: headword,
        pos: pos,
        gloss: gloss,
        matchedForm: matchedForm,
        slang: true,
      );
}

/// The Slang Stack: words, and meanings of words, the person added
/// themselves because the dictionary doesn't have them — or has them, but
/// not the way they heard them used.
///
/// A slang word is keyed by its headword. When the dictionary has that
/// headword too ("cap", "mid"), the slang word adds its meanings to the
/// dictionary's card and the card keeps the dictionary's entry id, so
/// studying, lists and notes carry on exactly as before. When the
/// dictionary doesn't ("skrrt"), the slang word's own [SlangWord.id] is the
/// entry id everything keys on.
library;

/// Where slang ids start. Every id the Slang Stack hands out — words,
/// meanings, examples — is at least this, far above anything the
/// dictionary uses (its largest is under a million), so an id says which
/// side it came from without a lookup, and the two never collide in
/// `study_cards`, `list_items`, `study_senses` or `entry_notes`. Positive
/// on purpose: the crossword already uses negative entry ids to mean
/// "no word".
const slangIdBase = 1000000000;

/// True if [id] — an entry, sense or example id — belongs to the Slang
/// Stack rather than the dictionary.
bool isSlangId(int id) => id >= slangIdBase;

/// The parts of speech a slang meaning can be filed under: the dictionary's
/// four, plus the two slang lives in most that the dictionary files as
/// something else.
const slangPartsOfSpeech = ['noun', 'verb', 'adj', 'adv', 'phrase', 'intj'];

/// How a meaning lands — what someone needs to know before they use it.
enum SlangTone {
  everyday('everyday', 'Everyday', 'Fine almost anywhere casual'),
  playful('playful', 'Playful', 'Jokey, affectionate'),
  ironic('ironic', 'Ironic', 'Usually said with a wink'),
  crude('crude', 'Crude', 'Vulgar — pick your company'),
  offensive('offensive', 'Offensive', 'Can hurt — know before you use it');

  final String storageKey;
  final String label;
  final String description;

  const SlangTone(this.storageKey, this.label, this.description);

  /// Crude and offensive meanings are flagged wherever they're shown.
  bool get isWarning => this == crude || this == offensive;

  static SlangTone? fromStorageKey(String? key) =>
      values.where((t) => t.storageKey == key).firstOrNull;
}

/// Where a word is in its life. Slang ages faster than any other
/// vocabulary, and using a dated word straight is its own kind of mistake.
enum SlangFreshness {
  rising('rising', 'Brand new'),
  current('current', 'Everywhere now'),
  fading('fading', 'Fading'),
  dated('dated', 'Dated');

  final String storageKey;
  final String label;

  const SlangFreshness(this.storageKey, this.label);

  static SlangFreshness? fromStorageKey(String? key) =>
      values.where((f) => f.storageKey == key).firstOrNull;
}

/// One meaning in the Slang Stack.
class SlangSense {
  /// Null for a meaning not saved yet.
  final int? id;
  final String pos;
  final String gloss;

  /// The ordinary word or phrase it stands for — "charisma" for "rizz".
  /// Shown on the card, and a clean synonym clue for the crossword.
  final String? plainEnglish;
  final SlangTone? tone;
  final List<String> examples;

  const SlangSense({
    this.id,
    this.pos = 'noun',
    required this.gloss,
    this.plainEnglish,
    this.tone,
    this.examples = const [],
  });
}

/// A word in the Slang Stack, with everything the person told us about it.
class SlangWord {
  /// Null for a word not saved yet.
  final int? id;
  final String headword;

  /// A respelling of how it's said ("guy-at"), which is also what the
  /// pronounce button reads — text-to-speech guesses badly at new words.
  final String? sayItLike;

  /// Other ways it's written ("finna" → "fina"). A lookup or a word in the
  /// reader by any of these reaches this word.
  final List<String> spellings;

  /// Its inflections ("rizzed", "rizzing") — recognised the same way.
  final List<String> forms;

  /// Where it's used ("UK", "Australia") and by whom ("gamers", "ballroom").
  final String? region;
  final String? scene;
  final SlangFreshness? freshness;

  /// Where the person came across it — a person, a show, a link.
  final String? heardAt;

  /// Its backstory, as far as they know it.
  final String? origin;

  final List<SlangSense> senses;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const SlangWord({
    this.id,
    required this.headword,
    this.sayItLike,
    this.spellings = const [],
    this.forms = const [],
    this.region,
    this.scene,
    this.freshness,
    this.heardAt,
    this.origin,
    this.senses = const [],
    this.createdAt,
    this.updatedAt,
  });

  /// The first meaning, for a one-line summary.
  String? get firstGloss => senses.firstOrNull?.gloss;

  /// True if any meaning is crude or offensive.
  bool get hasWarning => senses.any((s) => s.tone?.isWarning ?? false);
}

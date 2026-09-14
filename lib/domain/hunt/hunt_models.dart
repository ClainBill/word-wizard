/// The Word Hunt's data model — a 4x4 letter board and its certified answer
/// sets. Ported from `StrandinatorResearch/` (milestones 0.3-0.4); the engine
/// lives in `hunt_generator.dart` and `hunt_solver.dart`.
///
/// A board is sixteen cells indexed row-major, 0..15. A word is a simple
/// path through the eight-neighbourhood: no cell twice within one word,
/// cells freely shared between words.
library;

/// Cells on the board, and the longest word that can physically fit on it.
const int huntCells = 16;
const int huntSize = 4;
const int huntMinWordLength = 4;
const int huntMaxWordLength = huntCells;

/// One accepted answer: a representative path plus the union of **every**
/// legal route's start cells and used cells, as 16-bit masks.
///
/// Both masks matter to the player, not just the path: "how many words start
/// on this tile" and "is this tile still needed" are hints, and a hint
/// computed from one route of a word that has several would lie.
class HuntWord {
  final List<int> path;
  final int starts;
  final int uses;

  const HuntWord({required this.path, required this.starts, required this.uses});

  Map<String, dynamic> toJson() => {'p': path, 's': starts, 'u': uses};

  factory HuntWord.fromJson(Map<String, dynamic> json) => HuntWord(
        path: [for (final c in json['p'] as List) c as int],
        starts: json['s'] as int,
        uses: json['u'] as int,
      );
}

/// Where an anchor came from. A study word is one of the user's SRS cards;
/// a theme word is the day's topic pick.
enum HuntAnchorKind {
  study,
  theme;

  static HuntAnchorKind fromKey(String key) =>
      values.firstWhere((k) => k.name == key, orElse: () => HuntAnchorKind.study);
}

/// A word the board was built to contain.
class HuntAnchor {
  /// Board form, A-Z only.
  final String text;

  /// How the word is written in the dictionary ("re-enter" → REENTER).
  final String display;
  final HuntAnchorKind kind;

  /// The dictionary entry, for study words, so a find can be traced back to
  /// the card. Null for theme words.
  final int? entryId;

  /// A definition the player can ask for. Null when none was found that
  /// doesn't give the word away.
  final String? clue;

  const HuntAnchor({
    required this.text,
    required this.display,
    required this.kind,
    this.entryId,
    this.clue,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'display': display,
        'kind': kind.name,
        if (entryId != null) 'entryId': entryId,
        if (clue != null) 'clue': clue,
      };

  factory HuntAnchor.fromJson(Map<String, dynamic> json) => HuntAnchor(
        text: json['text'] as String,
        display: json['display'] as String,
        kind: HuntAnchorKind.fromKey(json['kind'] as String),
        entryId: json['entryId'] as int?,
        clue: json['clue'] as String?,
      );
}

/// Why a requested anchor was left out — research contract §7: never
/// silently claim personalisation an anchor could not deliver.
class HuntOmittedAnchor {
  final HuntAnchor anchor;
  final String reason;

  const HuntOmittedAnchor({required this.anchor, required this.reason});

  Map<String, dynamic> toJson() => {'anchor': anchor.toJson(), 'reason': reason};

  factory HuntOmittedAnchor.fromJson(Map<String, dynamic> json) => HuntOmittedAnchor(
        anchor: HuntAnchor.fromJson(json['anchor'] as Map<String, dynamic>),
        reason: json['reason'] as String,
      );
}

/// A generated board with its complete, certified answer sets.
///
/// Three answer classes, kept disjoint so a word is never rewarded twice
/// (research contract §7):
///
/// - [anchors] — the study and theme words the board was built around,
///   shown as targets with hints;
/// - [main] — every other familiar word on the board. **Completion is
///   measured against this set plus the anchors**, and nothing else;
/// - [bonus] — every other accepted spelling. Recognised and counted, never
///   required: bonus breadth must not dictate completion difficulty.
class HuntPuzzle {
  static const String currentSchema = 'hunt-1';

  final String schema;
  final int seed;

  /// Sixteen single uppercase letters, row-major.
  final List<String> board;
  final List<HuntAnchor> anchors;
  final List<HuntOmittedAnchor> omitted;

  /// Where each anchor actually sits — keyed by anchor text.
  final Map<String, HuntWord> anchorWords;
  final Map<String, HuntWord> main;
  final Map<String, HuntWord> bonus;

  /// The day's theme, or null when there was no theme (the theme anchor
  /// could not be placed).
  final String? themeLabel;

  /// Every answer on the board — anchor, main or bonus — that belongs to the
  /// day's theme. Finding one is a theme find whatever class it scores as.
  final Set<String> themeWords;

  /// Identifies the lexicon these answer sets were certified against. A
  /// stored puzzle is never re-scanned: the sets it was saved with are the
  /// sets it keeps, so a dictionary update can't move the goalposts under a
  /// half-played board.
  final String dictionaryHash;

  const HuntPuzzle({
    this.schema = currentSchema,
    required this.seed,
    required this.board,
    required this.anchors,
    required this.omitted,
    required this.anchorWords,
    required this.main,
    required this.bonus,
    required this.themeLabel,
    required this.themeWords,
    required this.dictionaryHash,
  });

  /// Words the player has to find to finish: anchors first, then main.
  int get requiredCount => anchors.length + main.length;

  /// Score for finding every required word: a word is worth its length.
  int get maxScore =>
      anchors.fold(0, (n, a) => n + a.text.length) + main.keys.fold(0, (n, w) => n + w.length);

  List<HuntAnchor> get studyAnchors =>
      [for (final a in anchors) if (a.kind == HuntAnchorKind.study) a];

  HuntAnchor? get themeAnchor {
    for (final a in anchors) {
      if (a.kind == HuntAnchorKind.theme) return a;
    }
    return null;
  }

  /// The class a traced word falls into, or null if it's not on the board.
  HuntWordClass? classify(String word) {
    if (anchorWords.containsKey(word)) return HuntWordClass.anchor;
    if (main.containsKey(word)) return HuntWordClass.main;
    if (bonus.containsKey(word)) return HuntWordClass.bonus;
    return null;
  }

  HuntWord? wordInfo(String word) => anchorWords[word] ?? main[word] ?? bonus[word];

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'seed': seed,
        'board': board,
        'anchors': [for (final a in anchors) a.toJson()],
        'omitted': [for (final o in omitted) o.toJson()],
        'anchorWords': {for (final e in anchorWords.entries) e.key: e.value.toJson()},
        'main': {for (final e in main.entries) e.key: e.value.toJson()},
        'bonus': {for (final e in bonus.entries) e.key: e.value.toJson()},
        if (themeLabel != null) 'themeLabel': themeLabel,
        'themeWords': themeWords.toList()..sort(),
        'dictionaryHash': dictionaryHash,
      };

  factory HuntPuzzle.fromJson(Map<String, dynamic> json) {
    Map<String, HuntWord> words(String key) => {
          for (final e in (json[key] as Map<String, dynamic>).entries)
            e.key: HuntWord.fromJson(e.value as Map<String, dynamic>),
        };
    return HuntPuzzle(
      schema: json['schema'] as String? ?? currentSchema,
      seed: json['seed'] as int,
      board: [for (final c in json['board'] as List) c as String],
      anchors: [
        for (final a in json['anchors'] as List) HuntAnchor.fromJson(a as Map<String, dynamic>),
      ],
      omitted: [
        for (final o in json['omitted'] as List? ?? const [])
          HuntOmittedAnchor.fromJson(o as Map<String, dynamic>),
      ],
      anchorWords: words('anchorWords'),
      main: words('main'),
      bonus: words('bonus'),
      themeLabel: json['themeLabel'] as String?,
      themeWords: {for (final w in json['themeWords'] as List? ?? const []) w as String},
      dictionaryHash: json['dictionaryHash'] as String,
    );
  }
}

enum HuntWordClass { anchor, main, bonus }

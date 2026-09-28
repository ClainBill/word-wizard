/// Puzzle sizes and the presentation model the solving screen renders.
///
/// The generator itself lives in `generator.dart`; everything here is either
/// a tuning constant from PORTING_SPEC.md §4.3 / §9 or a plain data holder.
library;

/// The three sizes, with the per-size search parameters §4.3 measured.
///
/// [whiteTarget] is a **floor on black squares, not an exact figure** —
/// capping entry length can already place more black squares than the target
/// implies, so achieved white % often lands below it (72.8% against a 0.78
/// target at 9x9 in the reference implementation). A below-target result is
/// not a failure.
///
/// The white percentages here are deliberately below the 85% a naive reading
/// of "dense grid = good grid" suggests, and that is the single most
/// important decision in the whole design (§10.1). Chasing 85% produces
/// grids that are not merely hard to fill but provably *unfillable* from a
/// word list of recognizable words — a CP-SAT model proved several 17x17
/// grids at that density infeasible in ~0.1s — and it was the direct cause
/// of the obscure fill this generator replaced. Fewer black squares means
/// longer entries means dense mutual interlocking. Treat white % as an
/// outcome, not a target.
enum CrosswordDifficulty {
  // At 5x5 one black square is 4% of the grid, so an 85% target caps mini at
  // three black squares and symmetry makes that effectively "zero or two".
  // 0.84 unlocks the four-black-square patterns standard in real NYT Minis.
  mini(
    label: 'Mini',
    size: 5,
    maxEntryLen: 5,
    whiteTarget: 0.84,
    maxAnchors: 1,
    overallBudget: Duration(seconds: 15),
    solveBudget: Duration(seconds: 3),
  ),
  midi(
    label: 'Midi',
    size: 9,
    maxEntryLen: 6,
    whiteTarget: 0.78,
    maxAnchors: 2,
    overallBudget: Duration(seconds: 25),
    solveBudget: Duration(seconds: 3),
  ),
  mega(
    label: 'Mega',
    size: 17,
    maxEntryLen: 9,
    whiteTarget: 0.72,
    maxAnchors: 3,
    overallBudget: Duration(seconds: 60),
    solveBudget: Duration(milliseconds: 1500),
  );

  final String label;

  /// Grids are always square; [size] is both width and height.
  final int size;

  /// No entry may exceed this. Enforced by splitting over-long white runs
  /// during skeleton generation (§4.2 phase 1), which is half of what makes
  /// the grids fillable — the other half is [whiteTarget].
  final int maxEntryLen;

  /// Target white fraction; see the class doc.
  final double whiteTarget;

  /// How many anchor entries (SRS words first, then theme words) to try to
  /// place. Measured against placement success in §7.1.
  final int maxAnchors;

  /// Wall clock for the whole `generatePuzzle` call, across every skeleton
  /// attempt. Generous relative to §11's measured times (0.14s at 5x5 and
  /// 9x9, 0.23s median at 17x17 with a worst seed of 8.3s) because this runs
  /// on a phone, on a background isolate, once a day.
  final Duration overallBudget;

  /// Wall clock for a single solve, well under the spec's flat 8s.
  ///
  /// Solve times are sharply bimodal: a skeleton that can be filled is filled
  /// in milliseconds (§11: 1.2ms / 4.3ms / 35ms median), and one that can't
  /// still hasn't been at 8s. Spending the full budget before giving up
  /// therefore buys almost nothing and costs the attempt budget. A short
  /// budget converts the same wall clock into several times as many
  /// skeletons, which is where the wins actually come from.
  final Duration solveBudget;

  const CrosswordDifficulty({
    required this.label,
    required this.size,
    required this.maxEntryLen,
    required this.whiteTarget,
    required this.maxAnchors,
    required this.overallBudget,
    required this.solveBudget,
  });

  String get storageKey => name;

  static CrosswordDifficulty fromStorageKey(String key) =>
      CrosswordDifficulty.values.firstWhere((d) => d.storageKey == key);
}

enum CrosswordDirection { across, down }

CrosswordDirection oppositeOf(CrosswordDirection d) =>
    d == CrosswordDirection.across ? CrosswordDirection.down : CrosswordDirection.across;

/// How a baked clue was derived (§2.5). Drives both the weighted pick in
/// `clues.dart` and the puzzle's clue-variety bonus (§9.2).
enum CrosswordClueType {
  /// Hand-authored, for words WordNet has no usable entry for (THE, AND,
  /// pronouns, prepositions). Rare but the highest quality per row.
  curated('c'),

  /// A WordNet gloss, capitalized with the terminal period removed. The bulk
  /// of the pool, and the most dictionary-sounding.
  definition('d'),

  /// Another lemma of the same synset — "Coroner" for MEDICALEXAMINER. Short
  /// and in the register a newspaper actually uses.
  synonym('s'),

  /// A gloss with the answer redacted to `___`.
  fillInBlank('f'),

  /// Written by a model at build time, for entries with no lexical source.
  llm('l'),

  /// Written for the puzzle by the clue bake (tool/bake_crossword_clues.dart)
  /// in a newspaper register, and passed through the same gate as every
  /// other outside clue. Replaces an entry's WordNet options where present.
  edited('e');

  final String code;
  const CrosswordClueType(this.code);

  static CrosswordClueType fromCode(String code) => switch (code) {
        'c' => CrosswordClueType.curated,
        's' => CrosswordClueType.synonym,
        'f' => CrosswordClueType.fillInBlank,
        'l' => CrosswordClueType.llm,
        'e' => CrosswordClueType.edited,
        _ => CrosswordClueType.definition,
      };
}

/// One baked clue option. The asset carries up to two per entry so a
/// recurring answer isn't clued identically every time (§2, §8).
class CrosswordClue {
  final String text;
  final CrosswordClueType type;

  const CrosswordClue(this.text, this.type);
}

/// One entry from the Crosswordler word-list asset
/// (`assets/crossword/wordlist.tsv`, packed by
/// `tool/pipeline/export_crossword_wordlist.py`). Mirrors the §2 schema.
///
/// [entryId] is this app's only addition: it points back at the dictionary
/// row an SRS anchor came from, so a word the user is studying can be linked
/// to its entry and credited back to the SRS when they solve it unaided.
/// Ordinary fill has no dictionary row behind it and carries -1.
class CrosswordEntry {
  /// Grid form: A-Z only, uppercase, no spaces or punctuation.
  final String text;

  /// Human form, may contain spaces or apostrophes ("I dos" for IDOS).
  final String display;

  /// Zipf frequency, ~0.0 (never observed) to ~7.0 (the/of/and).
  ///
  /// For multi-word entries this is **capped at 4.0 at build time** (§2.3):
  /// wordfreq cannot measure a phrase, it combines constituent frequencies
  /// under an independence assumption, and uncapped it scores "the the" at
  /// 7.43. For phrases the load-bearing recognizability signal is
  /// [editorTier], not frequency.
  final double freqZipf;

  /// Count of clue-eligible senses, excluding proper-noun senses (§2.2).
  final int synsetCount;

  final bool isProper;
  final bool isPhrase;

  /// On the hand-kept `CROSSWORDESE` list — words that are technically legal
  /// but chosen only for their convenient letters. Grown from complaints
  /// about real generated puzzles, and a hard exclusion from the fill pool
  /// rather than a scoring penalty: as a penalty six of them stayed in the
  /// pool and ERG reached a shipped puzzle.
  final bool isCrosswordese;

  /// Judged unfit for a puzzle by the clue bake — an abbreviation, a partial
  /// phrase, a word nobody knows — and so kept out of the fill pool. Still
  /// usable as an anchor: the bake clues it anyway.
  final bool isRejected;

  final List<String> tags;

  /// Precomputed composite quality, §2.3. Higher is better; the solver
  /// branches in descending score order.
  final double score;

  /// The Nediger tier (§2.1a) — a working constructor's judgement, and the
  /// most valuable single signal in the asset. **Not a quality ladder**: 25
  /// is "only if absolutely necessary" (excluded from fill), 51 is normal
  /// usable fill, 99 means "easy" when short and "an asset" from 8 letters
  /// up, and 0 just means absent from the list.
  final int editorTier;

  /// 1-5, "does a person actually know this word", from the build-time
  /// ratings pass. 5 when unrated, because a missing rating is not evidence
  /// against a word.
  ///
  /// This is the one fill-pool bar (§6.3) that cannot be derived from the
  /// other numbers. Frequency scores DES at 4.25 and AIN at 3.46 because
  /// below five characters it is counting a letter sequence in running text;
  /// the Nediger tier rates ABA 51 because a constructor's bar is "usable in
  /// a crossword", not "a learner knows this".
  final int familiarity;

  /// 1-2 clue options, best first (§2.5). Never empty for anything in the
  /// fill pool — an entry we cannot clue is one we never select.
  final List<CrosswordClue> clues;

  final int entryId;

  const CrosswordEntry({
    required this.text,
    required this.display,
    required this.freqZipf,
    required this.synsetCount,
    required this.isProper,
    required this.isPhrase,
    required this.isCrosswordese,
    this.isRejected = false,
    required this.tags,
    required this.score,
    required this.editorTier,
    required this.familiarity,
    required this.clues,
    this.entryId = -1,
  });

  int get length => text.length;

  /// An entry for a word that isn't in the list at all — the SRS path.
  /// §7.2: "If a word isn't in the list, synthesize an Entry for it anyway so
  /// it can still be placed — the SRS vocabulary is the point of the
  /// product." Scored high so anchor ordering puts it first.
  ///
  /// [clue] comes from the app's own bundled dictionary. §7.2 warns that an
  /// anchor arriving unclued falls through to a stub *in the puzzle's most
  /// prominent slot*; the app can always do better than a stub for a word the
  /// user is studying, so it resolves one before synthesizing.
  factory CrosswordEntry.synthetic({
    required String text,
    required String display,
    required int entryId,
    String? clue,
  }) =>
      CrosswordEntry(
        text: text,
        display: display,
        freqZipf: 3.0,
        synsetCount: 1,
        isProper: false,
        isPhrase: display.contains(' '),
        isCrosswordese: false,
        tags: const [],
        score: 100.0,
        editorTier: 51,
        familiarity: 5,
        clues: clue == null ? const [] : [CrosswordClue(clue, CrosswordClueType.curated)],
        entryId: entryId,
      );
}

class CrosswordWordPlacement {
  final int number;

  /// The slot this answer fills, stable for the life of the puzzle. The
  /// editorial reviewer (§9.3) keys its edits by this id, and re-solving a
  /// grid around pinned words (§9.4) needs slot identity to survive the
  /// round trip.
  final int slotId;
  final CrosswordDirection direction;
  final int row;
  final int col;
  final String answer;

  /// The natural human form of [answer] — "I dos" for IDOS. Shown once the
  /// answer is revealed or the puzzle is finished; a solver who only ever
  /// sees IDOS has been told less than the clue assumed.
  final String display;

  final int entryId;
  final String clue;
  final CrosswordClueType clueType;

  /// The answer's Zipf frequency, carried so the editorial prompt can show it
  /// without reloading the word list. It is what tells a reviewer that a
  /// candidate for replacement is genuinely obscure — with the standing
  /// caveat, stated in the prompt, that it is unreliable below four letters.
  final double freqZipf;

  /// Whether this word came from the user's SRS study pool rather than
  /// generic fill — powers the "N words from your study list" counter shown
  /// on the puzzle screen, and the retrieval credit fed back to the SRS when
  /// the user solves it unaided.
  final bool fromStudyPool;

  const CrosswordWordPlacement({
    required this.number,
    required this.slotId,
    required this.direction,
    required this.row,
    required this.col,
    required this.answer,
    required this.display,
    required this.entryId,
    required this.clue,
    this.clueType = CrosswordClueType.definition,
    this.freqZipf = 0,
    this.fromStudyPool = false,
  });

  /// The (row, col) of every cell this word occupies, in order.
  List<(int, int)> get cells => [
        for (var i = 0; i < answer.length; i++)
          direction == CrosswordDirection.across ? (row, col + i) : (row + i, col),
      ];

  CrosswordWordPlacement copyWith({String? clue, CrosswordClueType? clueType}) =>
      CrosswordWordPlacement(
        number: number,
        slotId: slotId,
        direction: direction,
        row: row,
        col: col,
        answer: answer,
        display: display,
        entryId: entryId,
        clue: clue ?? this.clue,
        clueType: clueType ?? this.clueType,
        freqZipf: freqZipf,
        fromStudyPool: fromStudyPool,
      );

  Map<String, dynamic> toJson() => {
        'number': number,
        'slotId': slotId,
        'direction': direction.name,
        'row': row,
        'col': col,
        'answer': answer,
        'display': display,
        'entryId': entryId,
        'clue': clue,
        'clueType': clueType.code,
        'freqZipf': freqZipf,
        'fromStudyPool': fromStudyPool,
      };

  factory CrosswordWordPlacement.fromJson(Map<String, dynamic> json) {
    final answer = json['answer'] as String;
    return CrosswordWordPlacement(
      number: json['number'] as int,
      // Puzzles saved before slot ids were persisted have none. -1 disables
      // the editorial pass for that puzzle (its edits could not be keyed
      // anyway) rather than failing to load a puzzle the user is mid-way
      // through.
      slotId: json['slotId'] as int? ?? -1,
      direction: CrosswordDirection.values.byName(json['direction'] as String),
      row: json['row'] as int,
      col: json['col'] as int,
      answer: answer,
      // Absent on puzzles saved before this field existed, which is not
      // hypothetical — real installs carry rows from an app version that
      // never wrote it, and casting straight through threw
      // "type 'Null' is not a subtype of type 'int'" for every one of them.
      // Repeat avoidance and prettier answer text are niceties; a saved
      // puzzle that will no longer load is not.
      display: json['display'] as String? ?? answer,
      entryId: json['entryId'] as int? ?? -1,
      clue: json['clue'] as String? ?? '',
      clueType: CrosswordClueType.fromCode(json['clueType'] as String? ?? 'd'),
      freqZipf: (json['freqZipf'] as num?)?.toDouble() ?? 0,
      fromStudyPool: json['fromStudyPool'] as bool? ?? false,
    );
  }
}

/// A generated, ready-to-render puzzle. Cell/grid geometry (which cells are
/// blocked, which numbers show) is derived from [words] on demand by the
/// solving screen rather than duplicated here — every white cell belongs to
/// both an across and a down entry (§4.1 rule 3), so [words] describes the
/// whole grid.
///
/// [seed] is stored because a puzzle *is* `(seed, size, weekday, srsWords,
/// blockedAnswers)` and nothing else: persisting it makes any puzzle exactly
/// reproducible, which is what makes a "this puzzle was broken" report
/// something that can be looked at rather than guessed about.
class CrosswordPuzzle {
  final int width;
  final int height;
  final List<CrosswordWordPlacement> words;
  final String? themeName;
  final String? themeKind;
  final double qualityScore;

  /// Grid forms of the anchors that were actually placed — the SRS and theme
  /// words the grid was built around. Exempt from the §9.1 quality gate, and
  /// protected from the refinement pass.
  final List<String> anchors;

  final int seed;

  /// Whether the editorial pass (§9.3) has already run over this puzzle, so
  /// it isn't reviewed twice.
  final bool reviewed;

  const CrosswordPuzzle({
    required this.width,
    required this.height,
    required this.words,
    this.themeName,
    this.themeKind,
    this.qualityScore = 0,
    this.anchors = const [],
    this.seed = 0,
    this.reviewed = false,
  });

  List<CrosswordWordPlacement> get across =>
      words.where((w) => w.direction == CrosswordDirection.across).toList()
        ..sort((a, b) => a.number.compareTo(b.number));

  List<CrosswordWordPlacement> get down =>
      words.where((w) => w.direction == CrosswordDirection.down).toList()
        ..sort((a, b) => a.number.compareTo(b.number));

  CrosswordPuzzle copyWith({List<CrosswordWordPlacement>? words, bool? reviewed}) =>
      CrosswordPuzzle(
        width: width,
        height: height,
        words: words ?? this.words,
        themeName: themeName,
        themeKind: themeKind,
        qualityScore: qualityScore,
        anchors: anchors,
        seed: seed,
        reviewed: reviewed ?? this.reviewed,
      );

  Map<String, dynamic> toJson() => {
        'width': width,
        'height': height,
        'words': words.map((w) => w.toJson()).toList(),
        if (themeName != null) 'themeName': themeName,
        if (themeKind != null) 'themeKind': themeKind,
        'qualityScore': qualityScore,
        'anchors': anchors,
        'seed': seed,
        'reviewed': reviewed,
      };

  factory CrosswordPuzzle.fromJson(Map<String, dynamic> json) => CrosswordPuzzle(
        width: json['width'] as int,
        height: json['height'] as int,
        words: (json['words'] as List)
            .map((w) => CrosswordWordPlacement.fromJson(w as Map<String, dynamic>))
            .toList(),
        themeName: json['themeName'] as String?,
        themeKind: json['themeKind'] as String?,
        qualityScore: (json['qualityScore'] as num?)?.toDouble() ?? 0,
        anchors: [for (final a in (json['anchors'] as List?) ?? const []) a as String],
        seed: json['seed'] as int? ?? 0,
        reviewed: json['reviewed'] as bool? ?? false,
      );
}

/// Puzzle sizes and the presentation model the solving screen renders.
///
/// The generator itself lives in `generator.dart`; everything here is either
/// a tuning constant from PORTING_SPEC.md §4.3 or a plain data holder.
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
  /// attempt. Generous relative to §11's measured times (~0.1-1.5s mini,
  /// ~0.13s midi, ~0.8-8s mega) because this runs on a phone, on a
  /// background isolate, once a day.
  final Duration overallBudget;

  /// Wall clock for a single solve, well under the spec's flat 8s.
  ///
  /// Solve times here are sharply bimodal: a skeleton that can be filled is
  /// filled in 20-350ms, and one that can't still hasn't been at 8s. Spending
  /// the full 8s before giving up therefore buys almost nothing and costs the
  /// attempt budget — at 8s a Mega generation fits about seven skeletons into
  /// its minute and failed 2 in 12. A short budget converts that same minute
  /// into several times as many skeletons, which is where the wins actually
  /// come from. Mega gets the shortest budget because it is the size that
  /// runs out of wall clock.
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

/// One entry from the scored word list asset (`assets/crossword/wordlist.tsv`,
/// built by `tool/pipeline/export_crossword_wordlist.py`). Mirrors the §2
/// schema; [entryId] is this app's addition, pointing back at the dictionary
/// row a clue is resolved from once the word is actually placed.
class CrosswordEntry {
  /// Grid form: A-Z only, uppercase, no spaces or punctuation.
  final String text;

  /// Human form, may carry an apostrophe ("don't" for DONT).
  final String display;

  final int entryId;

  /// Zipf frequency, ~0.0 (never observed) to ~7.7 ("the").
  final double freqZipf;

  /// Count of clue-eligible senses, excluding proper-noun senses (§2.2).
  final int synsetCount;

  final bool isProper;
  final bool isPhrase;

  /// Whether every clue-eligible sense is an "Abbreviation/Initialism/
  /// Acronym of X" gloss — such an entry can only be clued by spelling
  /// itself out. Scored down heavily at export time.
  final bool isAcronym;

  final List<String> tags;

  /// Precomputed composite quality, §2.3. Higher is better; the solver
  /// branches in descending score order.
  final double score;

  const CrosswordEntry({
    required this.text,
    required this.display,
    required this.entryId,
    required this.freqZipf,
    required this.synsetCount,
    required this.isProper,
    required this.isPhrase,
    required this.isAcronym,
    required this.tags,
    required this.score,
  });

  int get length => text.length;

  /// An entry for a word that isn't in the list at all — the SRS path.
  /// §7.2: "If a word isn't in the list, synthesize an Entry for it anyway so
  /// it can still be placed — the SRS vocabulary is the point of the
  /// product." Scored high so anchor ordering puts it first.
  factory CrosswordEntry.synthetic({
    required String text,
    required String display,
    required int entryId,
  }) =>
      CrosswordEntry(
        text: text,
        display: display,
        entryId: entryId,
        freqZipf: 3.0,
        synsetCount: 1,
        isProper: false,
        isPhrase: false,
        isAcronym: false,
        tags: const [],
        score: 100.0,
      );
}

class CrosswordWordPlacement {
  final int number;
  final CrosswordDirection direction;
  final int row;
  final int col;
  final String answer;
  final int entryId;
  final String clue;

  /// Whether this word came from the user's SRS study pool rather than
  /// generic fill — powers the "N words from your study list" counter shown
  /// on the puzzle screen.
  final bool fromStudyPool;

  const CrosswordWordPlacement({
    required this.number,
    required this.direction,
    required this.row,
    required this.col,
    required this.answer,
    required this.entryId,
    required this.clue,
    this.fromStudyPool = false,
  });

  /// The (row, col) of every cell this word occupies, in order.
  List<(int, int)> get cells => [
        for (var i = 0; i < answer.length; i++)
          direction == CrosswordDirection.across ? (row, col + i) : (row + i, col),
      ];

  CrosswordWordPlacement copyWith({String? clue}) => CrosswordWordPlacement(
        number: number,
        direction: direction,
        row: row,
        col: col,
        answer: answer,
        entryId: entryId,
        clue: clue ?? this.clue,
        fromStudyPool: fromStudyPool,
      );

  Map<String, dynamic> toJson() => {
        'number': number,
        'direction': direction.name,
        'row': row,
        'col': col,
        'answer': answer,
        'entryId': entryId,
        'clue': clue,
        'fromStudyPool': fromStudyPool,
      };

  factory CrosswordWordPlacement.fromJson(Map<String, dynamic> json) => CrosswordWordPlacement(
        number: json['number'] as int,
        direction: CrosswordDirection.values.byName(json['direction'] as String),
        row: json['row'] as int,
        col: json['col'] as int,
        answer: json['answer'] as String,
        // Absent on puzzles saved before this field existed, which is not
        // hypothetical — real installs carry rows from an app version that
        // never wrote it, and casting straight to int threw
        // "type 'Null' is not a subtype of type 'int'" for every one of them.
        // -1 is the same "no dictionary row behind this word" value the
        // generator uses, and clue lookup already skips it.
        entryId: json['entryId'] as int? ?? -1,
        clue: json['clue'] as String? ?? '',
        // Likewise absent on older rows — treat as generic filler rather than
        // failing to parse the saved puzzle.
        fromStudyPool: json['fromStudyPool'] as bool? ?? false,
      );
}

/// A generated, ready-to-render puzzle. Cell/grid geometry (which cells are
/// blocked, which numbers show) is derived from [words] on demand by the
/// solving screen rather than duplicated here — every white cell belongs to
/// both an across and a down entry (§4.1 rule 3), so [words] describes the
/// whole grid.
///
/// [themeName] and [qualityScore] are recorded but not rendered: §9.2's
/// score is reported rather than used to steer search, and the Sunday theme
/// mechanism (§7.3) hides its words on purpose.
class CrosswordPuzzle {
  final int width;
  final int height;
  final List<CrosswordWordPlacement> words;
  final String? themeName;
  final String? themeKind;
  final double qualityScore;

  const CrosswordPuzzle({
    required this.width,
    required this.height,
    required this.words,
    this.themeName,
    this.themeKind,
    this.qualityScore = 0,
  });

  List<CrosswordWordPlacement> get across =>
      words.where((w) => w.direction == CrosswordDirection.across).toList()
        ..sort((a, b) => a.number.compareTo(b.number));

  List<CrosswordWordPlacement> get down =>
      words.where((w) => w.direction == CrosswordDirection.down).toList()
        ..sort((a, b) => a.number.compareTo(b.number));

  Map<String, dynamic> toJson() => {
        'width': width,
        'height': height,
        'words': words.map((w) => w.toJson()).toList(),
        if (themeName != null) 'themeName': themeName,
        if (themeKind != null) 'themeKind': themeKind,
        'qualityScore': qualityScore,
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
      );
}

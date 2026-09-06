/// Tuning knobs for each puzzle size — a fixed grid filled via a real
/// North-American-style construction (symmetric black-square pattern +
/// constraint-solving fill, see `crossword_generator.dart`), not grown
/// organically from intersections. [blackRatio] trades a little density for
/// materially better word choice: benchmarking the fill against the actual
/// dictionary (weighted toward common words, see [crossword_generator])
/// showed that a few points more black space gives the solver enough slack
/// to avoid forcing obscure words into tight corners — e.g. at Mini's size,
/// 16% black produced ~70% obscure fill vs ~35% at 20%, for only a ~4-point
/// density drop (87.8% -> 83.7%), still far denser than the old organic
/// greedy generator's ~55-65% ceiling.
enum CrosswordDifficulty {
  mini(label: 'Mini', maxWidth: 7, maxHeight: 7, minWordLength: 3, maxWordLength: 7, blackRatio: 0.20),
  midi(label: 'Midi', maxWidth: 11, maxHeight: 11, minWordLength: 3, maxWordLength: 9, blackRatio: 0.18),
  mega(label: 'Mega', maxWidth: 15, maxHeight: 15, minWordLength: 3, maxWordLength: 12, blackRatio: 0.16);

  final String label;
  final int maxWidth;
  final int maxHeight;
  final int minWordLength;
  final int maxWordLength;
  final double blackRatio;

  const CrosswordDifficulty({
    required this.label,
    required this.maxWidth,
    required this.maxHeight,
    required this.minWordLength,
    required this.maxWordLength,
    required this.blackRatio,
  });

  String get storageKey => name;

  static CrosswordDifficulty fromStorageKey(String key) =>
      CrosswordDifficulty.values.firstWhere((d) => d.storageKey == key);
}

/// One word eligible for placement — a single-word, letters-only headword.
/// [fromStudyPool] distinguishes the handful of real study-pool words from
/// generic dictionary filler — the generator tries study-pool words first
/// within a matching slot so they reliably make it into the grid. Clue text
/// isn't resolved until after generation (see [CrosswordRepository]) —
/// there's no point fetching definitions for the ~99% of a 400k-word pool
/// that never gets placed.
class CrosswordCandidate {
  final int entryId;
  final String headword;
  final bool isDueToday;
  final bool fromStudyPool;
  final bool isAcronymOnly;

  const CrosswordCandidate({
    required this.entryId,
    required this.headword,
    required this.isDueToday,
    required this.fromStudyPool,
    this.isAcronymOnly = false,
  });
}

enum CrosswordDirection { across, down }

class CrosswordWordPlacement {
  final int number;
  final CrosswordDirection direction;
  final int row;
  final int col;
  final String answer;
  final int entryId;
  final String clue;
  // Whether this word came from the user's SRS study pool rather than
  // generic dictionary filler — powers the "N words from your study list"
  // counter shown on the puzzle screen.
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
        entryId: json['entryId'] as int,
        clue: json['clue'] as String,
        // Absent on puzzles saved before this field existed — treat as
        // generic filler rather than failing to parse the saved puzzle.
        fromStudyPool: json['fromStudyPool'] as bool? ?? false,
      );
}

/// A generated, ready-to-render puzzle. Cell/grid geometry (which cells are
/// blocked, which numbers show) is derived from [words] on demand by the
/// solving screen rather than duplicated here.
class CrosswordPuzzle {
  final int width;
  final int height;
  final List<CrosswordWordPlacement> words;

  const CrosswordPuzzle({required this.width, required this.height, required this.words});

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
      };

  factory CrosswordPuzzle.fromJson(Map<String, dynamic> json) => CrosswordPuzzle(
        width: json['width'] as int,
        height: json['height'] as int,
        words: (json['words'] as List)
            .map((w) => CrosswordWordPlacement.fromJson(w as Map<String, dynamic>))
            .toList(),
      );
}

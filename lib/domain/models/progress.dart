/// What the progress bar at the top of the Study tab and the progress
/// screen behind it are built from.
///
/// Everything here is a **count with a unit**, aggregated on read from the
/// ledgers (`review_log`, `game_results`, `lookup_log`, …) — there is no
/// stored score, and no composite one either. The one headline figure is
/// [ProgressOverview.mastered], because "words mastered" means something
/// outside the app and can't be inflated in an afternoon: it takes calendar
/// time for an interval to reach 90 days.
library;

/// Every word the user has touched, by how far along it is. Counts
/// **words**, not cards: a word studied both ways is one word, and it is
/// mastered only when both its cards are.
class ProgressOverview {
  final int mastered;
  final int reviewing;
  final int learning;

  /// In a list but not yet in study.
  final int unstudied;

  const ProgressOverview({
    required this.mastered,
    required this.reviewing,
    required this.learning,
    required this.unstudied,
  });

  int get studying => mastered + reviewing + learning;
  int get total => studying + unstudied;
}

/// One game at one difficulty.
class GameDifficultyStats {
  final String game;
  final String difficulty;
  final int completed;

  /// Completed without revealing anything.
  final int clean;

  /// Started but never finished.
  final int unfinished;

  /// Fastest and median clean solves; null until there is one with a
  /// measured time. Aided solves never rank — a time with reveals in it
  /// is not the same measurement.
  final Duration? best;
  final Duration? median;
  final Duration totalTime;

  const GameDifficultyStats({
    required this.game,
    required this.difficulty,
    required this.completed,
    required this.clean,
    required this.unfinished,
    required this.best,
    required this.median,
    required this.totalTime,
  });
}

/// A word looked up more than once — the strongest hint the app has that a
/// word wants studying.
class RepeatLookup {
  final int entryId;
  final String headword;
  final int count;
  final DateTime lastAt;
  final bool studying;

  const RepeatLookup({
    required this.entryId,
    required this.headword,
    required this.count,
    required this.lastAt,
    required this.studying,
  });
}

/// One calendar day of activity, for the heatmap.
class ActivityDay {
  final DateTime day;
  final int reviews;
  final int lookups;
  final int games;

  const ActivityDay({
    required this.day,
    required this.reviews,
    required this.lookups,
    required this.games,
  });

  int get total => reviews + lookups + games;
}

class ProgressSummary {
  final ProgressOverview overview;

  // Study
  final int reviews;
  final Duration studyTime;

  /// Share of reviews on mature cards (interval ≥ 21 days) not graded
  /// *Again*. Null until there have been any. This is the one number that
  /// punishes dishonest grading: tap Easy on everything and the intervals
  /// balloon, then the cards come back and fail.
  final double? retention;
  final int activeDays;
  final DateTime? firstActivity;

  // Games
  final List<GameDifficultyStats> games;

  // Lookups
  final int lookups;
  final int distinctLookups;
  final List<RepeatLookup> repeatLookups;

  // Reader
  final int readerDocuments;
  final int readerWords;

  // Collecting
  final int listWords;
  final int notes;

  const ProgressSummary({
    required this.overview,
    required this.reviews,
    required this.studyTime,
    required this.retention,
    required this.activeDays,
    required this.firstActivity,
    required this.games,
    required this.lookups,
    required this.distinctLookups,
    required this.repeatLookups,
    required this.readerDocuments,
    required this.readerWords,
    required this.listWords,
    required this.notes,
  });

  int get gamesCompleted => games.fold(0, (n, g) => n + g.completed);
  int get gamesClean => games.fold(0, (n, g) => n + g.clean);
}

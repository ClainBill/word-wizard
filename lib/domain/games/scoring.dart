/// How a play of a puzzle turns into leaderboard points. Computed on the
/// device from the puzzle's own state and uploaded per play; the server
/// only sums. One rule for everyone, so it lives here and nowhere else.
///
/// Crossword: points per correctly filled answer scale with the grid
/// (Mini ×1, Midi ×2, Mega ×3); finishing adds a bonus, finishing without
/// reveals adds another, and a clean finish under half an hour earns up
/// to 30 more for pace. An abandoned puzzle keeps the points for the
/// answers it got — progress counts.
///
/// Word Hunt: the board's own score (required words score their length,
/// bonus words one point) times five, plus a bonus for clearing the
/// required list.
library;

import '../crossword/crossword_models.dart';

int crosswordScore({
  required CrosswordDifficulty difficulty,
  required int solvedWords,
  required bool completed,
  required bool aided,
  required int activeMs,
}) {
  final scale = difficulty.index + 1;
  var score = solvedWords * 10 * scale;
  if (completed) {
    score += 50 * scale;
    if (!aided) {
      score += 25 * scale;
      final minutes = activeMs / 60000;
      if (activeMs > 0 && minutes < 30) score += ((30 - minutes) * scale).round();
    }
  }
  return score;
}

int huntLeaderboardScore({required int boardScore, required bool completed}) =>
    boardScore * 5 + (completed ? 50 : 0);

/// One play, as uploaded.
class PuzzlePlay {
  final String game;
  final String puzzleKey;
  final String playedOn; // YYYY-MM-DD
  final String difficulty;
  final int score;
  final bool completed;
  final int words;
  final int activeMs;
  final bool aided;

  const PuzzlePlay({
    required this.game,
    required this.puzzleKey,
    required this.playedOn,
    required this.difficulty,
    required this.score,
    required this.completed,
    required this.words,
    required this.activeMs,
    required this.aided,
  });

  Map<String, dynamic> toJson(String userId) => {
    'user_id': userId,
    'game': game,
    'puzzle_key': puzzleKey,
    'played_on': playedOn,
    'difficulty': difficulty,
    'score': score,
    'completed': completed,
    'words': words,
    'active_ms': activeMs,
    'aided': aided,
  };
}

/// One row of the public board: a name, a score, a rank — nothing that
/// identifies the account behind it.
class LeaderboardEntry {
  final int rank;
  final String name;
  final int score;
  final int puzzles;
  final bool isMe;

  const LeaderboardEntry({
    required this.rank,
    required this.name,
    required this.score,
    required this.puzzles,
    required this.isMe,
  });

  static LeaderboardEntry fromJson(Map<String, dynamic> json) => LeaderboardEntry(
    rank: (json['rank'] as num).toInt(),
    name: json['public_name'] as String? ?? '—',
    score: (json['score'] as num?)?.toInt() ?? 0,
    puzzles: (json['puzzles'] as num?)?.toInt() ?? 0,
    isMe: json['is_me'] == true,
  );
}

class MyRank {
  final int rank;
  final int score;
  final int puzzles;
  final int players;

  const MyRank({
    required this.rank,
    required this.score,
    required this.puzzles,
    required this.players,
  });

  static MyRank fromJson(Map<String, dynamic> json) => MyRank(
    rank: (json['rank'] as num).toInt(),
    score: (json['score'] as num?)?.toInt() ?? 0,
    puzzles: (json['puzzles'] as num?)?.toInt() ?? 0,
    players: (json['players'] as num?)?.toInt() ?? 0,
  );
}

/// What the person has told us about appearing on the board.
class LeaderboardProfile {
  final String? publicName;
  final bool optIn;

  const LeaderboardProfile({this.publicName, this.optIn = false});

  bool get visible => optIn && (publicName?.isNotEmpty ?? false);
}

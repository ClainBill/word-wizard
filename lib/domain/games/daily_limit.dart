/// How many puzzles of each kind a person gets in a day: the day's own and
/// one "start new". Each crossword gets the AI editor's pass, and the
/// server allows two edited puzzles per size per day (`ai_daily_limits`),
/// so the app stops at the same number rather than hand out puzzles the
/// editor won't touch. Word Hunt keeps the same rule, so every game reads
/// the same way. Group puzzles don't count: they're the group's, one a day.
const int puzzlesPerDay = 2;

/// Thrown by a repository asked for a new puzzle when today's allowance of
/// that kind is used up. The screens check first and don't offer it.
class DailyPuzzleLimitReached implements Exception {
  final String game;
  const DailyPuzzleLimitReached(this.game);

  @override
  String toString() => 'You\'ve had today\'s $puzzlesPerDay $game puzzles. New ones tomorrow.';
}

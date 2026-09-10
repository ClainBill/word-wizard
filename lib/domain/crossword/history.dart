/// What the user has already *solved*, which is what the cooldown must key
/// on — PORTING_SPEC.md §6.2a.
///
/// The brief says not to reuse "answers discovered by the user" in the
/// previous 10 puzzles. The obvious implementation — exclude everything that
/// appeared in the last 10 generated puzzles — is a different and weaker set,
/// and it gets the product backwards:
///
/// - A puzzle the user opened and abandoned taught them nothing, yet every
///   answer in it would be suppressed for ten puzzles.
/// - An answer they only got by revealing cells was not discovered either. It
///   should come back, because they still need to learn it.
///
/// The cooldown exists so a learner is not re-quizzed on what they already
/// know, and "already know" means they wrote it in unaided. Nothing here
/// reads a database or a clock, so it stays testable and ports directly.
library;

/// The brief's window: answers from the last N solve events are held back.
const int solveHistoryWindow = 10;

final _nonLetters = RegExp('[^A-Z]');

/// Grid form: A-Z only, so "I do's" and "IDOS" are the same answer.
String normalizeAnswer(String text) => text.toUpperCase().replaceAll(_nonLetters, '');

/// One puzzle the user actually played.
class CrosswordSolveEvent {
  final String puzzleId;

  /// Answers they entered correctly themselves.
  final Set<String> solved;

  /// Answers where **any** cell was given away by a hint or reveal. An answer
  /// in both sets counts as revealed: partial help still means it was not
  /// worked out.
  final Set<String> revealed;

  const CrosswordSolveEvent({
    required this.puzzleId,
    required this.solved,
    required this.revealed,
  });

  /// Normalizing constructor — callers can pass display forms.
  factory CrosswordSolveEvent.fromAnswers({
    required String puzzleId,
    Iterable<String> solved = const [],
    Iterable<String> revealed = const [],
  }) =>
      CrosswordSolveEvent(
        puzzleId: puzzleId,
        solved: {
          for (final a in solved)
            if (normalizeAnswer(a).isNotEmpty) normalizeAnswer(a),
        },
        revealed: {
          for (final a in revealed)
            if (normalizeAnswer(a).isNotEmpty) normalizeAnswer(a),
        },
      );

  Set<String> get learned => solved.difference(revealed);
}

/// Answers to keep out of the next puzzle.
///
/// [events] may be in any order as long as the most recent are last; only the
/// final [window] are considered, so a caller can hand over its whole history
/// without trimming it first.
Set<String> blockedAnswersFrom(
  List<CrosswordSolveEvent> events, {
  int window = solveHistoryWindow,
}) {
  final recent = window > 0 && events.length > window
      ? events.sublist(events.length - window)
      : events;
  return {
    for (final event in recent) ...event.learned,
  };
}

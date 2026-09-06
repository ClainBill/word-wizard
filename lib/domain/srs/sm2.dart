/// Grading buttons shown on a study card, in SM-2 quality order.
enum Grade { again, hard, good, easy }

extension GradeQuality on Grade {
  /// SM-2 quality-of-response value (0–5).
  int get q => switch (this) {
        Grade.again => 0,
        Grade.hard => 3,
        Grade.good => 4,
        Grade.easy => 5,
      };
}

/// Lifecycle stage of a [StudyCardState], derived from its repetition count
/// and interval rather than stored directly.
enum CardStage { newCard, learning, review, mastered }

const double _minEaseFactor = 1.3;
const double _masteredIntervalDays = 90;
const double _masteredEaseFactor = 2.5;
const double _easyBonus = 0.15;
const double _hardIntervalMultiplier = 1.2;

/// The SM-2 fields persisted per card — mirrors the `study_cards` columns.
class StudyCardState {
  final int repetitions;
  final double easeFactor;
  final int intervalDays;

  const StudyCardState({
    required this.repetitions,
    required this.easeFactor,
    required this.intervalDays,
  });

  /// A brand-new card that has never been graded.
  static const StudyCardState initial = StudyCardState(
    repetitions: 0,
    easeFactor: 2.5,
    intervalDays: 0,
  );

  CardStage get stage {
    if (repetitions == 0) return CardStage.newCard;
    if (intervalDays >= _masteredIntervalDays && easeFactor >= _masteredEaseFactor) {
      return CardStage.mastered;
    }
    if (repetitions < 2) return CardStage.learning;
    return CardStage.review;
  }

  StudyCardState copyWith({
    int? repetitions,
    double? easeFactor,
    int? intervalDays,
  }) {
    return StudyCardState(
      repetitions: repetitions ?? this.repetitions,
      easeFactor: easeFactor ?? this.easeFactor,
      intervalDays: intervalDays ?? this.intervalDays,
    );
  }
}

/// Result of grading a card: the new persisted state plus the resulting due date.
class SrsUpdate {
  final StudyCardState state;
  final DateTime dueAt;

  const SrsUpdate({required this.state, required this.dueAt});
}

/// A direct, unmodified implementation of SuperMemo-2 — see the "Algorithm"
/// section of the Word Wizard design doc for the reference formula this mirrors.
///
/// [Grade.hard] deviates from the textbook algorithm the same way Anki's
/// classic scheduler does: instead of running the EF formula, the interval
/// simply grows by [_hardIntervalMultiplier] and the ease factor is left
/// untouched.
SrsUpdate gradeCard(StudyCardState current, Grade grade, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final q = grade.q;

  if (grade == Grade.hard) {
    final interval = current.repetitions == 0
        ? 1
        : (current.intervalDays * _hardIntervalMultiplier).round().clamp(1, 1 << 30);
    final next = current.copyWith(intervalDays: interval);
    return SrsUpdate(state: next, dueAt: _addDays(today, interval));
  }

  if (q < 3) {
    final next = StudyCardState(
      repetitions: 0,
      easeFactor: current.easeFactor,
      intervalDays: 1,
    );
    return SrsUpdate(state: next, dueAt: _addDays(today, 1));
  }

  var ef = current.easeFactor + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02));
  if (grade == Grade.easy) ef += _easyBonus;
  ef = ef < _minEaseFactor ? _minEaseFactor : ef;

  final repetitions = current.repetitions + 1;
  final int interval;
  if (repetitions == 1) {
    interval = 1;
  } else if (repetitions == 2) {
    interval = 6;
  } else {
    interval = (current.intervalDays * ef).round().clamp(1, 1 << 30);
  }

  final next = StudyCardState(
    repetitions: repetitions,
    easeFactor: ef,
    intervalDays: interval,
  );
  return SrsUpdate(state: next, dueAt: _addDays(today, interval));
}

DateTime _addDays(DateTime from, int days) {
  final d = DateTime(from.year, from.month, from.day).add(Duration(days: days));
  return d;
}

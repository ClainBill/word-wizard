import '../srs/sm2.dart';
import 'study_direction.dart';

/// One row in the "manage study" browser — a word currently in the SRS
/// pool, with enough state to show its stage/history at a glance without a
/// second query per row.
///
/// One row **per direction**: a word studied both ways has two of these,
/// because each direction is separately scheduled and separately reviewed.
class StudyCardSummary {
  final int cardId;
  final int entryId;
  final String headword;
  final String pos;
  final StudyDirection direction;
  final DateTime createdAt;
  final DateTime dueAt;
  final bool paused;
  final int reviewCount;
  final StudyCardState srs;

  const StudyCardSummary({
    required this.cardId,
    required this.entryId,
    required this.headword,
    required this.pos,
    required this.direction,
    required this.createdAt,
    required this.dueAt,
    required this.paused,
    required this.reviewCount,
    required this.srs,
  });

  CardStage get stage => srs.stage;
}

/// One graded review, for the per-word history list.
class ReviewLogEntry {
  final DateTime reviewedAt;
  final Grade grade;
  final int priorInterval;

  const ReviewLogEntry({
    required this.reviewedAt,
    required this.grade,
    required this.priorInterval,
  });
}

extension GradeFromQuality on Grade {
  static Grade fromQ(int q) => switch (q) {
        0 => Grade.again,
        3 => Grade.hard,
        5 => Grade.easy,
        _ => Grade.good,
      };
}

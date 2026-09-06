/// Aggregate counts behind the Study tab's progress dashboard. A card counts
/// as "mastered" once its interval and ease factor clear the thresholds in
/// the design doc's SRS card lifecycle (interval >= 90 days, ease >= 2.5);
/// everything else still in the pool splits into "learning" (fewer than two
/// successful repetitions) and "reviewing" (two or more).
class StudyDashboardStats {
  final int dueToday;
  final int mastered;
  final int learning;
  final int reviewing;
  final int total;

  const StudyDashboardStats({
    required this.dueToday,
    required this.mastered,
    required this.learning,
    required this.reviewing,
    required this.total,
  });
}

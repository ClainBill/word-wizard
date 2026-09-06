import '../srs/sm2.dart';

/// A study card joined with the headword/gloss it's studying — everything
/// a study session screen needs without a second query.
class StudyCard {
  final int cardId;
  final int entryId;
  final String headword;
  final String pos;
  final String? ipa;
  final String? gloss;
  final String? example;
  final String? note;
  final StudyCardState srs;
  final DateTime dueAt;

  const StudyCard({
    required this.cardId,
    required this.entryId,
    required this.headword,
    required this.pos,
    this.ipa,
    this.gloss,
    this.example,
    this.note,
    required this.srs,
    required this.dueAt,
  });

  CardStage get stage => srs.stage;
}

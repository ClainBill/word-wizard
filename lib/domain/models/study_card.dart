import '../srs/sm2.dart';
import 'study_direction.dart';

/// One dictionary sense the user chose to carry on a word's study card.
class StudySense {
  final int senseId;
  final String gloss;

  /// The part of speech of the entry row this sense belongs to — which may
  /// differ from the card's own [StudyCard.pos] when the chosen sense lives
  /// under a sibling POS of the same headword ("muse" the verb on a card
  /// filed as a noun).
  final String pos;
  final String? example;

  const StudySense({required this.senseId, required this.gloss, required this.pos, this.example});
}

/// A study card joined with the headword/gloss it's studying — everything
/// a study session screen needs without a second query.
class StudyCard {
  final int cardId;
  final int entryId;
  final String headword;
  final String pos;
  final String? ipa;

  /// The meaning this card tests: the first of [senses]. Anything that
  /// reads a single gloss (the recall games, the reminder notification)
  /// follows whatever the card was dealt without knowing about it.
  final String? gloss;
  final String? example;
  final String? note;

  /// The meanings this card carries, in dictionary order — the ones the
  /// user pinned, or, with no pin, one or two drawn at random for this
  /// session. Empty only for a word with no senses at all, or a card that
  /// hasn't been through the repository's hydration. When there is more
  /// than one, the card's back lists them all; [gloss] is just the first.
  final List<StudySense> senses;

  /// Which way round this card is asked. Decides what the front shows, what
  /// counts as "knowing it", and which family of recall games can help.
  final StudyDirection direction;

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
    this.senses = const [],
    this.direction = StudyDirection.wordToMeaning,
    required this.srs,
    required this.dueAt,
  });

  CardStage get stage => srs.stage;

  /// The distinct parts of speech of [senses], in order — what the card's
  /// header should say. Falls back to the entry's own [pos] for a card
  /// with no senses.
  List<String> get posTags {
    if (senses.isEmpty) return [pos];
    final seen = <String>{};
    return [
      for (final s in senses)
        if (seen.add(s.pos)) s.pos,
    ];
  }

  /// The same card carrying [chosen] as its [senses], with [gloss] and
  /// [example] re-pointed at the first of them. An empty list leaves the
  /// card exactly as it was.
  StudyCard withSenses(List<StudySense> chosen) {
    if (chosen.isEmpty) return this;
    final first = chosen.first;
    final firstExample = chosen.map((s) => s.example).whereType<String>().firstOrNull;
    return StudyCard(
      cardId: cardId,
      entryId: entryId,
      headword: headword,
      pos: pos,
      ipa: ipa,
      gloss: first.gloss,
      example: firstExample,
      note: note,
      senses: chosen,
      direction: direction,
      srs: srs,
      dueAt: dueAt,
    );
  }
}

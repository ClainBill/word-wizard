/// The word of the day — one of the pipeline's curated `daily_words` pool
/// (tool/pipeline/daily_words.py), chosen by the date so every device
/// shows the same word on the same day and it never needs a server.
class DailyWord {
  final DateTime day;
  final int entryId;
  final String headword;
  final String pos;
  final String gloss;
  final String? example;

  const DailyWord({
    required this.day,
    required this.entryId,
    required this.headword,
    required this.pos,
    required this.gloss,
    this.example,
  });

  /// The notification's text: the meaning, then the example in quotes.
  String get notificationBody {
    final m = gloss.trim();
    final sentence = m.endsWith('.') || m.endsWith('!') || m.endsWith('?') ? m : '$m.';
    final ex = example?.trim();
    return ex == null || ex.isEmpty ? sentence : '$sentence "$ex"';
  }
}

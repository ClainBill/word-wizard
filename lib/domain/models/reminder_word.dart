/// A word + one-sentence meaning + one-sentence example, formatted for the
/// twice-daily study-reminder notification.
class ReminderWord {
  final String headword;
  final String meaning;
  final String? example;

  const ReminderWord({required this.headword, required this.meaning, this.example});

  String get notificationBody {
    final m = meaning.trim();
    final sentence = m.endsWith('.') || m.endsWith('!') || m.endsWith('?') ? m : '$m.';
    final ex = example?.trim();
    return ex == null || ex.isEmpty ? sentence : '$sentence "$ex"';
  }
}

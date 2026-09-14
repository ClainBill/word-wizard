import 'dart:math';

/// Daily themes for the hunt — `assets/hunt/themes.tsv`, one Wiktionary
/// topic per line with the familiar words whose primary sense carries it.
///
/// The day picks a topic; the topic supplies one anchor word the board is
/// built around, and every other topic word the board happens to contain
/// lights up as a theme find. Fully offline and deterministic: the same
/// date always gets the same topic, and the same seed the same anchor.
class HuntTheme {
  final String label;
  final Set<String> words;

  const HuntTheme({required this.label, required this.words});

  /// Words a board can be built around: long enough to be a satisfying
  /// target, short enough to leave the other anchors room.
  Iterable<String> get anchorCandidates => words.where((w) => w.length >= 5 && w.length <= 9);
}

class HuntThemeSet {
  final List<HuntTheme> themes;

  const HuntThemeSet(this.themes);

  static HuntThemeSet parse(String tsv) {
    final themes = <HuntTheme>[];
    for (final line in tsv.split('\n')) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final tab = line.indexOf('\t');
      if (tab < 0) continue;
      final words = {
        for (final w in line.substring(tab + 1).split(','))
          if (w.isNotEmpty) w,
      };
      if (words.isEmpty) continue;
      themes.add(HuntTheme(label: line.substring(0, tab), words: words));
    }
    return HuntThemeSet(themes);
  }

  bool get isEmpty => themes.isEmpty;

  /// The topic for a calendar day ('YYYY-MM-DD'). Consecutive days walk the
  /// list in a fixed shuffled order rather than by raw hash, so two nearby
  /// days repeating a topic is as rare as the list allows.
  HuntTheme? forDate(String date) {
    if (themes.isEmpty) return null;
    final day = _dayNumber(date);
    final order = [for (var i = 0; i < themes.length; i++) i]..shuffle(Random(0x5eed));
    // Cycle through the shuffled order, re-shuffling per cycle so the
    // sequence of topics doesn't simply repeat every N days.
    final cycle = day ~/ themes.length;
    if (cycle != 0) order.shuffle(Random(0x5eed + cycle));
    return themes[order[day % themes.length]];
  }

  /// Picks the theme anchor for a board: a random anchor-sized word from
  /// [theme], skipping [exclude] (recent boards' theme words) when that
  /// still leaves a choice.
  static String? pickAnchor(HuntTheme theme, Random rng, {Set<String> exclude = const {}}) {
    final all = theme.anchorCandidates.toList()..sort();
    if (all.isEmpty) return null;
    final fresh = [for (final w in all) if (!exclude.contains(w)) w];
    final pool = fresh.isEmpty ? all : fresh;
    return pool[rng.nextInt(pool.length)];
  }

  static int _dayNumber(String date) {
    final parsed = DateTime.tryParse(date) ?? DateTime(2026);
    return DateTime.utc(parsed.year, parsed.month, parsed.day).difference(DateTime.utc(2020)).inDays;
  }
}

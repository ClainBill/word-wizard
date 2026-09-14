/// Shared number formatting for the progress surfaces, so a solve time reads
/// the same on the crossword, its history and the progress screen.
library;

/// Stopwatch style — `6:12`, or `1:02:05` past an hour. For a single
/// solve, where the seconds matter.
String formatClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// Rounded span — `42s`, `18m`, `3h 12m`, `2d 5h`. For totals, where the
/// seconds don't.
String formatSpan(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) {
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${m}m';
  }
  final h = d.inHours % 24;
  return h == 0 ? '${d.inDays}d' : '${d.inDays}d ${h}h';
}

/// `1,240` — thousands separated, no decimals.
String formatCount(int n) {
  final s = n.abs().toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return n < 0 ? '-$out' : out.toString();
}

/// `91%` from a 0..1 ratio; null when there is nothing to take a ratio of.
String formatPercent(double? ratio) => ratio == null ? '—' : '${(ratio * 100).round()}%';

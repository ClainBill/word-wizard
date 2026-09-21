import 'package:flutter/material.dart';

/// What Premium looks like, moving: a real Mini crossword filling itself
/// in, and a Word Hunt board tracing real words, side by side (spec §3.1,
/// §3.3). Both loop like a GIF but are drawn live, so they follow the
/// theme, weigh nothing, and stop for people who've asked for less motion
/// (spec §7.1) — showing the finished state instead.
class PremiumPreview extends StatelessWidget {
  const PremiumPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _Labelled(label: 'Crossword', child: CrosswordDemo()),
          ),
          SizedBox(width: 14),
          Expanded(
            child: _Labelled(label: 'Word Hunt', child: HuntDemo()),
          ),
        ],
      ),
    );
  }
}

class _Labelled extends StatelessWidget {
  final String label;
  final Widget child;

  const _Labelled({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// Loops an animation, or holds it at the end under reduced motion.
class _Loop extends StatefulWidget {
  final Duration period;
  final Widget Function(BuildContext context, double t) builder;

  const _Loop({required this.period, required this.builder});

  @override
  State<_Loop> createState() => _LoopState();
}

class _LoopState extends State<_Loop> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    if (still) {
      _controller.stop();
      return widget.builder(context, 1);
    }
    if (!_controller.isAnimating) _controller.repeat();
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => widget.builder(context, _controller.value),
    );
  }
}

/// A genuine Mini, built by the app's own generator (seed 404 against the
/// shipped word list): black corners, five across, five down, nothing
/// shared between them. `#` is a black square.
const List<String> demoGrid = ['#WAS#', 'PHOTO', 'TIRED', 'ACTED', '#HAD#'];

/// The across entries in fill order: (number, row, col, answer, clue).
const List<(int, int, int, String, String)> demoAcross = [
  (1, 0, 1, 'WAS', 'Existed, once'),
  (4, 1, 0, 'PHOTO', 'Picture'),
  (6, 2, 0, 'TIRED', 'Worn out'),
  (7, 3, 0, 'ACTED', 'Took the stage'),
  (8, 4, 1, 'HAD', 'Possessed'),
];

/// The downs, for the tests and the numbering: (number, row, col, answer).
const List<(int, int, int, String)> demoDown = [
  (1, 0, 1, 'WHICH'),
  (2, 0, 2, 'AORTA'),
  (3, 0, 3, 'STEED'),
  (4, 1, 0, 'PTA'),
  (5, 1, 4, 'ODD'),
];

/// Cell → clue number, from the entries above.
final Map<(int, int), int> _demoNumbers = {
  for (final (n, r, c, _, _) in demoAcross) (r, c): n,
  for (final (n, r, c, _) in demoDown) (r, c): n,
};

/// The order cells get their letters: across, word by word.
final List<(int, int, String)> _demoFill = [
  for (final (_, r, c, answer, _) in demoAcross)
    for (var i = 0; i < answer.length; i++) (r, c + i, answer[i]),
];

/// Types the across answers in, one letter at a time; holds; clears.
class CrosswordDemo extends StatelessWidget {
  const CrosswordDemo({super.key});

  static const _perLetter = Duration(milliseconds: 150);
  static const _hold = Duration(milliseconds: 1800);

  @override
  Widget build(BuildContext context) {
    final letters = _demoFill.length;
    final total = _perLetter * letters + _hold;
    return _Loop(
      period: total,
      builder: (context, t) {
        final elapsedMs = t * total.inMilliseconds;
        final typed = (elapsedMs / _perLetter.inMilliseconds).floor().clamp(0, letters);
        // Which across word the cursor is in.
        var wordIndex = 0;
        var seen = 0;
        for (; wordIndex < demoAcross.length - 1; wordIndex++) {
          seen += demoAcross[wordIndex].$4.length;
          if (typed < seen) break;
        }
        final done = typed >= letters;
        final word = demoAcross[wordIndex];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: _MiniGrid(typed: typed, activeWord: done ? null : wordIndex),
            ),
            const SizedBox(height: 6),
            Text(
              done ? 'Solved · 0:41' : '${word.$1}A · ${word.$5}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MiniGrid extends StatelessWidget {
  final int typed;
  final int? activeWord;

  const _MiniGrid({required this.typed, required this.activeWord});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filled = <(int, int), String>{
      for (final (r, c, letter) in _demoFill.take(typed)) (r, c): letter,
    };
    final cursor = typed < _demoFill.length ? (_demoFill[typed].$1, _demoFill[typed].$2) : null;
    final active = activeWord == null ? null : demoAcross[activeWord!];
    final dark = Theme.of(context).brightness == Brightness.dark;
    final block = dark ? scheme.surfaceContainerLowest : scheme.onSurface;
    return LayoutBuilder(
      builder: (context, constraints) {
        const n = 5;
        const gap = 1.5;
        final size = (constraints.maxWidth - gap * (n - 1)) / n;
        return Column(
          children: [
            for (var r = 0; r < n; r++) ...[
              if (r > 0) const SizedBox(height: gap),
              Row(
                children: [
                  for (var c = 0; c < n; c++) ...[
                    if (c > 0) const SizedBox(width: gap),
                    if (demoGrid[r][c] == '#')
                      Container(
                        width: size,
                        height: size,
                        decoration: BoxDecoration(
                          color: block,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      )
                    else
                      _Cell(
                        size: size,
                        letter: filled[(r, c)] ?? '',
                        number: _demoNumbers[(r, c)]?.toString(),
                        cursor: cursor == (r, c),
                        rounded: 2,
                        background:
                            active != null &&
                                r == active.$2 &&
                                c >= active.$3 &&
                                c < active.$3 + active.$4.length
                            ? scheme.primary.withValues(alpha: 0.18)
                            : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      ),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Cell extends StatelessWidget {
  final double size;
  final String letter;
  final String? number;
  final bool cursor;
  final double rounded;
  final Color background;

  const _Cell({
    required this.size,
    required this.letter,
    this.number,
    this.cursor = false,
    required this.rounded,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cursor ? scheme.primary.withValues(alpha: 0.45) : background,
        borderRadius: BorderRadius.circular(rounded),
        border: Border.all(color: scheme.outlineVariant, width: 0.5),
      ),
      child: Stack(
        children: [
          if (number != null)
            Positioned(
              left: 1.5,
              top: 0,
              child: Text(
                number!,
                style: TextStyle(fontSize: size * 0.22, color: scheme.onSurfaceVariant),
              ),
            ),
          Center(
            child: Text(
              letter,
              style: TextStyle(
                fontSize: size * 0.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A 4×4 board with real words on it, and the paths that trace them.
const List<String> demoBoard = ['WORK', 'EADS', 'LRNT', 'PIEY'];

/// (word, cells as row*4+col) — each a genuine traceable path.
const List<(String, List<int>)> demoHuntWords = [
  ('WORD', [0, 1, 2, 6]),
  ('LEARN', [8, 4, 5, 9, 10]),
  ('PIE', [12, 13, 14]),
  ('EARN', [4, 5, 9, 10]),
];

/// Traces each word cell by cell, holds it lit with its name, moves on.
class HuntDemo extends StatelessWidget {
  const HuntDemo({super.key});

  static const _perCell = Duration(milliseconds: 230);
  static const _hold = Duration(milliseconds: 900);

  @override
  Widget build(BuildContext context) {
    final steps = [for (final w in demoHuntWords) _perCell * w.$2.length + _hold];
    final total = steps.fold(Duration.zero, (a, b) => a + b);
    return _Loop(
      period: total,
      builder: (context, t) {
        var elapsed = t * total.inMilliseconds;
        var index = 0;
        for (; index < steps.length - 1; index++) {
          if (elapsed < steps[index].inMilliseconds) break;
          elapsed -= steps[index].inMilliseconds;
        }
        final (word, path) = demoHuntWords[index];
        final lit = (elapsed / _perCell.inMilliseconds).floor().clamp(0, path.length);
        final found = lit >= path.length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: _HuntBoard(litPath: path.sublist(0, t >= 1 ? path.length : lit)),
            ),
            const SizedBox(height: 6),
            Text(
              found || t >= 1 ? '$word ✓' : word.substring(0, lit),
              maxLines: 1,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: found
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HuntBoard extends StatelessWidget {
  final List<int> litPath;

  const _HuntBoard({required this.litPath});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        const n = 4;
        const gap = 4.0;
        final size = (constraints.maxWidth - gap * (n - 1)) / n;
        final lit = litPath.toSet();
        return CustomPaint(
          foregroundPainter: _PathPainter(
            path: litPath,
            cell: size,
            gap: gap,
            color: scheme.secondary.withValues(alpha: 0.55),
          ),
          child: Column(
            children: [
              for (var r = 0; r < n; r++) ...[
                if (r > 0) const SizedBox(height: gap),
                Row(
                  children: [
                    for (var c = 0; c < n; c++) ...[
                      if (c > 0) const SizedBox(width: gap),
                      _Cell(
                        size: size,
                        letter: demoBoard[r][c],
                        rounded: 8,
                        background: lit.contains(r * n + c)
                            ? scheme.secondary.withValues(alpha: 0.35)
                            : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The line through the traced cells' centres.
class _PathPainter extends CustomPainter {
  final List<int> path;
  final double cell;
  final double gap;
  final Color color;

  const _PathPainter({
    required this.path,
    required this.cell,
    required this.gap,
    required this.color,
  });

  Offset _centre(int index) {
    final r = index ~/ 4, c = index % 4;
    return Offset(c * (cell + gap) + cell / 2, r * (cell + gap) + cell / 2);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (path.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = cell * 0.18
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final line = Path()..moveTo(_centre(path.first).dx, _centre(path.first).dy);
    for (final i in path.skip(1)) {
      line.lineTo(_centre(i).dx, _centre(i).dy);
    }
    canvas.drawPath(line, paint);
  }

  @override
  bool shouldRepaint(_PathPainter old) => old.path != path || old.cell != cell;
}

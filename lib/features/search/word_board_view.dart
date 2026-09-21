import 'dart:math';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../domain/board/word_board.dart';

/// The Search tab's landing view: a crossword-style board of tiles that
/// grows outward from the word of the day, one word at a time, until it
/// runs out of room or words. Drag to explore, pinch to zoom, tap a word
/// to open it. Tiles are tinted by how well the word is known, so the
/// board becomes more and more theirs as the Lexery grows.
class WordBoardView extends StatefulWidget {
  /// The word the board grows from — across through the middle.
  final String seed;

  /// A small caption painted above the seed ("Word of the day").
  final String? seedCaption;

  /// Candidate words, in the order they should be tried.
  final List<String> words;

  /// How well each word is known; anything missing is unknown.
  final Map<String, Familiarity> familiarity;

  final ValueChanged<String> onOpen;
  final VoidCallback onShuffle;

  /// Stops growing here, whatever the pool still holds.
  final int maxWords;

  const WordBoardView({
    super.key,
    required this.seed,
    this.seedCaption,
    required this.words,
    required this.familiarity,
    required this.onOpen,
    required this.onShuffle,
    this.maxWords = 80,
  });

  /// Pixels per grid cell, tile and gap together.
  static const double cell = 42;

  @override
  State<WordBoardView> createState() => _WordBoardViewState();
}

class _WordBoardViewState extends State<WordBoardView> with SingleTickerProviderStateMixin {
  static const _growEvery = Duration(milliseconds: 260);
  static const _tileIn = Duration(milliseconds: 360);
  static const _stagger = Duration(milliseconds: 45);

  late WordBoard _board;
  late WordBoardGrower _grower;
  late final Ticker _ticker;
  final _transform = TransformationController();

  /// When each word (by placement order) appeared, on the ticker's clock.
  final Map<int, Duration> _placedAt = {};
  Duration _elapsed = Duration.zero;
  Duration _lastGrowth = Duration.zero;
  bool _done = false;
  bool _centred = false;

  double get _canvas => _board.size * WordBoardView.cell;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _start();
  }

  @override
  void didUpdateWidget(WordBoardView old) {
    super.didUpdateWidget(old);
    if (old.seed != widget.seed || !identical(old.words, widget.words)) {
      _start();
      if (MediaQuery.disableAnimationsOf(context)) _growAll();
    }
  }

  void _start() {
    _board = WordBoard();
    _board.placeSeed(widget.seed);
    _grower = WordBoardGrower(_board, pool: widget.words.where(isBoardable).toList());
    _placedAt
      ..clear()
      ..[0] = Duration.zero;
    _elapsed = Duration.zero;
    _lastGrowth = Duration.zero;
    _done = false;
    if (_ticker.isActive) _ticker.stop();
    _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion: the whole board at once, no ticker.
    if (MediaQuery.disableAnimationsOf(context) && !_done) {
      _growAll();
    }
  }

  void _growAll() {
    while (!_grower.exhausted && _board.words.length < widget.maxWords) {
      final placed = _grower.next();
      if (placed != null) _placedAt[placed.order] = Duration.zero;
    }
    _done = true;
    if (_ticker.isActive) _ticker.stop();
    // Past every entry animation, so the painter draws everything settled.
    _elapsed = _tileIn * 20;
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    if (!_done && elapsed - _lastGrowth >= _growEvery) {
      _lastGrowth = elapsed;
      if (_board.words.length >= widget.maxWords || _grower.exhausted) {
        _done = true;
      } else {
        final placed = _grower.next();
        if (placed != null) _placedAt[placed.order] = elapsed;
      }
    }
    if (_done) {
      final last = _placedAt.values.fold(Duration.zero, (a, b) => a > b ? a : b);
      final longest = _board.words.fold(0, (n, w) => max(n, w.length));
      if (elapsed > last + _tileIn + _stagger * longest) _ticker.stop();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    _transform.dispose();
    super.dispose();
  }

  /// Puts the seed in the middle of the viewport.
  void _centre(Size viewport, {double scale = 1}) {
    final mid = _canvas / 2;
    _transform.value = Matrix4.identity()
      ..translateByDouble(viewport.width / 2 - mid * scale, viewport.height / 2 - mid * scale, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _onTap(TapUpDetails d) {
    final col = d.localPosition.dx ~/ WordBoardView.cell;
    final row = d.localPosition.dy ~/ WordBoardView.cell;
    final words = _board.wordsAt(row, col);
    if (words.isEmpty) return;
    if (words.length == 1) {
      widget.onOpen(words.single.word);
      return;
    }
    // A crossing: ask which.
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final w in words)
              ListTile(
                leading: Icon(w.across ? Icons.arrow_forward : Icons.arrow_downward),
                title: Text(w.word),
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onOpen(w.word);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final colours = _TileColours(
      unknown: dark ? const Color(0xFF6B5637) : const Color(0xFFF6E7C9),
      onUnknown: dark ? const Color(0xFFFBEFD6) : const Color(0xFF3E3123),
      studying: scheme.primaryContainer,
      onStudying: scheme.onPrimaryContainer,
      mastered: scheme.primary,
      onMastered: scheme.onPrimary,
      dots: scheme.outlineVariant.withValues(alpha: dark ? 0.35 : 0.6),
      caption: scheme.onSurfaceVariant,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!_centred && constraints.hasBoundedWidth && constraints.hasBoundedHeight) {
          _centred = true;
          _centre(constraints.biggest);
        }
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _transform,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(600),
                minScale: 0.45,
                maxScale: 2.2,
                child: GestureDetector(
                  onTapUp: _onTap,
                  child: CustomPaint(
                    size: Size(_canvas, _canvas),
                    painter: _BoardPainter(
                      board: _board,
                      familiarity: widget.familiarity,
                      placedAt: _placedAt,
                      elapsed: _elapsed,
                      tileIn: _tileIn,
                      stagger: _stagger,
                      colours: colours,
                      seedCaption: widget.seedCaption,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _Legend(
                colours: colours,
                onShuffle: widget.onShuffle,
                onCentre: () => _centre(constraints.biggest),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TileColours {
  final Color unknown, onUnknown, studying, onStudying, mastered, onMastered, dots, caption;
  const _TileColours({
    required this.unknown,
    required this.onUnknown,
    required this.studying,
    required this.onStudying,
    required this.mastered,
    required this.onMastered,
    required this.dots,
    required this.caption,
  });

  Color fill(Familiarity f) => switch (f) {
    Familiarity.unknown => unknown,
    Familiarity.studying => studying,
    Familiarity.mastered => mastered,
  };

  Color ink(Familiarity f) => switch (f) {
    Familiarity.unknown => onUnknown,
    Familiarity.studying => onStudying,
    Familiarity.mastered => onMastered,
  };
}

/// What the colours mean, and the two buttons — a translucent strip along
/// the bottom of the board.
class _Legend extends StatelessWidget {
  final _TileColours colours;
  final VoidCallback onShuffle;
  final VoidCallback onCentre;

  const _Legend({required this.colours, required this.onShuffle, required this.onCentre});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.surface.withValues(alpha: 0),
            scheme.surface.withValues(alpha: 0.9),
            scheme.surface,
          ],
        ),
      ),
      child: Row(
        children: [
          _Swatch(colours.unknown, 'new'),
          const SizedBox(width: 12),
          _Swatch(colours.studying, 'in your Lexery'),
          const SizedBox(width: 12),
          _Swatch(colours.mastered, 'mastered'),
          const Spacer(),
          IconButton(
            tooltip: 'Back to the middle',
            icon: const Icon(Icons.center_focus_weak),
            onPressed: onCentre,
          ),
          IconButton(tooltip: 'New words', icon: const Icon(Icons.shuffle), onPressed: onShuffle),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final String label;
  const _Swatch(this.color, this.label);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _BoardPainter extends CustomPainter {
  final WordBoard board;
  final Map<String, Familiarity> familiarity;
  final Map<int, Duration> placedAt;
  final Duration elapsed;
  final Duration tileIn;
  final Duration stagger;
  final _TileColours colours;
  final String? seedCaption;

  _BoardPainter({
    required this.board,
    required this.familiarity,
    required this.placedAt,
    required this.elapsed,
    required this.tileIn,
    required this.stagger,
    required this.colours,
    required this.seedCaption,
  });

  static const double _cell = WordBoardView.cell;
  static const double _gap = 5;
  static const double _tile = _cell - _gap;

  /// Letters and values are the same few glyphs over and over; laid out
  /// once per colour and reused across frames.
  static final Map<String, TextPainter> _glyphs = {};

  static TextPainter _glyph(String text, Color color, double size, FontWeight weight) {
    final key = '$text|${color.toARGB32()}|$size|${weight.value}';
    return _glyphs.putIfAbsent(key, () {
      return TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: color, fontSize: size, fontWeight: weight, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  /// 0 → 1 as the i-th tile of [w] comes in.
  double _progress(PlacedWord w, int i) {
    final at = placedAt[w.order];
    if (at == null) return 0;
    final t = (elapsed - at - stagger * i).inMilliseconds / tileIn.inMilliseconds;
    return t.clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintDots(canvas, size);

    // Each cell once, tinted by the best-known word through it and as far
    // in as the earlier of its words.
    final done = <int>{};
    for (final w in board.words) {
      final f = familiarity[w.word] ?? Familiarity.unknown;
      for (var i = 0; i < w.length; i++) {
        final r = w.rowAt(i), c = w.colAt(i);
        final key = r * board.size + c;
        if (!done.add(key)) continue;
        var best = f;
        var progress = _progress(w, i);
        for (final other in board.wordsAt(r, c)) {
          if (identical(other, w)) continue;
          final of = familiarity[other.word] ?? Familiarity.unknown;
          if (Familiarity.values.indexOf(of) > Familiarity.values.indexOf(best)) best = of;
          final j = other.across ? c - other.col : r - other.row;
          progress = max(progress, _progress(other, j));
        }
        if (progress <= 0) continue;
        _paintTile(canvas, r, c, w.word[i], best, progress);
      }
    }

    final caption = seedCaption;
    if (caption != null && board.words.isNotEmpty) {
      final seed = board.words.first;
      if (_progress(seed, 0) > 0) _paintCaption(canvas, seed, caption);
    }
  }

  /// The caption goes in the longest run of empty cells directly above the
  /// seed — or below it — that's wide enough; words crossing the seed take
  /// cells on both sides, so there's no fixed spot that's always free.
  void _paintCaption(Canvas canvas, PlacedWord seed, String caption) {
    final tp = _glyph(caption.toUpperCase(), colours.caption, 10, FontWeight.w700);
    for (final row in [seed.row - 1, seed.row + 1]) {
      var bestStart = 0, bestLen = 0, start = 0, len = 0;
      for (var i = 0; i <= seed.length; i++) {
        final free = i < seed.length && board.letterAt(row, seed.colAt(i)) == null;
        if (free) {
          if (len == 0) start = i;
          len++;
          if (len > bestLen) {
            bestLen = len;
            bestStart = start;
          }
        } else {
          len = 0;
        }
      }
      final width = bestLen * _cell - _gap;
      if (width < tp.width + 4) continue;
      final x = (seed.col + bestStart) * _cell + (width - tp.width) / 2;
      final y = row == seed.row - 1
          ? seed.row * _cell - tp.height - 6
          : seed.row * _cell + _tile + 6;
      tp.paint(canvas, Offset(x, y));
      return;
    }
  }

  void _paintDots(Canvas canvas, Size size) {
    final points = <Offset>[];
    for (var r = 0; r <= board.size; r++) {
      for (var c = 0; c <= board.size; c++) {
        points.add(Offset(c * _cell - _gap / 2, r * _cell - _gap / 2));
      }
    }
    canvas.drawPoints(
      PointMode.points,
      points,
      Paint()
        ..color = colours.dots
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  void _paintTile(Canvas canvas, int r, int c, String letter, Familiarity f, double progress) {
    final scale = Curves.easeOutBack.transform(progress);
    final alpha = Curves.easeOut.transform(progress);
    final centre = Offset(c * _cell + _tile / 2, r * _cell + _tile / 2);
    final rect = Rect.fromCenter(center: centre, width: _tile * scale, height: _tile * scale);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    final fill = colours.fill(f);
    final ink = colours.ink(f);

    // A darker lip under the tile, so it sits on the board instead of in it.
    canvas.drawRRect(
      rrect.shift(const Offset(0, 2)),
      Paint()..color = Color.lerp(fill, Colors.black, 0.28)!.withValues(alpha: alpha),
    );
    canvas.drawRRect(rrect, Paint()..color = fill.withValues(alpha: alpha));

    if (scale < 0.6) return;
    final glyph = _glyph(letter.toUpperCase(), ink.withValues(alpha: alpha), 19, FontWeight.w700);
    glyph.paint(canvas, centre - Offset(glyph.width / 2, glyph.height / 2 + 1));
    final value = letterValues[letter];
    if (value != null) {
      final v = _glyph('$value', ink.withValues(alpha: alpha * 0.8), 8, FontWeight.w600);
      v.paint(canvas, Offset(rect.right - v.width - 3, rect.bottom - v.height - 2));
    }
  }

  // Built fresh on every rebuild, and a rebuild only happens when a tick,
  // the familiarity map or the theme moved — all of which change the picture.
  @override
  bool shouldRepaint(_BoardPainter old) => true;
}

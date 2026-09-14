import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The three motions a study card makes, kept apart from what's printed on
/// it: it flips over to reveal its back ([FlipCard]), it follows the finger
/// on the front so a swipe feels like handling a card rather than pressing
/// a button ([SwipeableCard]), and once graded it leaves as the next one
/// arrives ([CardDeck]).

/// Turns over with a perspective flip about its vertical axis whenever
/// [showBack] changes. The child swaps at the halfway point, where the card
/// is edge-on and nothing is visible, so the back never appears mirrored.
class FlipCard extends StatefulWidget {
  final bool showBack;
  final Widget front;
  final Widget back;
  final Duration duration;

  const FlipCard({
    super.key,
    required this.showBack,
    required this.front,
    required this.back,
    this.duration = const Duration(milliseconds: 420),
  });

  @override
  State<FlipCard> createState() => _FlipCardState();
}

class _FlipCardState extends State<FlipCard> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.showBack ? 1 : 0,
  );
  late final Animation<double> _turn = CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic);

  @override
  void didUpdateWidget(FlipCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showBack != oldWidget.showBack) {
      if (widget.showBack) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _turn,
      builder: (context, _) {
        final angle = _turn.value * pi;
        final onBack = angle > pi / 2;
        // A small perspective term so the near edge grows as it turns —
        // without it a rotateY is just a horizontal squash.
        final transform = Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..rotateY(angle);
        return Transform(
          alignment: Alignment.center,
          transform: transform,
          child: onBack
              ? Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()..rotateY(pi),
                  child: widget.back,
                )
              : widget.front,
        );
      },
    );
  }
}

/// Lets the card be dragged sideways. It follows the finger with a slight
/// tilt and shows what each direction will do as it goes. On release past
/// the commit point it fires the matching callback and stays where it was
/// let go, so whatever replaces it ([CardDeck]) can carry it on off the
/// screen in the same direction; short of it, it springs back. Off when
/// [enabled] is false.
class SwipeableCard extends StatefulWidget {
  final bool enabled;
  final Widget child;
  final String rightLabel;
  final String leftLabel;
  final Color rightColor;
  final Color leftColor;
  final VoidCallback onSwipeRight;
  final VoidCallback onSwipeLeft;

  const SwipeableCard({
    super.key,
    required this.enabled,
    required this.child,
    required this.rightLabel,
    required this.leftLabel,
    required this.rightColor,
    required this.leftColor,
    required this.onSwipeRight,
    required this.onSwipeLeft,
  });

  @override
  State<SwipeableCard> createState() => _SwipeableCardState();
}

class _SwipeableCardState extends State<SwipeableCard> with SingleTickerProviderStateMixin {
  /// How far the finger has to have carried the card before letting go
  /// counts as a swipe rather than a fidget.
  static const _commitDistance = 72.0;
  static const _commitVelocity = 600.0;

  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  double _dx = 0;
  double _releasedFrom = 0;

  @override
  void initState() {
    super.initState();
    _settle.addListener(() {
      setState(() => _dx = _releasedFrom * (1 - Curves.easeOutBack.transform(_settle.value)));
    });
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_settle.isAnimating) return;
    setState(() => _dx += d.delta.dx);
  }

  void _onEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    final committed = _dx.abs() > _commitDistance || velocity.abs() > _commitVelocity;
    final toRight = committed ? (_dx.abs() > _commitDistance ? _dx > 0 : velocity > 0) : null;
    if (toRight == null) {
      _releasedFrom = _dx;
      _settle.forward(from: 0);
      return;
    }
    HapticFeedback.selectionClick();
    if (toRight) {
      widget.onSwipeRight();
    } else {
      widget.onSwipeLeft();
    }
  }

  @override
  Widget build(BuildContext context) {
    // The card lags the finger a little and tilts with it — the rubber-band
    // feel that says "this is a thing you're holding".
    final shift = _dx * 0.7;
    final tilt = (_dx / 900).clamp(-0.12, 0.12);
    final rightReveal = (_dx / _commitDistance).clamp(0.0, 1.0);
    final leftReveal = (-_dx / _commitDistance).clamp(0.0, 1.0);

    return GestureDetector(
      onHorizontalDragUpdate: widget.enabled ? _onUpdate : null,
      onHorizontalDragEnd: widget.enabled ? _onEnd : null,
      behavior: HitTestBehavior.opaque,
      child: Transform(
        alignment: Alignment.bottomCenter,
        transform: Matrix4.identity()
          ..translateByDouble(shift, 0, 0, 1)
          ..rotateZ(tilt),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (widget.enabled) ...[
              _SwipeHint(
                alignment: Alignment.centerLeft,
                opacity: rightReveal,
                color: widget.rightColor,
                icon: Icons.check,
                label: widget.rightLabel,
              ),
              _SwipeHint(
                alignment: Alignment.centerRight,
                opacity: leftReveal,
                color: widget.leftColor,
                icon: Icons.replay,
                label: widget.leftLabel,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SwipeHint extends StatelessWidget {
  final Alignment alignment;
  final double opacity;
  final Color color;
  final IconData icon;
  final String label;

  const _SwipeHint({
    required this.alignment,
    required this.opacity,
    required this.color,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: alignment,
          child: Opacity(
            opacity: opacity,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 18),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: color, width: 1.5),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(fontWeight: FontWeight.w600, color: color),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Swaps one card for the next. When [child]'s key changes, the old card
/// slides off — to the left by default, or to the right when
/// [exitToRight] says the user swiped it that way — dipping and fading as
/// it goes, while the new one slides in from the opposite side. So grading
/// reads as "done with that one, here is the next", not as the text under
/// your thumb silently changing.
class CardDeck extends StatefulWidget {
  /// Must carry a [Key] that changes from card to card.
  final Widget child;
  final bool exitToRight;

  const CardDeck({super.key, required this.child, this.exitToRight = false});

  @override
  State<CardDeck> createState() => _CardDeckState();
}

class _CardDeckState extends State<CardDeck> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  Widget? _outgoing;
  bool _outgoingToRight = false;

  @override
  void didUpdateWidget(CardDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.child.key != oldWidget.child.key) {
      _outgoing = oldWidget.child;
      _outgoingToRight = widget.exitToRight;
      _controller.forward(from: 0).whenComplete(() {
        if (mounted) setState(() => _outgoing = null);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final w = constraints.maxWidth;
          final out = Curves.easeInCubic.transform(_controller.value);
          final inn = Curves.easeOutCubic.transform(_controller.value);
          final outgoing = _outgoing;
          final sign = _outgoingToRight ? 1.0 : -1.0;
          // Both slots are the same widget type, keyed by the card, so the
          // leaving card keeps its element — and with it its flipped state,
          // its drag position and whatever game it was showing — instead of
          // being rebuilt from scratch just to animate out.
          return Stack(
            fit: StackFit.expand,
            children: [
              if (outgoing != null)
                _DeckSlot(
                  key: outgoing.key,
                  offset: Offset(sign * 1.1 * w * out, 40 * out),
                  rotation: sign * 0.18 * out,
                  opacity: 1 - out,
                  inert: true,
                  child: outgoing,
                ),
              _DeckSlot(
                key: widget.child.key,
                offset: Offset(outgoing == null ? 0 : -sign * (1 - inn) * 1.05 * w, 0),
                rotation: 0,
                opacity: 1,
                inert: false,
                child: widget.child,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DeckSlot extends StatelessWidget {
  final Offset offset;
  final double rotation;
  final double opacity;
  final bool inert;
  final Widget child;

  const _DeckSlot({
    super.key,
    required this.offset,
    required this.rotation,
    required this.opacity,
    required this.inert,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: inert,
      child: Opacity(
        opacity: opacity,
        child: Transform(
          alignment: Alignment.bottomCenter,
          transform: Matrix4.identity()
            ..translateByDouble(offset.dx, offset.dy, 0, 1)
            ..rotateZ(rotation),
          child: child,
        ),
      ),
    );
  }
}

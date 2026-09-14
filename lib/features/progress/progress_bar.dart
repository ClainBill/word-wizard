import 'package:flutter/material.dart';

import '../../domain/models/progress.dart';
import 'progress_format.dart';

/// The colours the four word states use everywhere — the bar, its legend,
/// the progress screen — so "mastered" is the same colour on every surface.
({Color mastered, Color reviewing, Color learning, Color unstudied}) progressColors(
  ColorScheme scheme,
) =>
    (
      mastered: scheme.primary,
      reviewing: scheme.primary.withValues(alpha: 0.55),
      learning: scheme.tertiary.withValues(alpha: 0.7),
      unstudied: scheme.outlineVariant,
    );

/// Every word the user has touched, as one bar: mastered on the left,
/// growing rightwards into what's still only sitting in a list.
///
/// The segments are proportional to real word counts, which is the point —
/// it is a picture of the vocabulary, not a meter that fills up. A single
/// hairline gap separates segments so two similar shades still read as two.
class ProgressSegmentsBar extends StatelessWidget {
  final ProgressOverview overview;
  final double height;

  const ProgressSegmentsBar({super.key, required this.overview, this.height = 14});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = progressColors(scheme);
    final total = overview.total;
    final segments = [
      (overview.mastered, colors.mastered),
      (overview.reviewing, colors.reviewing),
      (overview.learning, colors.learning),
      (overview.unstudied, colors.unstudied),
    ].where((s) => s.$1 > 0).toList();

    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: total == 0
            ? ColoredBox(color: colors.unstudied.withValues(alpha: 0.4))
            : Row(
                // The segments have no children of their own, so they only
                // take the bar's height if the row hands it to them.
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < segments.length; i++) ...[
                    if (i > 0) SizedBox(width: 1.5, child: ColoredBox(color: scheme.surface)),
                    Expanded(
                      flex: segments[i].$1,
                      child: ColoredBox(color: segments[i].$2),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

/// The counts behind the bar, in the bar's colours and order.
class ProgressLegend extends StatelessWidget {
  final ProgressOverview overview;

  const ProgressLegend({super.key, required this.overview});

  @override
  Widget build(BuildContext context) {
    final colors = progressColors(Theme.of(context).colorScheme);
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        _LegendItem(color: colors.mastered, label: 'Mastered', count: overview.mastered),
        _LegendItem(color: colors.reviewing, label: 'Reviewing', count: overview.reviewing),
        _LegendItem(color: colors.learning, label: 'Learning', count: overview.learning),
        _LegendItem(color: colors.unstudied, label: 'In lists', count: overview.unstudied),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  final int count;

  const _LegendItem({required this.color, required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          '${formatCount(count)} $label',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

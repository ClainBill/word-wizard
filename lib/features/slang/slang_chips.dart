import 'package:flutter/material.dart';

import '../../domain/models/slang.dart';

/// Where a slang word is used, by whom, and how fresh it is, as a row of
/// small labels — on a Slang Stack row and at the top of the word's card.
class SlangChips extends StatelessWidget {
  final SlangWord word;

  /// Smaller and tighter, for a list row.
  final bool compact;

  const SlangChips({super.key, required this.word, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final labels = <(IconData, String)>[
      if (word.region != null) (Icons.place_outlined, word.region!),
      if (word.scene != null) (Icons.groups_outlined, word.scene!),
      if (word.freshness != null) (_freshnessIcon(word.freshness!), word.freshness!.label),
    ];
    if (labels.isEmpty) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final size = compact ? 12.0 : 13.0;
    return Padding(
      padding: EdgeInsets.only(top: compact ? 4 : 8),
      child: Wrap(
        spacing: compact ? 10 : 14,
        runSpacing: 2,
        children: [
          for (final (icon, label) in labels)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: size + 2, color: color),
                const SizedBox(width: 3),
                Text(label, style: TextStyle(fontSize: size, color: color)),
              ],
            ),
        ],
      ),
    );
  }

  static IconData _freshnessIcon(SlangFreshness f) => switch (f) {
        SlangFreshness.rising => Icons.trending_up,
        SlangFreshness.current => Icons.local_fire_department_outlined,
        SlangFreshness.fading => Icons.trending_down,
        SlangFreshness.dated => Icons.hourglass_bottom,
      };
}

/// "Your slang" — marks what on a card or a search row came from the
/// person's own Slang Stack rather than the dictionary.
class SlangBadge extends StatelessWidget {
  final String label;

  const SlangBadge({super.key, this.label = 'Your slang'});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: 12, color: scheme.onTertiaryContainer),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onTertiaryContainer),
          ),
        ],
      ),
    );
  }
}

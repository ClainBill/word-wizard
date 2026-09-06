import 'package:flutter/material.dart';

class PosTag extends StatelessWidget {
  final String pos;

  const PosTag(this.pos, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.secondary.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        pos,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: scheme.secondary,
        ),
      ),
    );
  }
}

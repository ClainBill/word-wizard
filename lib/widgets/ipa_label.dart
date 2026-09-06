import 'package:flutter/material.dart';

class IpaLabel extends StatelessWidget {
  final String? ipa;

  const IpaLabel(this.ipa, {super.key});

  @override
  Widget build(BuildContext context) {
    if (ipa == null || ipa!.isEmpty) return const SizedBox.shrink();
    return Text(
      ipa!,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../domain/models/entry.dart';
import 'pos_tag.dart';

class EntryCard extends StatelessWidget {
  final EntrySummary entry;
  final VoidCallback onTap;

  const EntryCard({super.key, required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(entry.headword, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 8),
          PosTag(entry.pos),
          if (entry.matchedForm != null) ...[
            const SizedBox(width: 8),
            // Why a different word is here: it's what "ran" is a form of.
            Flexible(
              child: Text(
                '← ${entry.matchedForm}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
      subtitle: entry.gloss == null
          ? null
          : Text(
              entry.gloss!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
    );
  }
}

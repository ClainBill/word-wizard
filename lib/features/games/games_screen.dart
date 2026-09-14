import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../domain/crossword/crossword_models.dart';

class GamesScreen extends StatelessWidget {
  const GamesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Games')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Daily Crossword', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'A grid of dictionary words with a few of today\'s study words mixed in.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final difficulty in CrosswordDifficulty.values) ...[
            _DifficultyTile(difficulty: difficulty),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 16),
          Text('Word Hunt', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Trace words through a 4×4 board built around your study words and a daily theme.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          const _HuntTile(),
        ],
      ),
    );
  }
}

class _DifficultyTile extends StatelessWidget {
  final CrosswordDifficulty difficulty;

  const _DifficultyTile({required this.difficulty});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: () => context.push('/games/crossword/${difficulty.storageKey}'),
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Text(
            difficulty.label[0],
            style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer),
          ),
        ),
        title: Text(difficulty.label),
        subtitle: Text('${difficulty.size}×${difficulty.size}'),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _HuntTile extends StatelessWidget {
  const _HuntTile();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: () => context.push('/games/hunt'),
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(Icons.grid_view_rounded, color: scheme.onSecondaryContainer),
        ),
        title: const Text('Daily board'),
        subtitle: const Text('4×4 · new theme every day'),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

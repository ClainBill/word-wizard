import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/repositories/crossword_repository.dart';
import '../../domain/crossword/crossword_models.dart';

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(String date) {
  final today = CrosswordRepository.today();
  if (date == today) return 'Today';
  final parts = date.split('-');
  final year = int.parse(parts[0]);
  final month = int.parse(parts[1]);
  final day = int.parse(parts[2]);
  final yesterday = DateTime.now().subtract(const Duration(days: 1));
  if (year == yesterday.year && month == yesterday.month && day == yesterday.day) return 'Yesterday';
  return '${_monthNames[month - 1]} $day, $year';
}

class CrosswordHistoryScreen extends ConsumerWidget {
  final CrosswordDifficulty difficulty;

  const CrosswordHistoryScreen({super.key, required this.difficulty});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(crosswordHistoryProvider(difficulty));

    return Scaffold(
      appBar: AppBar(title: Text('${difficulty.label} History')),
      body: historyAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load history: $e')),
        data: (entries) {
          if (entries.isEmpty) {
            return const Center(child: Text('No puzzles yet.'));
          }
          return ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return ListTile(
                title: Text(_formatDate(entry.date)),
                trailing: entry.completed
                    ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () => context.push('/games/crossword/${difficulty.storageKey}?date=${entry.date}'),
              );
            },
          );
        },
      ),
    );
  }
}

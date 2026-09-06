import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/models/entry.dart';
import '../features/entry/entry_detail_screen.dart';

final _sheetWordProvider = FutureProvider.family<WordEntry?, String>(
  (ref, headword) => ref.watch(searchRepositoryProvider).loadWord(headword),
);

/// Pops the full dictionary card for [headword] up from below as a
/// swipe-to-dismiss sheet — used from the study session so a word can be
/// reviewed in full context without leaving the flow.
Future<void> showWordDetailSheet(BuildContext context, String headword) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _WordDetailSheet(headword: headword),
  );
}

class _WordDetailSheet extends ConsumerWidget {
  final String headword;

  const _WordDetailSheet({required this.headword});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wordAsync = ref.watch(_sheetWordProvider(headword));

    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: wordAsync.when(
                  data: (word) => word == null
                      ? const Center(child: Text('Entry not found.'))
                      : WordBody(word: word, controller: scrollController),
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('Couldn\'t load entry: $e')),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

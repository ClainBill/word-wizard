import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/word_list.dart';

final _listsProvider = StreamProvider<List<WordList>>(
  (ref) => ref.watch(listRepositoryProvider).watchLists(),
);

class ListsScreen extends ConsumerWidget {
  const ListsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listsAsync = ref.watch(_listsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Lists')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createList(context, ref),
        child: const Icon(Icons.add),
      ),
      body: listsAsync.when(
        data: (lists) => lists.isEmpty
            ? Center(
                child: Text(
                  'No lists yet.\nTap + to create one, or add a word to a\nlist from its entry page.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              )
            : ListView.separated(
                itemCount: lists.length,
                separatorBuilder: (context, i) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final list = lists[i];
                  return ListTile(
                    title: Text(list.name),
                    subtitle: Text('${list.itemCount} words'),
                    trailing: list.dueCount == 0
                        ? null
                        : Chip(
                            label: Text('${list.dueCount} due'),
                            visualDensity: VisualDensity.compact,
                          ),
                    onTap: () => context.push('/lists/${list.id}', extra: list.name),
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load lists: $e')),
      ),
    );
  }

  Future<void> _createList(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New list'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'List name'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    await ref.read(listRepositoryProvider).createList(trimmed);
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/word_list.dart';
import '../../widgets/confirm_dialog.dart';

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
        onPressed: () => _createTopLevel(context, ref),
        child: const Icon(Icons.add),
      ),
      body: listsAsync.when(
        data: (lists) => ListView.separated(
          // The Slang Stack sits above the lists: it isn't one, but
          // it's the other collection of words the person built.
          itemCount: lists.length + 1 + (lists.isEmpty ? 1 : 0),
          separatorBuilder: (context, i) => const Divider(height: 1),
          itemBuilder: (context, i) {
            if (i == 0) return const _SlangStackTile();
            if (lists.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No lists yet.\nTap + to create one, or add a word to a\nlist from its entry page.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              );
            }
            final list = lists[i - 1];
            return Dismissible(
              key: ValueKey(list.id),
              direction: DismissDirection.endToStart,
              background: Container(
                color: Theme.of(context).colorScheme.errorContainer,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                child: const Icon(Icons.delete_outline),
              ),
              confirmDismiss: (_) => showConfirmDialog(
                context,
                title: list.isFolder ? 'Delete this folder?' : 'Delete this list?',
                message: list.isFolder
                    ? 'Deletes this folder and everything inside it — nested lists and '
                        'folders, and all their words. This can\'t be undone.'
                    : 'Deletes this list and its words. This can\'t be undone.',
                confirmLabel: 'Delete',
                destructive: true,
              ),
              onDismissed: (_) => ref.read(listRepositoryProvider).deleteList(list.id),
              child: ListTile(
                leading: Icon(list.isFolder ? Icons.folder_outlined : Icons.list_alt_outlined),
                title: Text(list.name),
                subtitle: Text('${list.itemCount} words'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (list.dueCount > 0) ...[
                      Chip(
                        label: Text('${list.dueCount} due'),
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (list.isFolder) const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () => context.push('/lists/${list.id}', extra: list.name),
              ),
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load lists: $e')),
      ),
    );
  }

  Future<void> _createTopLevel(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<ListKind>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.list_alt_outlined),
              title: const Text('New list'),
              onTap: () => Navigator.of(context).pop(ListKind.custom),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('New folder'),
              onTap: () => Navigator.of(context).pop(ListKind.folder),
            ),
            ListTile(
              leading: const Icon(Icons.bolt_outlined),
              title: const Text('New slang word'),
              onTap: () {
                final router = GoRouter.of(context);
                Navigator.of(context).pop();
                router.push('/slang/edit');
              },
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;

    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(choice == ListKind.folder ? 'New folder' : 'New list'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name'),
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
    await ref.read(listRepositoryProvider).createList(trimmed, kind: choice);
  }
}

/// The way into the Slang Stack from the Lists tab, with how many words
/// it holds.
class _SlangStackTile extends ConsumerWidget {
  const _SlangStackTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(slangStackProvider).valueOrNull?.length;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.bolt, color: scheme.tertiary),
      title: const Text('Slang Stack'),
      subtitle: Text(
        count == null || count == 0
            ? 'Words and meanings the dictionary doesn\'t have yet'
            : '$count ${count == 1 ? 'word' : 'words'} of your own',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/lists/slang'),
    );
  }
}

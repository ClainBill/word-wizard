import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/models/word_list.dart';

Future<void> showAddToListSheet(BuildContext context, WidgetRef ref, int entryId) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => _AddToListSheet(entryId: entryId),
  );
}

class _AddToListSheet extends ConsumerStatefulWidget {
  final int entryId;

  const _AddToListSheet({required this.entryId});

  @override
  ConsumerState<_AddToListSheet> createState() => _AddToListSheetState();
}

class _AddToListSheetState extends ConsumerState<_AddToListSheet> {
  final _newListController = TextEditingController();

  @override
  void dispose() {
    _newListController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listsAsync = ref.watch(_listsForEntryProvider(widget.entryId));
    return SafeArea(
      child: Padding(
        // The keyboard inset keeps the "new list" field above the keys —
        // a modal sheet doesn't move for the keyboard by itself.
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add to list', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Tap a list to add this word; tap again to remove it.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            listsAsync.when(
              data: (lists) => lists.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No lists yet — create one below.'),
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final list in lists)
                            CheckboxListTile(
                              secondary: Icon(
                                list.kind == ListKind.folder ? Icons.folder_outlined : Icons.list_alt_outlined,
                              ),
                              title: Text(list.name),
                              value: list.isMember,
                              onChanged: (_) async {
                                final listRepo = ref.read(listRepositoryProvider);
                                if (list.isMember) {
                                  await listRepo.removeFromList(list.id, widget.entryId);
                                } else {
                                  await listRepo.addToList(list.id, widget.entryId);
                                }
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        list.isMember
                                            ? 'Removed from "${list.name}"'
                                            : 'Added to "${list.name}"',
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                        ],
                      ),
                    ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text('Couldn\'t load lists: $e'),
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newListController,
                    decoration: const InputDecoration(hintText: 'New list name'),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    final name = _newListController.text.trim();
                    if (name.isEmpty) return;
                    final listRepo = ref.read(listRepositoryProvider);
                    final id = await listRepo.createList(name);
                    await listRepo.addToList(id, widget.entryId);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Added to "$name"')),
                      );
                      Navigator.of(context).pop();
                    }
                  },
                  child: const Text('Create'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final _listsForEntryProvider = StreamProvider.family<List<ListMembership>, int>(
  (ref, entryId) => ref.watch(listRepositoryProvider).watchListsForEntry(entryId),
);

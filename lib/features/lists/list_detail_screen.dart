import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/word_list.dart';
import '../../widgets/pos_tag.dart';

final _listItemsProvider = StreamProvider.family<List<ListItem>, int>(
  (ref, listId) => ref.watch(listRepositoryProvider).watchListItems(listId),
);

class ListDetailScreen extends ConsumerWidget {
  final int listId;
  final String? listName;

  const ListDetailScreen({super.key, required this.listId, this.listName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(_listItemsProvider(listId));

    return Scaffold(
      appBar: AppBar(
        title: Text(listName ?? 'List'),
        actions: [
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: 'Study this list',
            onPressed: () async {
              // Enrolling here (rather than requiring each word to be added
              // to the study pool individually first) is what makes a list
              // a usable "study this word group today" unit.
              await ref.read(studyRepositoryProvider).enrollList(listId);
              ref.invalidate(dueCountProvider);
              if (context.mounted) context.push('/study/session?listId=$listId');
            },
          ),
          PopupMenuButton<_ListSrsAction>(
            tooltip: 'SRS actions for this list',
            onSelected: (action) => _handleSrsAction(context, ref, listId, action),
            itemBuilder: (context) => const [
              PopupMenuItem(value: _ListSrsAction.reset, child: Text('Reset all in study')),
              PopupMenuItem(value: _ListSrsAction.pause, child: Text('Pause all in study')),
              PopupMenuItem(value: _ListSrsAction.resume, child: Text('Resume all in study')),
              PopupMenuItem(value: _ListSrsAction.remove, child: Text('Remove all from study')),
            ],
          ),
        ],
      ),
      body: itemsAsync.when(
        data: (items) => items.isEmpty
            ? Center(
                child: Text(
                  'No words in this list yet.',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              )
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (context, i) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final item = items[i];
                  return Dismissible(
                    key: ValueKey("${item.entryId}-$listId"),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: Theme.of(context).colorScheme.errorContainer,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Icons.delete_outline),
                    ),
                    onDismissed: (_) => ref
                        .read(listRepositoryProvider)
                        .removeFromList(listId, item.entryId),
                    child: ListTile(
                      title: Row(
                        children: [
                          Text(item.headword),
                          const SizedBox(width: 8),
                          PosTag(item.pos),
                        ],
                      ),
                      subtitle: item.gloss == null
                          ? null
                          : Text(item.gloss!, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => context.push('/entry/${Uri.encodeComponent(item.headword)}'),
                    ),
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Couldn\'t load list: $e')),
      ),
    );
  }
}

enum _ListSrsAction { reset, pause, resume, remove }

Future<void> _handleSrsAction(
  BuildContext context,
  WidgetRef ref,
  int listId,
  _ListSrsAction action,
) async {
  final studyRepo = ref.read(studyRepositoryProvider);

  switch (action) {
    case _ListSrsAction.pause:
      await studyRepo.setListPaused(listId, true);
      ref.invalidate(dueCountProvider);
      return;
    case _ListSrsAction.resume:
      await studyRepo.setListPaused(listId, false);
      ref.invalidate(dueCountProvider);
      return;
    case _ListSrsAction.reset:
      final confirmed = await _confirmDialog(
        context,
        title: 'Reset this list\'s study progress?',
        message: 'Clears review history and progress for every word in this list that\'s '
            'currently in the SRS, putting them back to brand-new (due immediately). Words '
            'not currently in study are unaffected.',
        confirmLabel: 'Reset',
      );
      if (confirmed) {
        await studyRepo.resetListCards(listId);
        ref.invalidate(dueCountProvider);
      }
      return;
    case _ListSrsAction.remove:
      final confirmed = await _confirmDialog(
        context,
        title: 'Remove this list from study?',
        message: 'Deletes review history and un-enrolls every word in this list from the SRS '
            'pool. The list itself and its words are untouched.',
        confirmLabel: 'Remove',
        destructive: true,
      );
      if (confirmed) {
        await studyRepo.removeListCards(listId);
        ref.invalidate(dueCountProvider);
      }
      return;
  }
}

Future<bool> _confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error)
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}

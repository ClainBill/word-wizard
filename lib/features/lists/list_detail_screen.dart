import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/models/word_list.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/pos_tag.dart';

final _listItemsProvider = StreamProvider.family<List<ListItem>, int>(
  (ref, listId) => ref.watch(listRepositoryProvider).watchListItems(listId),
);

final _listProvider = StreamProvider.family<WordList?, int>(
  (ref, listId) => ref.watch(listRepositoryProvider).watchList(listId),
);

final _childListsProvider = StreamProvider.family<List<WordList>, int>(
  (ref, listId) => ref.watch(listRepositoryProvider).watchLists(parentId: listId),
);

class ListDetailScreen extends ConsumerWidget {
  final int listId;
  final String? listName;

  const ListDetailScreen({super.key, required this.listId, this.listName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listAsync = ref.watch(_listProvider(listId));
    final childrenAsync = ref.watch(_childListsProvider(listId));
    final itemsAsync = ref.watch(_listItemsProvider(listId));
    final list = listAsync.valueOrNull;
    final isFolder = list?.isFolder ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isFolder) ...[
              const Icon(Icons.folder_outlined, size: 20),
              const SizedBox(width: 8),
            ],
            Flexible(child: Text(list?.name ?? listName ?? 'List', overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: isFolder ? 'Study this folder' : 'Study this list',
            onPressed: () async {
              // Enrolling here (rather than requiring each word to be added
              // to the study pool individually first) is what makes a list
              // — or a whole folder, since enrollList resolves a folder id
              // to every word nested inside it — a usable "study this word
              // group today" unit.
              await ref
                  .read(studyRepositoryProvider)
                  .enrollList(listId, ref.read(studyDirectionsProvider));
              ref.invalidate(dueCountProvider);
              if (context.mounted) context.push('/study/session?listId=$listId');
            },
          ),
          PopupMenuButton<_ListAction>(
            tooltip: isFolder ? 'Actions for this folder' : 'Actions for this list',
            onSelected: (action) => _handleAction(context, ref, listId, list, action),
            itemBuilder: (context) => [
              const PopupMenuItem(value: _ListAction.reset, child: Text('Reset all in study')),
              const PopupMenuItem(value: _ListAction.pause, child: Text('Pause all in study')),
              const PopupMenuItem(value: _ListAction.resume, child: Text('Resume all in study')),
              const PopupMenuItem(value: _ListAction.remove, child: Text('Remove all from study')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: _ListAction.moveToFolder, child: Text('Move to folder…')),
              const PopupMenuItem(value: _ListAction.delete, child: Text('Delete')),
            ],
          ),
        ],
      ),
      floatingActionButton: !isFolder
          ? null
          : FloatingActionButton(
              onPressed: () => _createInFolder(context, ref, listId),
              child: const Icon(Icons.add),
            ),
      body: Column(
        children: [
          childrenAsync.when(
            data: (children) => children.isEmpty
                ? const SizedBox.shrink()
                : _ChildListsSection(children: children),
            loading: () => const SizedBox.shrink(),
            error: (e, _) => const SizedBox.shrink(),
          ),
          Expanded(
            child: itemsAsync.when(
              data: (items) => items.isEmpty
                  ? Center(
                      child: Text(
                        isFolder ? 'No words directly in this folder yet.' : 'No words in this list yet.',
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
          ),
        ],
      ),
    );
  }
}

/// Child lists/folders nested directly under this folder — tapping one
/// drills further in via the same `/lists/:id` route, one level per tap, so
/// the back button retraces the hierarchy one folder at a time.
class _ChildListsSection extends StatelessWidget {
  final List<WordList> children;

  const _ChildListsSection({required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Folders & lists',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        for (final child in children)
          ListTile(
            leading: Icon(child.isFolder ? Icons.folder_outlined : Icons.list_alt_outlined),
            title: Text(child.name),
            subtitle: Text('${child.itemCount} words'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (child.dueCount > 0) ...[
                  Chip(label: Text('${child.dueCount} due'), visualDensity: VisualDensity.compact),
                  const SizedBox(width: 4),
                ],
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => context.push('/lists/${child.id}', extra: child.name),
          ),
        const Divider(height: 1),
      ],
    );
  }
}

enum _ListAction { reset, pause, resume, remove, moveToFolder, delete }

Future<void> _handleAction(
  BuildContext context,
  WidgetRef ref,
  int listId,
  WordList? list,
  _ListAction action,
) async {
  final studyRepo = ref.read(studyRepositoryProvider);
  final listRepo = ref.read(listRepositoryProvider);
  final isFolder = list?.isFolder ?? false;

  switch (action) {
    case _ListAction.pause:
      await studyRepo.setListPaused(listId, true);
      ref.invalidate(dueCountProvider);
      return;
    case _ListAction.resume:
      await studyRepo.setListPaused(listId, false);
      ref.invalidate(dueCountProvider);
      return;
    case _ListAction.reset:
      final confirmed = await showConfirmDialog(
        context,
        title: isFolder ? 'Reset this folder\'s study progress?' : 'Reset this list\'s study progress?',
        message: 'Clears review history and progress for every word ${isFolder ? 'in this folder' : 'in this list'} that\'s '
            'currently in the SRS, putting them back to brand-new (due immediately). Words '
            'not currently in study are unaffected.',
        confirmLabel: 'Reset',
      );
      if (confirmed) {
        await studyRepo.resetListCards(listId);
        ref.invalidate(dueCountProvider);
      }
      return;
    case _ListAction.remove:
      final confirmed = await showConfirmDialog(
        context,
        title: isFolder ? 'Remove this folder from study?' : 'Remove this list from study?',
        message: 'Deletes review history and un-enrolls every word ${isFolder ? 'in this folder' : 'in this list'} from the SRS '
            'pool. The ${isFolder ? 'folder' : 'list'} itself and its words are untouched.',
        confirmLabel: 'Remove',
        destructive: true,
      );
      if (confirmed) {
        await studyRepo.removeListCards(listId);
        ref.invalidate(dueCountProvider);
      }
      return;
    case _ListAction.moveToFolder:
      await _showMoveToFolderSheet(context, ref, listId);
      return;
    case _ListAction.delete:
      final confirmed = await showConfirmDialog(
        context,
        title: isFolder ? 'Delete this folder?' : 'Delete this list?',
        message: isFolder
            ? 'Deletes this folder and everything inside it — nested lists and folders, and all '
                'their words. This can\'t be undone.'
            : 'Deletes this list and its words. This can\'t be undone.',
        confirmLabel: 'Delete',
        destructive: true,
      );
      if (confirmed) {
        await listRepo.deleteList(listId);
        ref.invalidate(dueCountProvider);
        if (context.mounted) context.pop();
      }
      return;
  }
}

Future<void> _showMoveToFolderSheet(BuildContext context, WidgetRef ref, int listId) async {
  final listRepo = ref.read(listRepositoryProvider);
  final folders = await listRepo.watchableFolders(excludingSubtreeOf: listId);
  if (!context.mounted) return;
  final chosen = await showModalBottomSheet<_MoveTarget>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Move to folder'),
          ),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Top level'),
            onTap: () => Navigator.of(context).pop(const _MoveTarget(null)),
          ),
          for (final folder in folders)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(folder.name),
              onTap: () => Navigator.of(context).pop(_MoveTarget(folder.id)),
            ),
        ],
      ),
    ),
  );
  if (chosen == null) return;
  try {
    await listRepo.moveList(listId, chosen.parentId);
  } on StateError catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _MoveTarget {
  final int? parentId;
  const _MoveTarget(this.parentId);
}

Future<void> _createInFolder(BuildContext context, WidgetRef ref, int folderId) async {
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
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final name = await _promptForName(context, choice == ListKind.folder ? 'New folder' : 'New list');
  if (name == null) return;
  await ref.read(listRepositoryProvider).createList(name, kind: choice, parentId: folderId);
}

Future<String?> _promptForName(BuildContext context, String title) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Create'),
        ),
      ],
    ),
  );
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
